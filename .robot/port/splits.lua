-- How each ported file over the limit is cut, by responsibility. Keys are the file's path in Moonsplice; each plan
-- names the modules it is cut into and which top-level chunks (outline.lua) each takes, as Lua patterns over the
-- chunk's name; `ranges` hand a giant function's branches or a comp's chapters to a module by line (lines of the
-- ported file at the pinned commit, 56ddad1; the cut lands on the nearest statement boundary). What nothing claims
-- stays in `rest`. The port's tests measure every module from the file itself, so a plan that leaves one over the
-- limit fails before anyone cuts anything.
--
-- A file cut in three or more becomes a folder whose init.lua is the rest, so require("painter") still finds it
-- (the engine's package.path gains core/runtime/?/init.lua); a file cut in two gets a sibling.
--
--   [path] = { rest = path, modules = { [path] = { pattern, ... } }, ranges = { [path] = { {a, b} } }?, note }
local P = {}

P["core/runtime/painter.lua"] = {
  note = "paint_node (464 lines) keeps its prologue and dispatch; its per-kind branches become draw(node) and "
    .. "media(node) entries keyed by kind, as DRAW_KIND already is",
  rest = "core/runtime/painter/init.lua",
  modules = {
    ["core/runtime/painter/assets.lua"] = { "^get_yuv_shader$", "^shadow_", "^get_blur$", "^P%.shadow_canvas$",
      "^fonts$", "^Font", "^font$", "^P%.font$", "^img_cache$", "^load_image$", "^node_image$", "^surf_cache$",
      "^surface_image$", "^paint_surface_cursor$", "^get_sdf$" },
    ["core/runtime/painter/kinds.lua"] = { "^DRAW_KIND", "^gcolor$" },
    ["core/runtime/painter/scene.lua"] = { "^scene_shape$", "^scene_imgdata$", "^scene_image$", "^scene_vector$",
      "^comp_render_fps$", "^scene_video$", "^scene_lottie$", "^scene_html$", "^node_box$", "^scene_node$",
      "^scene_text$", "^CHAIN_", "^scene_chain$", "^SCENE_", "^EFFECT_DEFAULTS$", "^PERSP_KINDS$", "^scene_owns$",
      "^P%.scene_owns$" },
    ["core/runtime/painter/fx.lua"] = { "^apply_fx$", "^OFFLINE_SLATE$", "^paint_offline$", "^draw_surface$",
      "^blend_modes$", "^set_node_blend$" },
  },
  ranges = {
    ["core/runtime/painter/draw.lua"] = { { 1117, 1190 }, { 1254, 1359 } },   -- flex, rect, circle, text; vector, world
    ["core/runtime/painter/media.lua"] = { { 1191, 1253 }, { 1360, 1494 } },  -- video; html, image, rive, displace
  },
}

P["core/moonsplice/rows.lua"] = {
  note = "the json, copy and sort helpers the parts share become fields of rows/init.lua",
  rest = "core/moonsplice/rows/init.lua",
  modules = {
    ["core/moonsplice/rows/scene.lua"] = { "^R%.scene$", "^R%.game$", "^derived_facts$", "^R%.fact_time$", "^SAFE$",
      "^R%.load_system$" },
    ["core/moonsplice/rows/moves.lua"] = { "^MOVES", "^NUMBER$", "^STRING$", "^check_value$", "^R%.check_value$",
      "^key_time$", "^key_at$", "^R%.MOVES$", "^R%.apply$", "^find$", "^node_of$", "^subtree$" },
    ["core/moonsplice/rows/dump.lua"] = { "^hex$", "^plain$", "^R%.dump$", "^IDENT$", "^LUA_KEYWORDS$", "^lua_key$",
      "^lua_val$", "^lv$", "^COMP_FIRST$", "^R%.lua$" },
  },
}

P["core/moonsplice/init.lua"] = {
  note = "init.lua keeps Node and the module table; Scene's verbs, the recorder and Comp are siblings it requires",
  rest = "core/moonsplice/init.lua",
  modules = {
    ["core/moonsplice/kinds.lua"] = { "^Scene:derive$", "^Scene:solid$", "^Scene:view$", "^Scene:lottie$",
      "^Scene:fx$", "^Scene:sprite", "^Scene:particles$", "^Scene:chart$", "^Scene:ornament$", "^Scene:captions$",
      "^Scene:spine$", "^Scene:rive$", "^Scene:camera$", "^Scene:world$", "^Scene:mesh$", "^Scene:light$",
      "^Scene:displace$", "^Scene:draw$", "^Scene:script$" },
    ["core/moonsplice/scene.lua"] = { "^Scene", "^wrote_at$", "^M%.BLENDS$", "^BLEND_INSTEAD$", "^add$" },
    ["core/moonsplice/rec.lua"] = { "^Rec", "^resolve_from$", "^record$", "^SETTABLE$" },
    ["core/moonsplice/comp.lua"] = { "^Comp", "^M%.comp$", "^NO_STATE$" },
  },
}

P["core/moonsplice/lint.lua"] = {
  note = "L.run (834 lines) keeps its setup and sampling; each `-- ====` rule family becomes a function of the "
    .. "sampled state (states, add, opts) in its own module, called in the same order",
  rest = "core/moonsplice/lint/init.lua",
  ranges = {
    ["core/moonsplice/lint/motion.lua"] = { { 328, 515 } },   -- motion rules, segment metadata
    ["core/moonsplice/lint/frame.lua"] = { { 516, 671 } },    -- geometry, colour and brand
    ["core/moonsplice/lint/audio.lua"] = { { 672, 736 } },
    ["core/moonsplice/lint/world.lua"] = { { 737, 842 } },    -- solids, 3D framing, keys a system overrides
    ["core/moonsplice/lint/expect.lua"] = { { 843, 894 } },   -- the ask as predicates
  },
}

P["core/runtime/resolve.lua"] = {
  note = "R.media (318 lines) stays whole in resolve/init.lua; what it calls moves out",
  rest = "core/runtime/resolve/init.lua",
  modules = {
    ["core/runtime/resolve/voice.lua"] = { "^elevenlabs_key$", "^VOICES$", "^verify_audio$", "^tts_",
      "^chars_to_words$", "^moonsplice_audio_bin$", "^music_generate$", "^sfx_generate$", "^normword$",
      "^align_generate$" },
    ["core/runtime/resolve/probe.lua"] = { "^probed$", "^file_size$", "^probe_", "^ffprobe_duration$",
      "^bake_energy$" },
    ["core/runtime/resolve/fetch.lua"] = { "^cache_root$", "^exists$", "^MEDIA_EXT$", "^localize$",
      "^R%.localize$", "^R%.layout$" },
    ["core/runtime/resolve/offline.lua"] = { "^WHY_OFFLINE$", "^R%.why_offline$", "^went_offline$" },
  },
}

P["core/runtime/serve.lua"] = {
  note = "serve's JSON encoder duplicates moonsplice.json; prefer deleting it for that module over moving it",
  rest = "core/runtime/serve/init.lua",
  modules = {
    ["core/runtime/serve/json.lua"] = { "^esc$", "^qstr$", "^num$", "^enc_", "^encode$", "^S%.encode$" },
    ["core/runtime/serve/outline.lua"] = { "^humanise$", "^S%.humanise$", "^clip$", "^label_of$", "^CLI_ONLY$",
      "^onscreen_of$", "^WHERE_A_FILE_IS$", "^S%.outline$", "^S%.at$" },
  },
}

P["core/runtime/main.lua"] = {
  note = "main keeps the frame loop (love.run) and the modes; argument and comp loading, and the offline render, "
    .. "become siblings",
  rest = "core/runtime/main.lua",
  modules = {
    ["core/runtime/args.lua"] = { "^parse_args$", "^abs_path$", "^read_inputs_json$", "^merge_kv$",
      "^resolve_inputs$", "^load_comp$" },
    ["core/runtime/render.lua"] = { "^frame_order$", "^offline$" },
  },
}

P["core/runtime/fx.lua"] = {
  note = "the GLSL sources are data; the passes that run them stay",
  rest = "core/runtime/fx.lua",
  modules = { ["core/runtime/fxglsl.lua"] = { "^%u%u[%u_]*$", "^F%.convert_shadertoy$", "^F%.preprocess$" } },
}

P["core/moonsplice/demo.lua"] = {
  rest = "core/moonsplice/demo.lua",
  modules = { ["core/moonsplice/demolive.lua"] = { "^Live", "^read_meta$", "^D%.read_meta$", "^D%.live$" } },
}

P["core/runtime/rowsmode.lua"] = {
  rest = "core/runtime/rowsmode.lua",
  modules = {
    ["core/runtime/brief.lua"] = { "^brief$", "^source_of$", "^tables$" },
    ["core/runtime/expect.lua"] = { "^EXPECT_", "^expect_why$", "^M%.expect$", "^M%.gate$" },
  },
}

-- the two lessons are generated (tools/make-lesson.py, make-agent-lesson.py, both parked): cut them once by hand,
-- and the Lua generator that replaces the Python writes them cut. A comp loads its parts with a resolve-phase
-- include relative to the comp (no I/O during render), which the engine gains first.
P["comps/lesson/how-moonsplice-works.lua"] = {
  rest = "comps/lesson/how-moonsplice-works.lua",
  ranges = {
    ["comps/lesson/captions.lua"] = { { 41, 147 } },    -- narration clips and word-aligned captions
    ["comps/lesson/chapters-1.lua"] = { { 155, 318 } }, -- open, fn, seek, declare, det
    ["comps/lesson/chapters-2.lua"] = { { 319, 551 } }, -- hash, lift, perceive, lower, why, close
  },
}

P["comps/agent/facts-on-footage.lua"] = {
  rest = "comps/agent/facts-on-footage.lua",
  ranges = {
    ["comps/agent/cues-1.lua"] = { { 62, 305 } },
    ["comps/agent/cues-2.lua"] = { { 306, 549 } },
  },
}

-- Rust: a module cut out of src/x.rs goes to src/x/<part>.rs (declared `mod part;` in x.rs; for lib.rs, in
-- src/<part>.rs), and a second `impl` block may live in the new module. `cargo test` and the goldens stay green.
P["native/scene/src/lib.rs"] = {
  note = "run() (474 lines) is the opcode interpreter: each opcode family's match arms become a function over "
    .. "(&mut State, &mut Reader, &mut frames) in its own module; run keeps the filter scan and the dispatch",
  rest = "native/scene/src/lib.rs",
  modules = {
    ["native/scene/src/state.rs"] = { "^Brush$", "^State$", "^state$", "^register$", "^color$", "^Reader" },
    ["native/scene/src/text.rs"] = { "^TextRun$", "^TextSpec$", "^spec_key$", "^build_layout", "^draw_text$",
      "^hole_winds_like$" },
    ["native/scene/src/world.rs"] = { "^world$", "^to_premul$", "^premul_pixmap$" },
  },
  ranges = {
    ["native/scene/src/ops_draw.rs"] = { { 422, 483 }, { 692, 760 } },   -- paths 0-10; text, image, glyphs 100-102
    ["native/scene/src/ops_layer.rs"] = { { 484, 554 } },                -- push, pop, close (103-105)
    ["native/scene/src/ops_fx.rs"] = { { 555, 691 } },                   -- 106-116: blends, filters, fx, persp
  },
}

P["native/tabicl/src/prep.rs"] = {
  rest = "native/tabicl/src/prep.rs",
  modules = {
    ["native/tabicl/src/prep/yeojohnson.rs"] = { "^yj", "^logsumexp$", "^log_var$", "^fminbound$", "^col$",
      "^mean$", "^var$", "^nan_stats$", "^is_constant$" },
    ["native/tabicl/src/prep/ensemble.rs"] = { "^Pipeline$", "^latin_square$", "^feature_shuffles$",
      "^class_shifts$" },
  },
}

P["native/track/src/lib.rs"] = {
  rest = "native/track/src/lib.rs",
  modules = {
    ["native/track/src/tracker.rs"] = { "^Tracker$" },
    ["native/track/src/memory.rs"] = { "^spatial_memory$", "^pointer_memory$", "^Memory$", "^FrameMask$" },
  },
}

P["native/render/src/world.rs"] = {
  rest = "native/render/src/world.rs",
  modules = {
    ["native/render/src/world/rows.rs"] = { "^row_kind$", "^spawn_row$", "^update_row$", "^shape_mesh$",
      "^material$", "^read_msh$", "^colour$", "^transform$", "^v3$", "^f$" },
  },
}

P["native/decode/src/lib.rs"] = {
  rest = "native/decode/src/lib.rs",
  modules = {
    ["native/decode/src/worker.rs"] = { "^Ready$", "^Shared$", "^Worker$", "^spawn_worker$", "^Drop for Worker$" },
    ["native/decode/src/ffi.rs"] = { "^REG$", "^NEXT_ID$", "^with_reg$" },
  },
}

P["native/scene3d/src/gpu.rs"] = {
  rest = "native/scene3d/src/gpu.rs",
  modules = {
    ["native/scene3d/src/gpu/buffers.rs"] = { "^upload$", "^padded_bpr$", "^FrameU$", "^DrawU$", "^GpuMesh$",
      "^Targets$" },
  },
}

P["native/scene/src/html/mod.rs"] = {
  rest = "native/scene/src/html/mod.rs",
  modules = { ["native/scene/src/html/tests.rs"] = { "^tests$" } },
}

P["native/solid/src/lib.rs"] = {
  rest = "native/solid/src/lib.rs",
  modules = { ["native/solid/src/export.rs"] = { "^write_msh$", "^write_gltf$", "^write_whole$" } },
}

-- the editor's plans live beside these
for path, plan in pairs(require("splits_editor")) do P[path] = plan end

return P
