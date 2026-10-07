-- The editor's split plans (editor/: the Tauri + React app), in splits.lua's form. Rust: a module cut from src/x.rs
-- goes to src/x/<part>.rs (`mod part;` in x.rs; for lib.rs, src/<part>.rs), and an `impl` may be cut into several
-- blocks across them. A test module over the limit is cut by range into two. Integration tests (tests/*.rs) share
-- helpers through tests/common/mod.rs. TypeScript: a component or hook goes to its own file beside the old one.
local P = {}
local T = "editor/src-tauri/"

P[T .. "src/lib.rs"] = {
  note = "lib.rs keeps the Studio state, its events and run(); the commands Tauri exposes move by what they act on",
  rest = T .. "src/lib.rs",
  modules = {
    [T .. "src/open.rs"] = { "^Opened$", "^open_project_now$", "^remembered_path$", "^remember_path$", "^project$",
      "^open_variation_now$", "^close_variation$" },
    [T .. "src/assets.rs"] = { "^frame_base$", "^PlaybackReport$", "^playback$", "^report_playback$", "^asset_base$",
      "^Source$", "^asset_source$", "^serve_asset$", "^sound_asked_for$", "^sound_path$", "^read_slice$",
      "^parse_range$", "^urldecode$" },
    [T .. "src/gesture.rs"] = { "^instant_now$", "^Gesture$", "^Edge$", "^Span$", "^span_of$", "^one_frame$",
      "^comp_duration$", "^tween_start$", "^is_note$", "^is_sound$", "^not_a_clip$" },
    [T .. "src/gesture_edits.rs"] = { "^gesture_to_edits$", "^round2$", "^placed$", "^timed$" },
    [T .. "src/edit.rs"] = { "^ripple$", "^moving_anywhere$", "^moving_at$", "^Refused$", "^apply_gesture_now$",
      "^place_asset_now$", "^place_edit$" },
    [T .. "src/apply.rs"] = { "^asset_named$", "^apply_edits$", "^refusal$", "^reread$", "^write_and_reload$",
      "^unloadable$", "^apply_now$", "^step_history$" },
    [T .. "src/library.rs"] = { "^add_composition$", "^add_folder$", "^move_item$", "^rename_folder$",
      "^add_variation$", "^add_assets$", "^drop_paths$" },
    [T .. "src/export.rs"] = { "^ExportPlan$", "^plan_export$", "^run_export$", "^export_now$" },
    [T .. "src/bridge.rs"] = { "^Bridge$", "^agent::AppBridge for Bridge$" },
    [T .. "src/describe.rs"] = { "^describe$", "^describe_instant$", "^brief$", "^ChannelSurface$",
      "^agent::Surface for ChannelSurface$", "^answer_ask$", "^stop_turn$", "^ask_agent$", "^set_key$",
      "^key_is_set$", "^trouble$", "^looks_like_a_path$" },
    [T .. "src/framing.rs"] = { "^frame_budget$", "^node_refs$", "^watch$", "^same_file$", "^frame_wanted$", "^across_the_origin$", "^stamped$",
      "^make_frame$", "^frame_queue$", "^frame_now$" },
    [T .. "src/tests.rs"] = { "^tests$" },
  },
}

P[T .. "tests/studio.rs"] = {
  note = "one integration test file per area, each `mod common;` for root, cases, serve_dir and node_refs",
  rest = T .. "tests/common/mod.rs",
  modules = {
    [T .. "tests/studio_open.rs"] = { "^no_edit_is", "^every_node_is_traced", "^an_edit_is_a_write",
      "^a_frame_arrives", "^one_instant" },
    [T .. "tests/studio_project.rs"] = { "^the_engine_measures", "^an_empty_composition", "^a_folder_of",
      "^a_spoken_line", "^an_export_renders", "^an_edit_the_engine_cannot" },
    [T .. "tests/studio_gestures.rs"] = { "^a_whole_sitting", "^a_thing_from_the_project" },
    [T .. "tests/studio_timeline.rs"] = { "^a_clip_is_dragged", "^a_clip_is_cut", "^what_paints_over" },
    [T .. "tests/studio_undo.rs"] = { "^a_whole_edit_is_made", "^a_thing_is_given_a_name" },
    [T .. "tests/studio_gaps.rs"] = { "^when_a_movement_starts", "^a_composition_that_will_not_open",
      "^a_gap_in_the_timeline" },
    [T .. "tests/studio_notes.rs"] = { "^a_gap_is_not_closed", "^a_note_is_pinned", "^a_frame_reaches_the_canvas",
      "^a_frame_and_a_sound" },
  },
}

P[T .. "src/lower.rs"] = {
  rest = T .. "src/lower.rs",
  modules = {
    [T .. "src/lower/refusal.rs"] = { "^EditRefusal$", "^fmt::Display for EditRefusal$", "^EditResult$" },
    [T .. "src/lower/layout.rs"] = { "^Span$", "^ctor_re$", "^tween_re$", "^match_brace$", "^node_spans$",
      "^NodeRef$", "^Layout$", "^line_of$" },
    [T .. "src/lower/fields.rs"] = { "^field$", "^field_span$", "^value_len$", "^set_field$", "^OPEN_TO_ALL$",
      "^set_prop$", "^tween_hits$", "^set_ease$", "^set_tween_duration$" },
    [T .. "src/lower/moves.rs"] = { "^move_tween_start$", "^set_cue$", "^pin_prop$", "^remove$", "^reorder$" },
    [T .. "src/lower/statements.rs"] = { "^statement$", "^split$", "^round2$", "^place$", "^insert$", "^set_comp$",
      "^find_function_end$", "^indent_at$", "^fmt_num$", "^escape_lua$", "^lua_literal$" },
  },
  ranges = {
    [T .. "src/lower/tests.rs"] = { { 1662, 1995 } },
    [T .. "src/lower/tests_more.rs"] = { { 1996, 2328 } },
  },
}

P[T .. "src/agent.rs"] = {
  note = "malleable is dropped: app_table and the tool calls are rewritten to drive tablua's agent.loop",
  rest = T .. "src/agent.rs",
  modules = {
    [T .. "src/agent/turn.rs"] = { "^run_turn$", "^Turn$", "^Cancel$" },
    [T .. "src/agent/table.rs"] = { "^malleable_role$", "^app_table$", "^declared$", "^set_declaration_dir$" },
    [T .. "src/agent/tools.rs"] = { "^list_tools$", "^call_tool$", "^guard$", "^two$", "^err$" },
  },
  ranges = {
    [T .. "src/agent/tests.rs"] = { { 875, 1160 } },
    [T .. "src/agent/tests_more.rs"] = { { 1161, 1411 } },
  },
}

P[T .. "src/project.rs"] = {
  note = "impl Project (642 lines) becomes three impl blocks: opening and saving, adding, the tree",
  rest = T .. "src/project.rs",
  modules = {
    [T .. "src/project/walk.rs"] = { "^MAX_DEPTH$", "^skipped$", "^folder_of$", "^rehome$", "^clean_folder$",
      "^folder_name$", "^humanise_folder$", "^looks_empty$", "^comps_under$", "^is_media$", "^walk$",
      "^declared_size$", "^retarget$", "^blank_comp$" },
    [T .. "src/project/tests.rs"] = { "^tests$" },
  },
  ranges = {
    [T .. "src/project/open.rs"] = { { 269, 442 } },   -- open, reconcile, save, source_of, title_of, asset_path
    [T .. "src/project/add.rs"] = { { 443, 626 } },    -- add_asset, add_export, add_composition, add_variation
    [T .. "src/project/tree.rs"] = { { 627, 910 } },   -- view, tree, items_in, add_folder, move_item, rename_folder
  },
}

P[T .. "src/headless.rs"] = {
  rest = T .. "src/headless.rs",
  modules = {
    [T .. "src/headless/session.rs"] = { "^Session$", "^Drop for Session$", "^apply_headless$", "^pick_variation$",
      "^AppBridge for Session$" },
    [T .. "src/headless/words.rs"] = { "^project_words$", "^words_of$", "^Word$", "^word_list$", "^phrases$",
      "^transcript$" },
    [T .. "src/headless/produce.rs"] = { "^asset_rel$", "^produce$", "^num$", "^text$", "^shape$", "^secs$", "^r2$",
      "^comp_size$", "^media_key$", "^shared_cache$", "^media_duration$", "^keep$", "^comp$" },
    [T .. "src/headless/draw.rs"] = { "^DRAWABLE$", "^DRAW_KEYS$", "^draw$", "^lua_table$", "^captions$" },
  },
}

P[T .. "tests/spec.rs"] = {
  rest = T .. "tests/spec.rs",
  modules = {
    [T .. "tests/spec_agent.rs"] = { "^Scripted$", "^Transport for Scripted$", "^text$", "^calls$", "^Spy$",
      "^agent::AppBridge for Spy$", "^Watch$", "^Surface for Watch$", "^turn$", "^a_turn_streams",
      "^an_edit_asks", "^a_refusal_is_a_result", "^the_pixel_model" },
    [T .. "tests/spec_edits.rs"] = { "^a_manual_edit", "^no_code_is_shown", "^a_refusal_is_said",
      "^an_edit_is_a_write", "^an_unedited_comp" },
    [T .. "tests/spec_sync.rs"] = { "^a_change_from_the_agent", "^an_external_edit", "^an_agent_edit_undoes",
      "^a_gesture_with_no_lowering" },
  },
}

P[T .. "tests/agent_live.rs"] = {
  rest = T .. "tests/agent_live.rs",
  modules = { [T .. "tests/live/mod.rs"] = { "^Live$", "^agent::AppBridge for Live$" } },
}

P[T .. "tests/longform.rs"] = {
  rest = T .. "tests/longform.rs",
  modules = { [T .. "tests/longform_play.rs"] = { "^playing_a_long_edit", "^dropping_the_playhead" } },
}

P[T .. "src/perf.rs"] = {
  rest = T .. "src/perf.rs",
  modules = {
    [T .. "src/perf/stats.rs"] = { "^load_average$", "^Percentiles$", "^PlaybackStats$" },
    [T .. "src/perf/tests.rs"] = { "^tests$" },
  },
}

P[T .. "src/bin/moonsplice-agent.rs"] = {
  rest = T .. "src/bin/moonsplice-agent/main.rs",
  modules = {
    [T .. "src/bin/moonsplice-agent/terminal.rs"] = { "^Terminal$", "^Surface for Terminal$", "^render$" },
    [T .. "src/bin/moonsplice-agent/tools.rs"] = { "^tools$", "^call$" },
  },
}

P[T .. "src/source.rs"] = { rest = T .. "src/source.rs", modules = { [T .. "src/source/tests.rs"] = { "^tests$" } } }
P[T .. "src/frames.rs"] = { rest = T .. "src/frames.rs", modules = { [T .. "src/frames/tests.rs"] = { "^tests$" } } }

P[T .. "src/engine.rs"] = {
  rest = T .. "src/engine.rs",
  modules = { [T .. "src/engine/reply.rs"] = { "^gone$", "^next_cs_line$", "^payload$", "^in_words$",
    "^why_it_would_not_open$", "^read_ready$", "^read_reply$", "^tail$" } },
}

local S = "editor/src/"

P[S .. "timeline/Timeline.tsx"] = {
  rest = S .. "timeline/Timeline.tsx",
  modules = {
    [S .. "timeline/Lanes.tsx"] = { "^Lanes$", "^GrabEdge$" },
    [S .. "timeline/marks.tsx"] = { "^Footer$", "^SoundDivider$", "^Playhead$", "^Note$", "^Gap$" },
    [S .. "timeline/LaneRow.tsx"] = { "^LaneRow$", "^TINT$", "^iconFor$" },
    [S .. "timeline/ClipBar.tsx"] = { "^ClipBar$", "^LaneName$" },
    [S .. "timeline/props.tsx"] = { "^Stack$", "^PropRow$", "^Movement$" },
  },
}

P[S .. "stage/Stage.tsx"] = {
  rest = S .. "stage/Stage.tsx",
  modules = {
    [S .. "stage/Preview.tsx"] = { "^Preview$", "^useWhyBehind$" },
    [S .. "stage/Transport.tsx"] = { "^Transport$", "^num$", "^Listening$", "^useHeard$" },
  },
}

P[S .. "library/Library.tsx"] = {
  rest = S .. "library/Library.tsx",
  modules = { [S .. "library/rows.tsx"] = { "^RowsProps$", "^Rows$", "^Folder$", "^Row$", "^NameIt$" } },
}

P[S .. "timeline/lanes.test.ts"] = {
  rest = S .. "timeline/lanes.test.ts",
  modules = { [S .. "timeline/derived.test.ts"] = { "^the timeline, derived$" } },
}

P[S .. "player.ts"] = {
  rest = S .. "player.ts",
  modules = { [S .. "frame.ts"] = { "^useFrame$", "^Showing$", "^sized$" } },
}

P[S .. "timeline/lanes.ts"] = {
  rest = S .. "timeline/lanes.ts",
  modules = { [S .. "timeline/scale.ts"] = { "^fraction$", "^timeAt$", "^ticks$", "^easeShape$", "^EASES$", "^ZOOM_",
    "^FLOOR$", "^fitZoom$", "^clampZoom$", "^zoomStep$", "^restep$", "^edges$", "^snap$", "^gapAfter$" } },
}

P[S .. "ui/bits.tsx"] = { rest = S .. "ui/bits.tsx", modules = { [S .. "ui/icons.tsx"] = { "^Icon$", "^IconName$" } } }

return P
