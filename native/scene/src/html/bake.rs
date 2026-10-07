//! Resolve-only script bake: run classic <script> against a tiny document, dump HTML.
//!
//! StarlingMonkey is a WinterTC JS engine with no document. This module *is* the
//! document. The engine is QuickJS (rquickjs) — embeddable, no ICU clash with
//! Parley. Evaluate(t) never calls this — only capture / s:page resolve.

use kuchikiki::traits::*;
use kuchikiki::NodeRef;
use rquickjs::{function::Func, CatchResultExt, Context, Runtime};
use std::cell::RefCell;
use url::Url;

thread_local! {
    static ROOT: RefCell<Option<NodeRef>> = const { RefCell::new(None) };
    static NODES: RefCell<Vec<NodeRef>> = const { RefCell::new(Vec::new()) };
}

const PRELUDE: &str = r##"
var console = { log: function() { __el_log(Array.prototype.join.call(arguments, " ")); } };
function __wrap(nid) {
  if (nid === null || nid === undefined) return null;
  nid = nid|0;
  return {
    get textContent() { return __el_text(nid); },
    set textContent(v) { __el_set_text(nid, String(v)); },
    get innerHTML() { return __el_html(nid); },
    set innerHTML(v) { __el_set_html(nid, String(v)); },
    get className() { return __el_attr(nid, "class") || ""; },
    set className(v) { __el_set_attr(nid, "class", String(v)); },
    getAttribute: function(k) { return __el_attr(nid, String(k)); },
    setAttribute: function(k, v) { __el_set_attr(nid, String(k), String(v)); },
    classList: {
      add: function(n) { __el_class(nid, "add", String(n)); },
      remove: function(n) { __el_class(nid, "remove", String(n)); },
      toggle: function(n) { __el_class(nid, "toggle", String(n)); },
      contains: function(n) { return __el_class(nid, "contains", String(n)) === "1"; }
    }
  };
}
var document = {
  getElementById: function(id) { return __wrap(__el_qs("#" + String(id))); },
  querySelector: function(sel) { return __wrap(__el_qs(String(sel))); },
  get body() { return __wrap(__el_qs("body")); },
  get documentElement() { return __wrap(__el_qs("html")); }
};
"##;

fn intern(node: NodeRef) -> i32 {
    NODES.with(|n| {
        let mut n = n.borrow_mut();
        let id = n.len() as i32;
        n.push(node);
        id
    })
}

fn node(id: i32) -> Option<NodeRef> {
    NODES.with(|n| n.borrow().get(id as usize).cloned())
}

fn el_log(msg: String) {
    eprintln!("moonsplice-html bake: {msg}");
}

fn el_qs(sel: String) -> Option<i32> {
    ROOT.with(|r| {
        r.borrow()
            .as_ref()
            .and_then(|root| root.select_first(&sel).ok())
            .map(|n| intern(n.as_node().clone()))
    })
}

fn el_text(id: i32) -> String {
    node(id).map(|n| n.text_contents()).unwrap_or_default()
}

fn el_set_text(id: i32, text: String) {
    if let Some(n) = node(id) {
        for child in n.children().collect::<Vec<_>>() {
            child.detach();
        }
        n.append(NodeRef::new_text(text));
    }
}

fn serialize_children(n: &NodeRef) -> String {
    let mut out = Vec::new();
    for child in n.children() {
        let _ = child.serialize(&mut out);
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn el_html(id: i32) -> String {
    node(id).map(|n| serialize_children(&n)).unwrap_or_default()
}

fn el_set_html(id: i32, html: String) {
    if let Some(n) = node(id) {
        for child in n.children().collect::<Vec<_>>() {
            child.detach();
        }
        let frag = kuchikiki::parse_html().one(html);
        if let Ok(body) = frag.select_first("body") {
            for child in body.as_node().children().collect::<Vec<_>>() {
                n.append(child);
            }
        }
    }
}

fn el_attr(id: i32, key: String) -> Option<String> {
    node(id).and_then(|n| {
        n.as_element()
            .and_then(|el| el.attributes.borrow().get(key.as_str()).map(|s| s.to_string()))
    })
}

fn el_set_attr(id: i32, key: String, val: String) {
    if let Some(n) = node(id) {
        if let Some(el) = n.as_element() {
            el.attributes.borrow_mut().insert(key, val);
        }
    }
}

fn el_class(id: i32, op: String, name: String) -> String {
    node(id)
        .and_then(|n| {
            let el = n.as_element()?;
            let mut attrs = el.attributes.borrow_mut();
            let mut set: Vec<String> = attrs
                .get("class")
                .unwrap_or("")
                .split_whitespace()
                .filter(|s| !s.is_empty())
                .map(|s| s.to_string())
                .collect();
            match op.as_str() {
                "add" => {
                    if !set.iter().any(|c| c == &name) {
                        set.push(name);
                    }
                    attrs.insert("class", set.join(" "));
                    Some(String::new())
                }
                "remove" => {
                    set.retain(|c| c != &name);
                    attrs.insert("class", set.join(" "));
                    Some(String::new())
                }
                "toggle" => {
                    if set.iter().any(|c| c == &name) {
                        set.retain(|c| c != &name);
                    } else {
                        set.push(name);
                    }
                    attrs.insert("class", set.join(" "));
                    Some(String::new())
                }
                "contains" => Some(if set.iter().any(|c| c == &name) {
                    "1".into()
                } else {
                    "0".into()
                }),
                _ => Some(String::new()),
            }
        })
        .unwrap_or_default()
}

fn collect_scripts(root: &NodeRef, base: Option<&str>) -> Vec<String> {
    let mut scripts = Vec::new();
    let Ok(nodes) = root.select("script") else {
        return scripts;
    };
    let list: Vec<_> = nodes.collect();
    for n in list {
        let node = n.as_node().clone();
        let Some(el) = node.as_element() else { continue };
        let attrs = el.attributes.borrow();
        let kind = attrs.get("type").unwrap_or("").to_ascii_lowercase();
        if kind.contains("module") || kind == "importmap" {
            drop(attrs);
            node.detach();
            continue;
        }
        let src = attrs.get("src").map(|s| s.to_string());
        drop(attrs);
        if let Some(src) = src {
            if let Some(code) = fetch_script(&src, base) {
                scripts.push(code);
            } else {
                eprintln!("moonsplice-html bake: skip script {src}");
            }
        } else {
            scripts.push(node.text_contents());
        }
        node.detach();
    }
    scripts
}

fn fetch_script(src: &str, base: Option<&str>) -> Option<String> {
    let url = if let Ok(u) = Url::parse(src) {
        u
    } else if let Some(b) = base.and_then(|b| {
        Url::parse(b).ok().or_else(|| {
            std::path::Path::new(b)
                .canonicalize()
                .ok()
                .and_then(|p| Url::from_file_path(p).ok())
        })
    }) {
        b.join(src).ok()?
    } else {
        return None;
    };
    match crate::html::load_url(&url) {
        Ok((_, bytes)) => String::from_utf8(bytes.to_vec()).ok(),
        Err(e) => {
            eprintln!("moonsplice-html bake: fetch {url}: {e}");
            None
        }
    }
}

/// Run classic scripts, strip them, return serialized HTML. No-op if none.
pub fn bake(html: &str, base: Option<&str>) -> Result<String, String> {
    if !html.contains("<script") && !html.contains("<SCRIPT") {
        return Ok(html.to_string());
    }
    let root = kuchikiki::parse_html().one(html);
    let scripts = collect_scripts(&root, base);
    if scripts.is_empty() {
        let mut out = Vec::new();
        root.serialize(&mut out).map_err(|e| e.to_string())?;
        return Ok(String::from_utf8_lossy(&out).into_owned());
    }

    ROOT.with(|r| *r.borrow_mut() = Some(root.clone()));
    NODES.with(|n| n.borrow_mut().clear());

    let result = (|| {
        let rt = Runtime::new().map_err(|e| e.to_string())?;
        let ctx = Context::full(&rt).map_err(|e| e.to_string())?;
        ctx.with(|ctx| {
            let g = ctx.globals();
            g.set("__el_log", Func::from(el_log)).map_err(|e| e.to_string())?;
            g.set("__el_qs", Func::from(el_qs)).map_err(|e| e.to_string())?;
            g.set("__el_text", Func::from(el_text)).map_err(|e| e.to_string())?;
            g.set("__el_set_text", Func::from(el_set_text)).map_err(|e| e.to_string())?;
            g.set("__el_html", Func::from(el_html)).map_err(|e| e.to_string())?;
            g.set("__el_set_html", Func::from(el_set_html)).map_err(|e| e.to_string())?;
            g.set("__el_attr", Func::from(el_attr)).map_err(|e| e.to_string())?;
            g.set("__el_set_attr", Func::from(el_set_attr)).map_err(|e| e.to_string())?;
            g.set("__el_class", Func::from(el_class)).map_err(|e| e.to_string())?;
            ctx.eval::<(), _>(PRELUDE).catch(&ctx).map_err(|e| e.to_string())?;
            for (i, code) in scripts.iter().enumerate() {
                ctx.eval::<(), _>(code.as_str())
                    .catch(&ctx)
                    .map_err(|e| format!("script[{i}]: {e}"))?;
            }
            Ok::<(), String>(())
        })
    })();

    let mut out = Vec::new();
    let ser = root.serialize(&mut out).map_err(|e| e.to_string());
    ROOT.with(|r| *r.borrow_mut() = None);
    NODES.with(|n| n.borrow_mut().clear());
    result?;
    ser?;
    Ok(String::from_utf8_lossy(&out).into_owned())
}
