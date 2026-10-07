//! Solids (.robot/docs/solids.robot): Lua calls `MOONSPLICE_ENGINE.solid(tree_json, out_msh) -> info_json`.
//! Manifold builds the tree (solid/), writes OUT.msh and OUT.gltf beside it, and the reply is the
//! solid's measurements, or { error } for a tree it cannot build. core/runtime/solid.lua caches by hash.

use mlua::{Lua, Table};

pub fn answer(tree: &str, out: &str) -> String {
    let r = serde_json::from_str::<serde_json::Value>(tree)
        .map_err(|e| format!("tree is not JSON: {e}"))
        .and_then(|tree| moonsplice_solid::build(&tree, std::path::Path::new(out)).map_err(|e| format!("{e:#}")));
    match r {
        Ok(v) => v.to_string(),
        Err(e) => serde_json::json!({ "error": e }).to_string(),
    }
}

pub fn install(lua: &Lua, t: &Table) -> mlua::Result<()> {
    t.set("solid", lua.create_function(|_, (tree, out): (String, String)| Ok(answer(&tree, &out)))?)?;
    Ok(())
}
