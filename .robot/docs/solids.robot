*** Settings ***
Documentation    Solids
...
...    Agents need to build 3D objects from scratch, correctly: a buoy, a hull, a chain, not a cylinder
...    standing in for one. Solids are constructive solid geometry as data. A tree of plain Lua values
...    names primitives, 2D profiles, booleans and transforms. [Manifold](https://github.com/elalish/manifold)
...    builds the tree into a mesh that is watertight by construction, inside the engine, in the resolve
...    phase, once per tree. LuaCAD (an OpenSCAD dialect in Lua) was the prompt for this. We took its shape
...    (a CAD vocabulary in Lua) without its route (writing OpenSCAD and shelling out), because Manifold
...    links into Rust directly, is the kernel OpenSCAD itself now uses, and keeps a comp a pure function
...    of time.
Metadata    Source    cadence@56ddad1:docs/SOLIDS.md

*** Test Cases ***
The path
    [Documentation]    ```
    ...    assets = { { id = "buoy", solid = TREE } } \ \ \ \ \ \ \ \ \ -- rows (core/moonsplice/rows.lua)
    ...    \ \ -> s:solid(TREE) \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ -- core/moonsplice/init.lua, a compile hook
    ...    \ \ -> core/runtime/solid.lua: canonical JSON, sha1 -> ~/.cache/moonsplice/solids/<sha>.{msh,gltf,info.json}
    ...    \ \ -> MOONSPLICE_ENGINE.solid(json, out) \ \ \ \ \ \ \ \ \ \ \ \ \ -- engine/src/solid.rs
    ...    \ \ -> moonsplice-solid (solid/): Manifold builds, measures, writes MSH1 + glTF
    ...    mesh node src = "asset:buoy" \ or \ entity row solid = "asset:buoy"
    ...    \ \ -> core/runtime/worldbevy.lua: row.solid = the .msh path
    ...    \ \ -> render/src/world.rs: row kind "solid:<path>", read_msh -> a Bevy Mesh, cached per path
    ...    ```
    ...
    ...    A solid is authored Z-up in metres, as CAD is, and exported Y-up for Bevy: (x, y, z) -> (x, z, -y).
    ...    MSH1 is little-endian: `"MSH1"`, u32 vertex count, u32 triangle count, then per vertex a position and
    ...    a normal (6 f32), then the triangles (3 u32 each). The glTF beside it is for other tools.
    ...
    ...    `moonsplice-solid TREE.json OUT.msh` builds one tree from the shell and prints its measurements.
    [Tags]    doc    source:cadence@56ddad1:docs/SOLIDS.md
    Skip    prose

The vocabulary
    [Documentation]    The agent card (.robot/docs/reference.robot, "Solids") is the reference. In short:
    ...
    ...    - **3D:** cube/box, sphere, cylinder/cone, torus, capsule, extrude (with twist and scale_top), revolve.
    ...    - **Booleans:** union, difference, intersection, hull, group, minkowski.
    ...    - **Modifiers:** smooth (Manifold's smooth_out and refine), repeat (n copies, each a step on from the
    ...    \ \ last), radial, mirror, trim (by a plane).
    ...    - **2D profiles:** points, circle, square, polygon, offset, and the 2D booleans.
    ...    - **Transforms:** every node takes scale, rotate (degrees) and move, applied in that order.
    [Tags]    doc    source:cadence@56ddad1:docs/SOLIDS.md
    Skip    prose

Measurements are the agent's check
    [Documentation]    A build returns what the solid came out as: `parts`, `genus`, `watertight`, `volume`, `area`,
    ...    `triangles`, and `min`/`max`/`size` (Y-up). `moonsplice rows COMP --json` lists them under
    ...    `solids`. They catch the mistakes a model makes and cannot see in a render. The first buoy in
    ...    comps/cases/solids.lua measured `parts = 2`: its lifting eye sat 1 cm above the top and floated
    ...    free. A wrong `size` means a wrong scale.
    [Tags]    doc    source:cadence@56ddad1:docs/SOLIDS.md
    Skip    prose

Lessons
    [Documentation]    - **Normal channel:** Manifold 3 counts property channels after the position, so normals go in at
    ...    \ \ channel 0 (`calculate_normals(0, …)`), which puts them in vertex properties 3..6. Channel 3 left
    ...    \ \ every normal zero, and Bevy drew the solids unshaded. The cache key carries the format version
    ...    \ \ (`msh2|`) so meshes built wrong are not reused.
    ...    - **Light kind:** building this case found that worldbevy chose a light's kind by `ci.x and "point"`.
    ...    \ \ Every node carries `x = 0`, so every authored light had been a point light at the world's origin,
    ...    \ \ 2.9 Mcd, with `dir` ignored. A light is now directional unless `type` says point or spot. `dir` is
    ...    \ \ the way the light travels, and the defaults now come from behind a camera on +z.
    [Tags]    doc    source:cadence@56ddad1:docs/SOLIDS.md
    Skip    prose

