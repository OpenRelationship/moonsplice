import { readFileSync, readdirSync } from "node:fs";
import { join } from "node:path";

import { describe, expect, it } from "vitest";

// Selection, and the two ways it goes wrong.
//
// A desktop app is not a document: dragging a clip along the timeline should move the clip, not
// paint a smear across every lane name it passed. The rule that stops that is three lines of CSS,
// and it is exactly the kind of rule that gets deleted by accident, weakened by a refactor, or
// quietly escaped by a subtree that sets `user-select` for its own reasons -- and nothing fails
// when it does, because nothing was watching. This watches.
//
// The stylesheet is read as text rather than applied to a document: jsdom does not compute
// `user-select` at all, so a test that asked the DOM would agree with whatever the CSS said.

const css = readFileSync(join(__dirname, "app.css"), "utf8");

/** Every .ts/.tsx under src/, so a new component cannot quietly opt itself back in. */
function sources(dir = __dirname): string[] {
  const out: string[] = [];
  for (const e of readdirSync(dir, { withFileTypes: true })) {
    const p = join(dir, e.name);
    if (e.isDirectory()) out.push(...sources(p));
    else if (/\.tsx?$/.test(e.name) && !e.name.endsWith(".test.ts")) out.push(p);
  }
  return out;
}

const code = sources().map((p) => ({ p, text: readFileSync(p, "utf8") }));

describe("nothing highlights unless it is meant to", () => {
  it("bans selection on every element, not on the one it is written on", () => {
    // The rule used to live on `body` and rely on inheritance, which is the one thing it could
    // not rely on: anything setting its own `user-select` escapes it and takes its subtree along.
    const universal = /\*,\s*\*::before,\s*\*::after\s*\{[^}]*\}/.exec(css)?.[0];
    expect(universal, "no universal rule in app.css").toBeTruthy();
    expect(universal).toMatch(/(^|[^-])user-select:\s*none/);
    // WKWebView only took the unprefixed property in Safari 17, and this ships in a webview.
    expect(universal).toMatch(/-webkit-user-select:\s*none/);
  });

  it("keeps the children of a selectable thing selectable", () => {
    // Load-bearing now that the ban is stated on every element rather than inherited: the agent's
    // messages are a <p> full of <span>s, and a paragraph you can select whose spans you cannot
    // selects nothing at all.
    expect(css).toMatch(/\[data-selectable\] \*/);
  });

  it("only lets words be taken: something typed, and something said", () => {
    const rule = /(?:^|\n)((?:[^{}\n]+,\n)*[^{}\n]+)\{[^}]*user-select:\s*text[^}]*\}/g;
    const selectors = [...css.matchAll(rule)]
      .flatMap((m) => m[1].split(","))
      .map((s) => s.trim())
      .filter(Boolean);
    expect(selectors.length).toBeGreaterThan(0);
    // A new exception is a deliberate act. Everything not on this list is a lane name, a number,
    // a label or a menu, and nobody has ever wanted to highlight one of those.
    const allowed = new Set([
      "input",
      "textarea",
      '[contenteditable="true"]',
      "[data-selectable]",
      "[data-selectable] *",
    ]);
    for (const s of selectors) expect(allowed, `${s} was made selectable`).toContain(s);
  });

  it("marks selectable only what a person would want to copy", () => {
    // Today that is the agent's side of the conversation and your own side of it. If the list
    // grows it should grow because somebody decided it should.
    const marked = code.filter((f) => /data-selectable/.test(f.text)).map((f) => f.p);
    expect(marked.map((p) => p.split("/src/")[1])).toEqual(["agent/Agent.tsx"]);
  });

  it("does not leave a utility class lying about that cannot work", () => {
    // The ban is unlayered and Tailwind's utilities are layered, so the ban wins: reaching for
    // `select-text` would compile, apply, and do nothing whatever. `data-selectable` is the one
    // that works, and this is where somebody finds that out.
    for (const f of code) {
      const said = `${f.p} uses select-text, which this stylesheet overrides`;
      expect(f.text, said).not.toMatch(/\bselect-text\b/);
    }
  });
});

describe("the app's own dragging survives the ban", () => {
  it("puts back the one thing a blanket ban would have taken away", () => {
    // `-webkit-user-drag: none` stops WebKit painting a ghost of whatever text is under the
    // pointer. It also stops a real HTML drag dead, and the app has two of those: a composition
    // dragged into a folder, and footage dragged onto the timeline.
    const back = /\[draggable\]:not\(\[draggable="false"\]\)\s*\{[^}]*-webkit-user-drag:\s*element/;
    expect(css).toMatch(/-webkit-user-drag:\s*none/);
    expect(css).toMatch(back);
  });

  it("is not a rule about nothing", () => {
    // If the app stops dragging anything, the rule above should go rather than sit there being
    // true. And if a component starts writing `draggable={something}`, the selector stops
    // matching it -- which is silent everywhere except here.
    const dragging = code.filter((f) => /\bdraggable\b/.test(f.text));
    expect(dragging.length).toBeGreaterThan(0);
    for (const f of dragging) {
      const odd = f.text.match(/draggable=\{(?!true\})[^}]*\}/g) ?? [];
      expect(odd, `${f.p} sets draggable to something the stylesheet cannot match`).toEqual([]);
    }
  });
});
