*** Settings ***
Documentation    Moonsplice API card (Lua, rows form). Exact. If it is not listed here, it does not exist.
...
...    A comp is rows (.robot/docs/rows.robot, schema msr/1): nodes, keys, motion, systems, assets, facts, input, game.
...    You edit an existing comp only with typed patches (below). Write a whole file only when there is no comp yet,
...    and then in this form. The object API (s:rect{}, s:script, s:view) still runs old comps but is not for you:
...    its closures dump as opaque systems that no patch can edit.
Metadata    Source    cadence@56ddad1:agent/REFERENCE.md

*** Test Cases ***
Comp skeleton (passes lint + check)
    [Documentation]    Summary: the whole shape of a rows comp (comp settings, nodes, keys, systems, assets, expect), as a template that passes lint and check.
    ...    ```lua
    ...    local e = require("moonsplice")
    ...    local F = "/Users/shinyobjectz/cadence/evals/longform/Footage/"
    ...    local S = "/Users/shinyobjectz/cadence/evals/longform/Sound/"
    ...    local FONT = "/Users/shinyobjectz/cadence/evals/assets/fonts/"
    ...
    ...    return e.comp {
    ...    \ \ width = 1920, height = 1080, duration = 6, fps = 30, background = "#0b0d12",
    ...
    ...    \ \ assets = {
    ...    \ \ \ \ { id = "bed", src = S .. "music-bed.mp3", derive = { beats = true } }, \ -- facts beat:1, beat:2, ...
    ...    \ \ },
    ...
    ...    \ \ nodes = { \ \ -- draw order = list order; a parent comes before its children
    ...    \ \ \ \ { id = "clip", kind = "video", src = F .. "07-harbour-sunset-boats.mp4", x = 960, y = 540, w = 1920, h = 1080,
    ...    \ \ \ \ \ \ anchor = "center", media_start = 10 },
    ...    \ \ \ \ { id = "field", kind = "rect", x = 0, y = 560, w = 1920, h = 520, color = "#0b0d12e6" },
    ...    \ \ \ \ { id = "mask", kind = "rect", x = 120, y = 740, w = 0, h = 160, opacity = 0 },
    ...    \ \ \ \ { id = "title", kind = "text", x = 120, y = 760, text = "Harbour, 19:40", size = 110,
    ...    \ \ \ \ \ \ font = FONT .. "Roboto-Bold.ttf", color = "#f4f1ea", clip_node = "mask" },
    ...    \ \ \ \ { id = "rule", kind = "rect", x = 120, y = 920, w = 2, h = 4, color = "#f2a541" },
    ...    \ \ \ \ { id = "music", kind = "audio", src = S .. "music-bed.mp3", at = 0, duration = 6, volume = 0.6, fade_in = 0.3, fade_out = 1 },
    ...    \ \ },
    ...
    ...    \ \ keys = { \ \ \ -- { id, prop, t, value, ease? }: eased from the previous key of (id, prop) to this one
    ...    \ \ \ \ { "mask", "w", 0.3, 0 }, { "mask", "w", 1.2, 1300, "expoOut" },
    ...    \ \ \ \ { "rule", "w", "beat:1", 2 }, { "rule", "w", "beat:3", 860, "cubicInOut" },
    ...    \ \ \ \ { "clip", "scale", 0.3, 1 }, { "clip", "scale", 6, 1.12, "sineInOut" },
    ...    \ \ },
    ...
    ...    \ \ systems = { -- pure functions run every frame after the keys; the rows they return are that frame's props
    ...    \ \ \ \ { name = "rule-under-title", order = 1, source = [[
    ...    \ \ \ \ \ \ return function(t, state, q)
    ...    \ \ \ \ \ \ \ \ return { { id = "rule", y = q.y("title") + 160 } }
    ...    \ \ \ \ \ \ end ]] },
    ...    \ \ },
    ...    }
    ...    ```
    ...    Comp fields: width, height, duration (s) required; fps=30, background="#000000", seed, color_space="oklab"|"hsluv"|"okhsl"|"rgb", lint_allow={codes}.
    ...    - node row: id (stable string, required), kind (required), parent (a node id), then the kind's props (below). References (parent, clip_node, camera, flex items) are ids, never handles.
    ...    - Values are numbers, strings, booleans, or arrays/objects of those. Colours are strings or {r,g,b,a}.
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Keys and motion
    [Documentation]    Summary: keyframes (id, prop, t, value, ease), times as seconds or facts (beat:4), the eases, and motion curves (path, wiggle, follow, spring, drop).
    ...    - key { id, prop, t, value, ease? }. Before the first key the prop holds the first key's value; after the last, the last. Two keys at one (id, prop, t) are an error.
    ...    - t is seconds or a fact reference: "beat:12" (the 12th beat of any asset with derive beats), "beat:3+0.25" (offset s), "word:tide#2" (2nd "tide" from derive words), "onset:N", "silence:N".
    ...    - ease "step", and every key on text, src or font, switches at its time; before it the prop is at rest.
    ...    - Animatable: x y w h r rx rotation scale opacity color size progress tracking reveal outline weight amp freq mix; effect_*; fx_*; yaw pitch roll dolly fov aperture maxcoc focus_u focus_v truck_u truck_v look_x look_y look_z cam_x cam_y cam_z z; a clip's speed and time. Keys on text/src/font step. Anything else: a node prop or a system.
    ...    - Eases: linear; quad cubic sine expo back elastic bounce, each + In|Out|InOut; "spring(180,12)" (stiffness, damping[, mass]); "cubicBezier(0.2,0,0,1)".
    ...    - motion { id, prop, t0, t1, curve, params } for what is not key to key:
    ...    \ \ curve="path", prop="xy", params={points={{x,y},...}, ease}: a smooth path from the node's x,y at t0.
    ...    \ \ curve="wiggle", params={amp=10, freq=1.5, seed, ramp=0.25}.
    ...    \ \ curve="bake", params={samples={...}} (values sampled evenly over t0..t1).
    ...    \ \ t0/t1 may be fact references.
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Systems and code
    [Documentation]    Summary: systems are sandboxed source text run every frame after the keys, returning rows; q and shared; code props ({fn=}).
    ...    Code is source text in a sandbox (no io, os clocks or math.random), never a Lua function value.
    ...    - system { name, order, source }: source returns function(t, state, q) -> list of rows { id=node, prop=value, ... }.
    ...    \ \ Rows set props for that frame only (cleared before the next). Systems run in order; a later one sees an earlier one's rows.
    ...    - q (also a global in every piece of code): q.get(id, prop), shorthand q.x(id) q.y(id) q.opacity(id) ...; q.state (game state, false in videos); q.fact("beat:3") -> seconds; q.all(pred) -> fact rows; q.t.
    ...    - A system named "shared" (order 0) runs once and returns a table; every other piece of code reads it as the global `shared` (constants, palettes, helper functions).
    ...    - Sandbox globals: math, string, table, ipairs, pairs, select, tostring, tonumber, type, unpack, ease(name) -> f(0..1), lerp(a,b,k), clamp(x,a,b), color(c) -> {r,g,b,a}, shared, q.
    ...    - A code prop is { fn = "<source>" } where source returns the function the kind expects: a vector's draw = { fn = [[ return function(v, t) ... end ]] }.
    ...    - A system row whose id is not a node and whose parent is a world spawns a Bevy entity for that frame (see 3D).
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Composition: clips, tracks, transitions, precomps, isolation, mattes
    [Documentation]    Summary: time containers (clip: start, duration, offset, speed or a speed ramp, time remap, loop, hold, reverse), tracks that lay clips end to end, transitions over their overlap, precomps of other rows comps, isolated layers, and track mattes.
    ...    ```lua
    ...    \ \ nodes = {
    ...    \ \ \ \ { id = "reel", kind = "track", x = 40, y = 40, w = 720, h = 405, transition = { kind = "crossfade", duration = 0.6 } },
    ...    \ \ \ \ { id = "dawn", kind = "clip", parent = "reel", duration = 3.2 },
    ...    \ \ \ \ { id = "dawn_title", kind = "text", parent = "dawn", x = 48, y = 280, text = "Dawn", size = 84 },
    ...    \ \ \ \ { id = "dusk", kind = "clip", parent = "reel", duration = 2.9, transition = { kind = "wipe", duration = 0.5, dir = "right" } },
    ...    \ \ \ \ { id = "ramp", kind = "clip", x = 820, y = 70, start = 0.2, duration = 7.6, loop = true, length = 2 },
    ...    \ \ \ \ { id = "ball", kind = "circle", parent = "ramp", x = 10, y = 30, r = 16, color = "#f2a541" },
    ...    \ \ \ \ { id = "card1", kind = "precomp", src = "card.lua", x = 820, y = 420, start = 0.4 },
    ...    \ \ \ \ { id = "fade", kind = "group", isolate = true },
    ...    \ \ \ \ { id = "word", kind = "text", x = 40, y = 452, text = "TIDE", size = 220 },
    ...    \ \ \ \ { id = "waves", kind = "group", matte = "word" },
    ...    \ \ },
    ...    \ \ keys = { { "dawn_title", "x", 0.15, 90 }, { "dawn_title", "x", 1, 48, "expoOut" }, \ \ -- local to dawn
    ...    \ \ \ \ { "ramp", "speed", 0.2, 0.3 }, { "ramp", "speed", 4.6, 2.4, "sineInOut" }, \ \ \ \ \ \ \ \ \ -- comp time: a ramp
    ...    \ \ \ \ { "ball", "x", 0, 10 }, { "ball", "x", 2, 390 }, { "card1/label", "opacity", 2.8, 0 } },
    ...    ```
    ...    - clip{start=0 (parent seconds, or a fact: "beat:8"), duration (parent s; none = to the end), offset=0 (local s at start: trims the head), speed=1 (key it for a ramp: it is integrated), time (key it to remap: the local s at each parent s; replaces offset and speed), loop + length (local s that repeat), hold=false|true|"start"|"end" (freeze the first/last frame outside the range), reverse (needs duration), isolate=true, and a group's x y scale rotation opacity}. Children: parent = the clip.
    ...    - Time: a clip's own keys (x, opacity, speed, time) are in its PARENT's time. Everything under it is in its LOCAL time: keys, motion, a video's from/media_start, particles' emit, a world, and a system with clip = "<id>". Clips nest and compose. Outside its range the clip and everything in it draw nothing. `rows --brief` prints each clip's comp range and every key as `0@1.00s (comp 5.00s)`.
    ...    - Sound under a clip is placed in comp time when built, trimmed to the clip; only a clip at speed 1 (no ramp, remap, loop or reverse) may hold audio.
    ...    - track{x,y,w,h (its frame; default the comp), start=0, transition = default for every cut}: holds only clips, which play end to end in draw order: each starts where the one before ends, less its transition's duration (the overlap). A clip in a track has no start (an error): use gap (space before it) or overlap (with no transition). Every clip but the last needs a duration. Trim with set_prop duration, reorder with move_clip: the rest ripple. What falls outside the track's box is cut.
    ...    - transition = { kind, duration, ease, dir, color } on the incoming clip (or on the track; false = a cut). crossfade (an exact dissolve), dip (through color, default black), wipe (the edge travels in dir, default right), push (both move in dir, default left), slide (the incoming slides over), zoom. Ease: linear for crossfade and dip, cubicInOut otherwise.
    ...    - precomp{src = a rows comp file (relative to this comp's file), and every clip prop}: a clip of that comp. length and duration default to its duration, w,h to its size; cut to its box; its background is not drawn. Its nodes are <id>/<child>: key them from here in its local time; its systems and expectations run in its local time. A game cannot be a precomp.
    ...    - isolate: a clip, precomp or track draws as one layer, its opacity, blend and effects applied once (isolate = false opts out); a group only with isolate = true. A fading group without it fades each child, and overlaps show through.
    ...    - matte = "<node id>", matte_mode = "alpha"|"alpha_inverted"|"luma"|"luma_inverted": this node (a group or clip as one layer) shows only through that node, which is not drawn itself.
    ...    - q.time(id) is a clip's local time. Games take no clips, tracks or precomps.
    ...    - Exemplar: comps/cases/composition.lua (reel with crossfade and wipe, speed ramp, isolated fade, precomp twice, alpha matte).
    [Tags]    doc    source:cadence@f91db8b:agent/REFERENCE.md
    Skip    prose

Games: the game table plus systems game.init and game.step
    [Documentation]    Summary: a game is a fold over input (game.init, game.step, Rapier physics) whose state systems draw; autopilot, input logs.
    ...    ```lua
    ...    \ \ game = { rate = 60, seed = 7 },
    ...    \ \ input = { { t = 0.5, down = "right" }, { t = 3, up = "right" }, { t = 4, down = "space" }, { t = 4.1, up = "space" } },
    ...    \ \ nodes = {
    ...    \ \ \ \ { id = "ship", kind = "circle", x = 640, y = 360, r = 20, color = "#f2a541" },
    ...    \ \ \ \ { id = "hud", kind = "text", x = 120, y = 110, text = "0", size = 36, color = "#e9e1cf" },
    ...    \ \ },
    ...    \ \ systems = {
    ...    \ \ \ \ { name = "game.init", order = 1, source = [[ return function(st, g) st.x, st.y, st.score = 640, 360, 0 end ]] },
    ...    \ \ \ \ { name = "game.step", order = 2, source = [[
    ...    \ \ \ \ \ \ return function(st, input, g)
    ...    \ \ \ \ \ \ \ \ local dx = (input.held.right and 1 or 0) - (input.held.left and 1 or 0)
    ...    \ \ \ \ \ \ \ \ st.x = math.max(20, math.min(1260, st.x + dx * 300 * g.dt))
    ...    \ \ \ \ \ \ \ \ if input.pressed.space then st.score = st.score + g.random(1, 3) end
    ...    \ \ \ \ \ \ end ]] },
    ...    \ \ \ \ { name = "view", order = 3, source = [[
    ...    \ \ \ \ \ \ return function(t, st)
    ...    \ \ \ \ \ \ \ \ return { { id = "ship", x = st.x, y = st.y + math.sin(t * 2) * 30 }, { id = "hud", text = tostring(st.score) } }
    ...    \ \ \ \ \ \ end ]] },
    ...    \ \ },
    ...    ```
    ...    - game: rate=60 steps/s, seed=1. game.init(state,g) once; game.step(state,input,g) is the ONLY place state changes. Systems read state (2nd arg, or q.state) and never write it.
    ...    - input rows play the game unattended: always give a log spanning the duration (or an autopilot in the state). Events: {t,down="k"} {t,up="k"} {t,x,y} {t,x,y,press=true} {t,x,y,release=true}.
    ...    - input (in game.step): held[k], pressed[k] (this step), released[k], pointer={x,y,down}, events. Keys: up down left right space enter shift tab a..z "0".."9"; pressed.pointer.
    ...    - g: dt, n (step), t, random() in [0,1), random(a,b) int a..b, random(n) int 1..n, physics{gravity=980, gravity_x=0}.
    ...    - physics (px, y down): w:box{x,y,w=32,h=32,angle,kind="dynamic|static|kinematic",damping,angular_damping,density=1,friction=.5,restitution=0,sensor,bullet,fixed_rotation}->id; w:ball{x,y,r=16,...}->id; w:step(g.dt); w:get(id)->x,y,angle,vx,vy,spin; w:set(id,{x,y,angle,vx,vy,spin}); w:impulse(id,ix,iy); w:torque(id,t); w:remove(id); w:contacts()->{{a,b},...} begun last step; w:count().
    ...    - Exemplar: comps/cases/game_harbour.lua (shared, game.init, game.step, hud, and a vector draw that reads q.state).
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

The moves (moonsplice patch COMP PATCHES.json --json)
    [Documentation]    Summary: every typed move (add_node, set_prop, keys, bind, systems, derive, solid, move_clip, remove) with its payload, and what a patch replies.
    ...    PATCHES.json is a list; each item has move = one of:
    ...    - {move="add_node", node={id, kind, parent?, order?, ...props}}
    ...    - {move="set_prop", id, name, value} \ (value null removes the prop; name may be parent or order)
    ...    - {move="add_key", id, name, t, value, ease?} · {move="move_key", id, name, t, to_t?, value?, ease?} · {move="drop_key", id, name, t}
    ...    - {move="bind", id, name, t, fact="beat:4"} \ (moves that key to the fact's time)
    ...    - {move="add_system", name, source, order?, clip?} · {move="edit_system", name, source?, order?, clip?} \ (clip: run in that clip's local time; "" clears)
    ...    - {move="move_clip", id, index | before | after} \ (a clip's place in its track; the rest ripple)
    ...    - keys may name a precomp's inner node, "card1/label", in the precomp's local time
    ...    - {move="derive", asset={id, src, derive={...}}}
    ...    - {move="solid", asset={id, solid=TREE}} \ (a solid built by Manifold; see "Solids" below)
    ...    - {move="remove", id} (the node, its children, props, keys, motion and references) · {move="remove", system=name}
    ...    Each patch is checked: the comp must still compile and evaluate. The reply is {applied, rejected[{patch, why}], touched, digest_before, digest_after, findings}.
    ...    Read a comp with `moonsplice rows COMP --json` (tables, digest, derived facts, and each solid's measurements); see it with `moonsplice sheet COMP OUT.png --json`.
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Node kinds: { id=, kind="<kind>", ...props }
    [Documentation]    Summary: every 2D node kind and its props (text, rect, image, video, audio, vector, html, ...), common props, blends, colours.
    ...    All visual nodes: x, y (px), anchor="topleft"|"center", opacity=1, rotation=0 (rad), scale=1, parent, blend, clip_node, clip_invert, matte, matte_mode, effects, shadow, id. Rotate/scale pivot = x,y (anchor="center" pivots on the middle). circle x,y = centre.
    ...    - rect{x,y,w,h,color,rx} ; surface{w,h required, same as rect}.
    ...    - circle{x,y,r,color}.
    ...    - text{x,y,text,size=32,font=path,color=white,wrap=px,leading=mult,tracking=px,reveal=0..1,outline,outline_color,weight}. Tags: {c:#rrggbb}..{/c} {b}..{/b} {i}..{/i}. outline ~0.3-1.2, weight 0-0.3.
    ...    - kinetic{x,y,text,size=64,spacing=0,font,color,opacity,rotation,scale} -> .chars = per-char text nodes, row centred on x. Its characters are nodes <id>.1, <id>.2, ... (spaces skipped): key them or move them from a system. ASCII only.
    ...    - captions{x,y,size=36,font,color,cues={{t0,t1,"text"},...}} (or src=SRT/CSV).
    ...    - video{src (req),x,y,w,h (default comp size),anchor,from=0 (comp start),duration=comp.duration-from,media_start=0 (source s),rx,derive={...}}. Cover-crops to w×h; drawn only in [from,from+duration). Silent: add an audio node with the same src.
    ...    - image{src,x,y,w,h (default comp size),rx}; image{prompt="...",seed,w,h} generates a still once (MiniMax image-01; needs a MiniMax key, else the build fails); svg{src,w,h required}; page{src|html,w,h}.
    ...    - html{html=markup|src, w,h required, progress}: {{progress}} / {{progress_int}} substituted; tween progress.
    ...    - vector{x,y,w,h required, draw=function(v,t) ... end}: local coords, clipped. v:rect(x,y,w,h,c,radius) v:circle(cx,cy,r,c) v:move(x,y) v:line(x,y) v:curve(x1,y1,x2,y2,x,y) v:fill(c) v:stroke(width,c) v:polyline({x1,y1,x2,y2,...},width,c) v:gradient(x,y,w,h,x0,y0,x1,y1,c0,c1) v:radial(cx,cy,r,c0,c1) v:grain(amount,seed).
    ...    - group{x,y,scale,rotation,opacity,isolate}: children parent=g, x,y relative to it; opacity multiplies, per child unless isolate = true (one layer). clip, track, precomp: see Composition.
    ...    - flex{items={nodes},x,y,w,h,dir="row"|"column",justify="start|center|end|between|around|evenly",align="start|center|end|stretch",gap,pad,wrap}: static, sets items' x,y.
    ...    - fx{x,y,w,h required, chain={names}, amounts}: children parent=plate (plate-local px). chain names: bloom glow blur vignette chroma grain tonemap pixelate posterize filmgrain kawase worley shadertoy. Amounts: bloom= glow= blur= ... worley= (key fx_<name>; filmgrain uses grain, kawase blur). shadertoy=GLSL mainImage string (iChannel0, iTime, iResolution; GPU build only).
    ...    - particles{x,y,n (req),seed=1,life=1.2,emit=0 (comp-absolute start s),emit_window=0.2,heading=-pi/2,spread=pi,speed=240,gravity=520,r=3.5,color}.
    ...    - chart{type="bar|stack|line|area|pie|arc",data (req),data1,mix=0,reveal=1,w=420,h=240,color,colors,hue,sat,stroke="clean"|"rough",seed,width,inner,start,track}.
    ...    - ornament{kind="star|compass|egg|linker",w=180,h=180,color,width=2.5,reveal=1,n (star points),stroke,seed}.
    ...    - lottie{src,w,h required,from,duration,loop=true,speed,media_start}. spritesheet{src=png|aseprite json,fps,loop,from,w,h,cols,rows,frame_w,frame_h}.
    ...    - displace{src=image | text=,size,color,font; w,h required, cols=24,rows=16,amp=14,freq=1}
    ...    - perspective=true (rect|surface|image|svg|page|video only): yaw,pitch,roll,dolly,fov,aperture (defocus),maxcoc,focus_u,focus_v,truck_u,truck_v (0..1),persp_margin, camera="<id of a camera node>" (kind camera: yaw,pitch,roll,dolly=1,fov=0.62,aperture=0; shared).
    ...    - audio{src (req),at=0,duration=file length,media_start=0,volume=1,fade_in=0,fade_out=0,bus="vo",duck=true|{threshold,ratio,attack,release},follow=true,derive={loudness=-14,denoise=..}}. duck: sidechain under bus="vo" clips. follow=true makes its energy available (object API only).
    ...    - tts{text,provider="minimax"|"elevenlabs"|"onnx",voice}, sfx{prompt}, music{prompt}: network + key (onnx is local); prefer local files.
    ...
    ...    blend: alpha normal multiply screen overlay darken lighten color-dodge color-burn hard-light soft-light difference exclusion hue saturation color luminosity add. clip_node=node: clip to its live rect (same parent space); clip_invert=true: outside only. shadow={blur=40,dy=10,alpha=0.3} on nodes with w,h. effects={blur,brightness,contrast,saturate,grayscale,sepia,invert,opacity,hue_rotate} (tween effect_<name>; neutral 0,1,1,1,0,0,0,1,0).
    ...    Colours: "#rgb" "#rgba" "#rrggbb" "#rrggbbaa" or {r,g,b,a} 0..1; no names. e.palette{n=5,h=210,s=72,l0=32,l1=78} -> OKHSL ramp of colours.
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

3D: a world node (Bevy PBR)
    [Documentation]    Summary: a Bevy world: camera, lights (dir is the way light travels), meshes and materials, what is keyable, and entities a system spawns.
    ...    world{x,y,w,h (req),anchor, cam_x=0,cam_y=0.35,cam_z=3.2, look_x,look_y,look_z=0, yaw,pitch (orbit camera about look), fov=0.7, near, far, background="#rrggbb", ambient=160 (brightness), ambient_color, bloom (e.g. 0.2; off if unset), fog={color,start=5,["end"]=40}, tonemapping="agx"|"aces"|"reinhard"|"tony"|"blender"|"none"}. Key cam_*, look_*, yaw, pitch, fov.
    ...    Children (nodes with parent = the world): mesh{primitive="cube|box|sphere|plane|cylinder|capsule|cone|torus" | src="file.gltf" | src="asset:<solid id>", x,y,z (y up),yaw,pitch,roll,scale,size={sx,sy,sz} (a mesh's size is always three numbers),color,emissive,emissive_strength=1,metallic=0,roughness=0.5,reflectance=0.5,unlit,double_sided,detail=24}; light{dir={-.4,-1,-.3}, intensity=1 (×3500), color} is a directional light (a sun) unless type="point"|"spot".
    ...    Assemblies: a mesh or light may have parent = another mesh in the world. Its x,y,z, yaw,pitch,roll and scale are then in that mesh's frame (size stays its own), so a buoy's band, topmark and lamp parented to its body move and roll with it: a system sets the body alone, with no trig for the parts. Never move the parts of one object with separate rows; they drift apart.
    ...    dir is the way the light TRAVELS. The camera usually sits on +z looking toward -z, so a key light has dir z < 0 (it comes from behind the camera); dir z > 0 shines into the lens: faces toward the camera go dark, and a glossy sea mirrors the sun as a glare. Keep a low sun out of the camera's mirror path, or keep it dim.
    ...    Keyable on world children: x,y,z, yaw,pitch,roll, scale, color, opacity, metallic, roughness, reflectance, emissive_strength, intensity (and the world's cam_*, look_*, fov). Not keyable: primitive, src, size, dir, emissive, type: set those with set_prop, or drive them from a system.
    ...    Entities from a system: a system returns rows. A row whose id is a node sets that node's props. A row whose id is NOT a node must carry parent = <the world's id>, and is spawned as a Bevy entity for that frame only, keyed by id (return it again every frame it should exist). Without parent the patch is rejected ("set no node X (give a world parent to spawn an entity)"). An entity row: shape (as primitive) or solid="asset:<solid id>", pos={x,y,z}, yaw,pitch,roll, scale, size={sx,sy,sz}, the material props above; or a light row: light="directional"|"point"|"spot", color, intensity (directional lux 8000; point/spot 800000), dir, pos, range=20, radius, angle=0.6, softness=0.7, shadows=true. No light -> default sun.
    ...    So to flash a lamp, either key the lamp node's emissive_strength, or have a system return { id="lamp", emissive_strength=... } every frame; to add a glow light, return { id="glow", parent="<world>", light="point", pos={...}, intensity=... }. In a game, read q.state.
    ...    Exemplar: comps/cases/world_bevy.lua (two mesh nodes, a "ring" system spawning 24 pillars, a floor and two lights).
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Solids: build 3D objects from scratch (Manifold CSG, build time, cached)
    [Documentation]    Summary: CAD as data: a tree of primitives, profiles, booleans and transforms built by Manifold into a mesh, and its measurements to check.
    ...    An asset with solid = TREE (and parts = n when it is meant to be n separate pieces) is built into a watertight mesh once (cached by the tree's hash). Show it with a mesh node src="asset:<id>", or a system entity solid="asset:<id>". Authored Z-UP in metres, as CAD is (z is height); drawn Y-up, so a revolve's axis stands upright.
    ...    A node is { op=..., params..., children as positional entries or children={...} or child=... }. Every node may also take scale (number or {x,y,z}), rotate={deg x, deg y, deg z}, move={x,y,z}, applied in that order.
    ...    3D ops: cube|box{size={x,y,z}, center=true} · sphere{r} · cylinder{h, r | r1,r2} · cone{h, r1} · torus{r, tube<r} · capsule{r, h} · extrude{profile, h, twist (deg), scale_top, slices} · revolve{profile (points as {radius, height}), degrees=360} · union · difference (first minus the rest) · intersection · hull · group (several parts, no merging) · minkowski (two children) · smooth{child, angle=60, smoothness=0.4, refine=3} · repeat{child, n, step={move,rotate,scale}, union=true} · radial{child, n} (copies round z) · mirror{child, normal={1,0,0}, keep=true} · trim{child, normal={0,0,1}, offset=0} (keeps the side the normal points to). segments=n on round ops (default 48).
    ...    2D profile ops (for extrude and revolve): a list of points {{x,y},...}, or circle{r} · square|rect{size={x,y}} · polygon{points} · offset{child, delta, join="round"|"square"|"miter"} · union|difference|intersection|hull.
    ...    After building, `moonsplice rows COMP --json` lists each solid's measurements: parts, genus, watertight, volume, size={x,y,z} (Y-up, metres), triangles. Check them against what you meant: an object meant to be one piece must have parts=1 (parts>1 means something floats free: a gap of even 1 cm), a ring has genus 1, and size must match the real object's dimensions.
    ...    Model real objects from their real parts and proportions: a can buoy is a revolved profile plus its fender ring, lifting eyes and topmark; a boat hull is the lower half of a hull of ellipsoids minus a smaller copy (a shell), with thwarts cut to the hull by intersection. Exemplar: comps/cases/solids.lua (buoy, bollard, chain of interlocking links, dinghy).
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Derive and facts (build time, cached)
    [Documentation]    Summary: media work and facts made before render (beats, words, stabilize, slowmo, reframe, cutout), and how to bind to them.
    ...    asset { id, src, derive = ops }, or a video/audio node's own derive = { ... }.
    ...    Video ops (run in this order): stabilize=true, deflicker=true, denoise=n|true, slowmo=factor (int), motion_blur=strength, reframe="9:16"|{aspect="9:16",follow="saliency"|"faces"}, cutout="person"|true (alpha .mov). reframe/cutout: macOS only.
    ...    Audio ops: loudness=-14 (LUFS), denoise=nf; facts: beats=true -> beat:N, onset:N; words=true -> word:<text>#k; silence=true -> silence:N.
    ...    Fact times are the asset's SOURCE seconds; a key at "beat:N" lands there in comp time (assets play from 0).
    ...    music-bed.mp3: tempo 112.3, first beat 0.255 s (beat:1), then every 0.534 s.
    ...    Exemplar: comps/cases/rows_tide.lua (a title keyed to beat:2..beat:4, a system holding text on a keyed line, a buoy in a world).
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Local media (absolute paths)
    [Documentation]    Summary: the footage, music and sound on this machine, with their sizes and what is in them.
    ...    Footage /Users/shinyobjectz/cadence/evals/longform/Footage/ (1920x1080 unless noted, a = has audio):
    ...    01-coastal-road-sea.mp4 (1280x720, 123 s) · 02-fishing-harbour-boats.mp4 (36 s, a) · 03-old-town-narrow-street.mp4 (76 s, a) · 04-aerial-view-coastline-vi.mp4 (200 s) · 05-storm-sea-waves.mp4 (108 s, a) · 06-fisherman-nets-boat.mp4 (1280x720, 41 s) · 07-harbour-sunset-boats.mp4 (80 s) · 08-town-lights-night-water.mp4 (283 s) · 09-dock-crane-cargo.mp4 (75 s) · 10-ferry-leaving-harbour.mp4 (59 s, a)
    ...    Sound /Users/shinyobjectz/cadence/evals/longform/Sound/: music-bed.mp3 (112 bpm, 600 s), sfx-rise.mp3 (1.2 s), sfx-thud.mp3 (0.5 s), sfx-tick.mp3 (0.15 s), sfx-whoosh.mp3 (0.7 s).
    ...    Fonts /Users/shinyobjectz/cadence/evals/assets/fonts/ (the ONLY files; any other name fails the build). font is a path, not a family name; no font = Noto Sans.
    ...    \ \ condensed grotesk (data, labels, almanac): BarlowCondensed-Medium.ttf BarlowCondensed-SemiBold.ttf ArchivoNarrow.ttf
    ...    \ \ grotesk: SpaceGrotesk.ttf Roboto-Regular.ttf Roboto-Bold.ttf Roboto-Italic.ttf Roboto-BoldItalic.ttf
    ...    \ \ serif display: DMSerifDisplay-Regular.ttf Fraunces.ttf PlayfairDisplay.ttf
    ...    \ \ serif text/italic voice: InstrumentSerif-Regular.ttf InstrumentSerif-Italic.ttf
    ...    \ \ mono (tabular figures): IBMPlexMono-Regular.ttf JetBrainsMono-Regular.ttf
    ...    Glyphs: → ← only JetBrainsMono/PlayfairDisplay; ✓ only JetBrainsMono; ★ and emoji nowhere. · — – • … € ° × “ ” everywhere.
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

Pitfalls (each fails build, lint or check)
    [Documentation]    Summary: every finding the engine raises (expectations, overflow, cropping, contrast, frozen, overridden keys, solids, composition) and what to do about it.
    ...    - Lint expect_failed (error): the comp's expect rows are what the ask requires (a node that must exist, a text that must read, a value at a time). You cannot edit or remove them, and removing or hiding what they name is an error, never progress. When a critic says "kill" or "remove" something an expectation names, restyle, move or retime it instead.
    ...    - Lint key_overridden (error): systems run after the keys every frame, so a key on a prop a system sets never shows. `moonsplice rows COMP --brief` prints "<system> sets <props> every frame" under each node a system drives: change that system (edit_system), not the node's keys.
    ...    - Check text_overflow (error): a text's real box (measured with its font) runs past the edge of the panel it sits in (the smallest rect, surface, world, image or video holding its start) or the frame. A bigger size or a longer string needs a wider panel, or a smaller size.
    ...    - Lint subject_cropped (warn): a small mesh in a world is cut by, or leaves, the camera's view for over 20% of the piece. Things move (a buoy rides the tide): frame the camera for the whole range of motion, not the first frame.
    ...    - Lint solid_parts (warn): a solid came out in more pieces than meant: something floats free (even a 1 cm gap). Overlap it, or, for pieces meant apart (a chain), declare parts = n on the asset. solid_empty / solid_not_watertight are errors.
    ...    - Lint clip_out_of_range (error): a clip never plays inside the comp, so nothing in it shows. transition_too_long (error): a transition outlasts the clip before or after it. key_outside_clip (warn): a key under a clip at a local time the clip never shows (keys there are LOCAL). track_overlap (warn): a clip overlaps the one before with no transition.
    ...    - Build (composition): start on a clip in a track; a non-clip in a track; loop without length; reverse without duration; a transition on a track's first clip or outside a track; audio under a clip not at speed 1; a precomp of a game, or of itself; any clip in a game.
    ...    - Build: blend "subtract"/"replace"; a key past duration; two keys at one (id, prop, t); a key on a non-animatable prop; a fact reference no asset produces; unknown ease; video/image/audio without src; surface/svg/html/vector/fx/world/lottie/displace without w,h.
    ...    - Pure: os.time/clock/date and io.* error. No math.random in code (frames render in any order); games use g.random.
    ...    - Only anchors "topleft"/"center" (right/bottom: compute x,y). `ls` is ignored: letter-spacing is tracking. Relative paths resolve from the cwd: use absolute paths.
    ...    - Lint frozen_span (error >3 s): visible but static. Per frame Δx/W+Δy/H+Δscale+Δopacity+Δrot/π must reach ~0.002 (a drift under ~6% of W per second is static). A playing video/lottie/particles/world/html or audio excuses it. Lint evaluates systems and games too, so motion a system sets counts. Keep things moving.
    ...    - Lint overshoot_on_opacity: back/elastic/spring on opacity. Use them on x/y/scale.
    ...    - Lint zero_area: w/h/scale ≤ 0 while opacity>0. A clip_node mask starting at w=0 needs opacity=0 (its geometry still clips).
    ...    - Lint contrast_static: text vs comp background (or a full-frame opaque rect) needs 4.5:1, or 3:1 when size×scale ≥ 48.
    ...    - Lint vo_collision: two bus="vo" clips overlap.
    ...    - Check contrast_measured: real pixels on a ring around the text's box (its width estimated from its length, plus half a size each side; ±0.9×size vertically) need 3:1 (size≥48) or 4.5:1. Over footage put a field of alpha ≥ ~0.9 under the whole box and a margin round it.
    ...    - Check nondeterministic: a frame differs on re-render (clock/RNG/state leak).
    ...    - Warns: cold_open (first motion at t=0; start at 0.1-0.3 s), text_min_size (<30 px at 1080p), unknown_anchor.
    ...    - Engine exits 3 naming the node: kind rive; perspective=true outside rect/surface/image/svg/page/video. A node id must be unique; a system must return a list of rows with ids.
    [Tags]    doc    source:cadence@56ddad1:agent/REFERENCE.md
    Skip    prose

