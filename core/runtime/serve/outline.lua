-- Part of serve (core/runtime/serve/init.lua): see its head for the module's contract.
local S = require("serve")
local clip, hand = S._.clip, S._.hand

-- The left pane and the timeline show no filenames and no extensions: a path becomes the
-- words a person would have used for it.
local function humanise(path)
  if type(path) ~= "string" or path == "" then return nil end
  local stem = path:match("([^/\\]+)$") or path
  stem = stem:gsub("%.[%w]+$", "")
  stem = stem:gsub("[_%-%.]+", " "):gsub("(%l)(%u)", "%1 %2"):gsub("%s+", " ")
  stem = stem:gsub("^%s*(.-)%s*$", "%1")
  if stem == "" then return nil end
  return (stem:gsub("^%l", string.upper))
end
S.humanise = humanise

local function label_of(node)
  local i = node.initial
  -- A name somebody typed wins over one worked out from what the thing holds. It is the only
  -- name in here that was chosen rather than derived, and a derived name that overrode it would
  -- make naming a thing look like it did nothing.
  if type(i.label) == "string" and i.label ~= "" then return clip(i.label, 48) end
  if type(i.text) == "string" and i.text ~= "" then return clip(i.text, 48) end
  -- Spoken lines are called what they are. Deliberately not the first cue: a name that changes
  -- when you retype a line is not a name -- the lane moved under the pointer and the notice read
  -- "changed line 2 of Hold the cut.". `s:captions` builds a text node, so the kind cannot say
  -- this, and the one word is spelled here to match `captions` in editor/vocabulary.json.
  if type(i.cues) == "table" and i.cues[1] then return "Captions" end
  local from_path = humanise(i.src) or humanise(i.file) or humanise(i.path)
  if from_path then return from_path end
  return nil
end

-- Escape hatches the scene rasterizer cannot paint. The app says so rather than
-- rendering something quietly wrong (love-free-render, scenario 4).
local CLI_ONLY = {
  shader = "a GLSL shader",
  shadertoy = "a Shadertoy program",
  worley = "a Worley noise shader",
}

local function onscreen_of(live, id)
  local spans = live.by_id[id]
  if not spans or #spans == 0 then return { __empty_array = true } end
  return spans
end

-- ----------------------------------------------------------------------------- the outline

-- Props that are a place on a disk rather than a value. The composition needs them; the app is
-- never told one. `ProjectView` holds this line by construction and the outline has to as well,
-- or "no file names anywhere a person looks" is only true of one payload out of two.
local WHERE_A_FILE_IS = { src = true, file = true, path = true, font = true, source = true }

-- One JSON document that is everything the UI knows about a composition: no Lua leaks
-- through it, and nothing in it is a byte offset. Spans belong to the editor, not the view.
function S.outline(comp, meta)
  local nodes, tracks, audio, cues, cli_only = {}, {}, {}, {}, {}
  local index_of = {}

  -- When each thing is actually on screen. The timeline draws a clip from this, so the width of
  -- the biggest shape in it means something; see `core/moonsplice/onscreen.lua`.
  -- Required here rather than at the top: `lib/` only joins `package.path` once a composition
  -- has been loaded, and this file is required before that on some paths.
  local live = require("moonsplice.onscreen").of(comp)

  for i, n in ipairs(comp.nodes) do
    index_of[n] = i
    local ini = n.initial
    local props = {}
    for k, v in pairs(ini) do
      local ty = type(v)
      if WHERE_A_FILE_IS[k] then
        -- Not sent. The app shows a thing by the name in its left pane, and `label` already
        -- carries that; a path in the payload is a path waiting to be printed somewhere.
        props[k] = nil
      elseif ty == "number" or ty == "boolean" then
        props[k] = v
      elseif ty == "string" and #v <= 512 then
        props[k] = v
      elseif ty == "table" and #v == 3 and type(v[1]) == "number" and k == "color" then
        props[k] = { v[1], v[2], v[3] }
      end
    end
    local entry = {
      id = n.id,
      kind = n.kind,
      index = i,
      -- The line of the composition that built it. This is what lets an editor rewrite the
      -- right span: counting constructor calls cannot, because one call in a loop builds many.
      line = n.line,
      label = label_of(n),
      props = next(props) and props or nil,
      -- Measured, not inferred: `[ {t0,t1}, ... ]`. An empty list means never on screen, and it
      -- has to arrive as a list — `{}` would read as "no measurement" on the other side.
      onscreen = onscreen_of(live, n.id),
      -- Set when the thing this node needed is not on the disk: one word, from the small set in
      -- `core/runtime/resolve.lua`, that `editor/vocabulary.json` turns into a sentence. Absent
      -- is the normal case and means nothing is wrong. It is a word rather than the renderer's
      -- own message on purpose -- that message names the file, and no file name goes to the
      -- window.
      offline = n.offline,
    }
    if CLI_ONLY[n.kind] then
      cli_only[#cli_only + 1] = { node = n.id, kind = n.kind, why = CLI_ONLY[n.kind] }
    end
    if ini.perspective then entry.perspective = true end
    -- Who holds it. The timeline indents a group's children under it, the way a layer list does.
    if ini.parent and ini.parent.id then entry.parent = ini.parent.id end
    nodes[#nodes + 1] = entry

    if n.kind == "audio" or n.kind == "tts" or n.kind == "sfx" or n.kind == "music" then
      audio[#audio + 1] = {
        id = n.id, kind = n.kind,
        at = ini.at or 0,
        duration = ini.duration,
        media_start = ini.media_start or 0,
        -- How long the file itself is, which is not how long the clip is. The timeline needs
        -- both to draw the part of a sound a trimmed clip actually plays.
        media_duration = n.media_duration,
        volume = ini.volume or 1,
        bus = ini.bus or false,
        fade_in = ini.fade_in or 0,
        fade_out = ini.fade_out or 0,
        label = label_of(n),
      }
    end
    if type(ini.cues) == "table" then
      for ci, cue in ipairs(ini.cues) do
        cues[#cues + 1] = {
          node = n.id, index = ci - 1,
          t0 = cue.t0 or cue[1], t1 = cue.t1 or cue[2],
          text = cue.text or cue[3],
        }
      end
    end
  end

  -- The timeline is the honest source of the manual/relational distinction the spec asks
  -- for: a tween is a relation between two values over a duration, a step is a value a
  -- person pinned at an instant. Nothing here is a flag the UI could get wrong.
  for _, g in ipairs(comp.timeline.order) do
    local segs = {}
    -- A caption's lines are recorded as steps on `text`, the same shape a hand-pinned value
    -- takes. They are not one: a line is a line, and the UI draws it as one. Tagged here so the
    -- view does not have to re-derive it.
    local from_cues = (g.prop == "text") and type(g.node.initial.cues) == "table"
    for _, seg in ipairs(g.segs) do
      local kind = seg.kind or "tween"
      local manual = (kind == "step") or (seg.t1 <= seg.t0)
      if from_cues and kind == "step" then kind, manual = "cue", false end
      local out = {
        kind = manual and "pin" or kind,
        t0 = seg.t0, t1 = seg.t1,
        manual = manual,
        ease = seg.ease_id,
        overshoot = seg.overshoot or nil,
      }
      local function plain(v)
        if type(v) == "number" or type(v) == "string" or type(v) == "boolean" then return v end
        if type(v) == "table" and type(v[1]) == "number" then return { v[1], v[2], v[3] } end
        return nil
      end
      out.from, out.to = plain(seg.from), plain(seg.to)
      segs[#segs + 1] = out
    end
    tracks[#tracks + 1] = {
      node = g.node.id,
      index = index_of[g.node],
      prop = g.prop,
      segments = segs,
    }
  end

  local bg = comp.background
  return {
    comp = {
      width = comp.width, height = comp.height,
      duration = comp.duration, fps = comp.fps,
      background = { bg[1], bg[2], bg[3] },
      direct = meta.direct or false,
      source_hash = meta.source_hash,
      -- The title, and deliberately not the path it came from. `app-shell` scenario 5 says the
      -- source is not displayed, and a path is the source's name; nothing downstream has ever
      -- needed it, and anything that is handed it can leak it.
      title = humanise(meta.path),
      -- 1 unless the composition is long enough that the on-screen measurement had to stride.
      onscreen_stride = live.stride,
    },
    nodes = #nodes > 0 and nodes or { __empty_array = true },
    tracks = #tracks > 0 and tracks or { __empty_array = true },
    audio = #audio > 0 and audio or { __empty_array = true },
    cues = #cues > 0 and cues or { __empty_array = true },
    cli_only = #cli_only > 0 and cli_only or { __empty_array = true },
  }
end

-- --------------------------------------------- one instant, as values rather than curves

-- `outline` is the shape of a composition; this is what it *is* at one time. The agent
-- reads this to answer "where is the title at 1.2s" without looking at a picture, and it
-- is exact: these are the numbers the renderer painted with.
function S.at(comp, t)
  t = math.max(0, math.min(t or 0, comp.duration))
  comp:evaluate(t)
  local nodes = {}
  for _, n in ipairs(comp.nodes) do
    local props, any = {}, false
    local seen = {}
    for k in pairs(n.initial) do seen[k] = true end
    for k in pairs(n.state) do seen[k] = true end
    for k in pairs(seen) do
      local v = n:get(k)
      local ty = type(v)
      if WHERE_A_FILE_IS[k] then
        props[k] = nil
      elseif ty == "number" or ty == "boolean" then
        props[k] = v; any = true
      elseif ty == "string" and #v <= 512 then
        props[k] = v; any = true
      elseif ty == "table" and type(v[1]) == "number" and k == "color" then
        props[k] = { v[1], v[2], v[3] }; any = true
      end
    end
    nodes[#nodes + 1] = {
      id = n.id, kind = n.kind, label = label_of(n),
      props = any and props or nil,
    }
  end
  -- A list, even when it is empty. An empty composition is a real thing in this app, and `{}`
  -- on the other side reads as an object -- which is how it blanked the preview the first time
  -- somebody opened one.
  return { t = t, nodes = #nodes > 0 and nodes or { __empty_array = true } }
end

-- --------------------------------------------------------------------------- the loop

