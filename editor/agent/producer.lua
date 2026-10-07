-- The producer: the editor's tools, plus the ones that make a piece out of footage.
--
-- `editor.lua` is the agent in the app's window, and it is deliberately small: it adjusts a
-- composition somebody already made, and it cannot make a shape or a line of writing out of
-- nothing. That is right for a person nudging their own edit and wrong for the job this
-- declaration exists for -- being handed a long take and a goal ("a five minute explainer") and
-- building the piece. So this one starts from the editor's tools and adds five:
--
--   transcript  what is said in a clip, a phrase a line, in the clip's own seconds
--   keep        lay chosen stretches of a clip end to end, picture and sound together
--   comp        the composition's size, length, frame rate and background
--   draw        a title, a label, a block or a picture, on for a stretch, with a way in and out
--   captions    the words of a clip on screen while they are heard, following the edit
--
-- The host is `moonsplice agent` (src/bin/moonsplice-agent.rs), which runs it with no window.
-- Every tool body is a call into the app (`c.moonsplice`); no Lua the model writes reaches a
-- composition -- `draw` builds its block from structured arguments on the Rust side.

local agent = agent or require("agent")

-- The editor's tools, unchanged. `DECLARATION_DIR` is set by the host; the fallback is for a
-- declaration loaded straight off the disk by `malleable --check`.
local here = DECLARATION_DIR
if not here and type(debug) == "table" then
  local src = debug.getinfo(1, "S").source or ""
  here = src:match("^@?(.*)[/\\][^/\\]*$")
end
dofile((here or ".") .. "/editor.lua")

local function app(c)
  if not c.moonsplice then
    error("the producer needs the app; run it through moonsplice agent")
  end
  return c.moonsplice
end

agent.name "producer"

-- A whole piece is many calls: a transcript read, a cut list, a dozen graphics, captions, a
-- render. The window's twenty-step leash is for one request; `--budget` moves this one.
agent.budget(80)

agent.system [[
You build videos in Moonsplice from footage the project already holds. You work alone: nobody
answers questions mid-run, so decide, act, check, and say what you made at the end.

A composition is a pure function of time: things with properties, and movements between values.
You change it only through your tools; you never write code.

How to build a piece from a long take of someone talking:

1. `project` to see what there is. `holds` to see the composition as it stands.
2. `transcript` on the take. Times are in the take's own seconds. Read it all before cutting:
   find the through-line, the strongest opening line (the hook), and the parts that repeat,
   wander or stumble.
3. `comp` to set the frame (1920x1080 for a landscape explainer) and roughly the length you are
   aiming for. `keep` lengthens the composition by itself if the pieces run past the end.
4. `keep` the stretches you want, in the order they should be heard, as [start, end] pairs from
   the transcript. Cut on phrase boundaries -- start a little before the first word and end a
   little after the last, never mid-word. One `keep` call lays every piece end to end; a
   portrait take in a landscape frame needs a `box` ({x, y, w, h}) or it is cropped to fill.
   The pieces are named "<take> 1", "<take> 2" ... and their sounds "<take> 1 sound" ...
5. `draw` the explanation on top: a title card for the hook, a kicker or label for each section,
   key numbers and terms as big type, blocks of colour behind them. Time each one to the line
   it illustrates (composition seconds -- `keep` tells you where each piece landed). Vox-style
   means bold type, a restrained palette, clean blocks, things arriving with purpose (rise, pop,
   wipe, type) and leaving cleanly.
6. `captions` on the take, once the cut is settled, so the words follow the edit.
7. `holds` and `at` to check what you made. `export` only when asked to render.

Rules:
- Name things exactly as `holds` or `project` names them.
- Every visual must be on screen while something relevant is being said; nothing should sit on
  top of the speaker's face for long.
- If a tool refuses, read why, fix the call and carry on. Do not repeat a call that failed the
  same way twice.
- Positions are pixels from the top-left of the frame. Text `size` is in pixels; `anchor =
  "center"` centres writing on its x. Colours are "#rrggbb" or "#rrggbbaa".
]]

-- ------------------------------------------------------------------------------ the tools

agent.tool "transcript" {
  about = "What is said in a clip or a sound, a phrase a line with its start and end in the clip's own seconds. Use it to choose what to keep. Long takes are heard once and remembered.",
  args = {
    thing = agent.string "the clip or sound, by its name in the project",
    from = agent.number_opt "only what is said after this moment of the clip, in seconds",
    to = agent.number_opt "only what is said before this moment of the clip, in seconds",
  },
  run = function(c)
    return app(c).produce("transcript", c.args)
  end,
}

agent.tool "keep" {
  about = "Lay chosen stretches of a clip end to end on the timeline, picture and sound together, in the order given. This is how a long take becomes a tight piece. Answers with where each piece landed in the composition.",
  ask = true,
  args = {
    thing = agent.string "the clip, by its name in the project",
    ranges = agent.list "the stretches to keep, in the order they should play: [[start, end], ...] in seconds of the clip's own time, as `transcript` gives them. They may not overlap.",
    at = agent.number_opt "where the first piece starts in the composition, in seconds (0 if left out)",
    box = agent.table_opt "where the picture sits: {x, y, w, h} in pixels. Left out, it fills the frame, cropping what does not fit.",
    sound = agent.boolean_opt "keep its sound too (yes if left out)",
    picture = agent.boolean_opt "keep its picture too (yes if left out); no makes it a voice under other pictures",
    volume = agent.number_opt "how loud its sound is, 1 being as recorded",
  },
  run = function(c)
    local out, why = app(c).produce("keep", c.args)
    if not out then return nil, why end
    c.note("kept parts of " .. tostring(c.args.thing))
    return out
  end,
}

agent.tool "comp" {
  about = "Set the composition's own frame: its size, how long it is, its frame rate, and what is behind everything.",
  ask = true,
  args = {
    width = agent.number_opt "width in pixels",
    height = agent.number_opt "height in pixels",
    duration = agent.number_opt "length in seconds",
    fps = agent.number_opt "pictures a second",
    background = agent.string_opt "the colour behind everything, \"#rrggbb\"",
  },
  run = function(c)
    return app(c).produce("comp", c.args)
  end,
}

agent.tool "draw" {
  about = "Put writing, a block, a circle or a picture on screen for a stretch of the composition, with a way in and a way out. This is how the explanation gets on top of the footage: titles, labels, key numbers, blocks of colour behind them. Later draws paint in front of earlier ones.",
  ask = true,
  args = {
    kind = agent.one_of "what it is" { "text", "rect", "circle", "image", "surface" },
    what = agent.string "a short name for it, which is what `holds` will call it",
    props = agent.table [[how it looks, as an object. Writing: {"text": "...", "x": 960, "y": 200, "size": 96, "color": "#ffffff", "anchor": "center", "font": "Roboto Bold", "wrap": 900, "align": "center"} (`font` is a typeface in the project; `wrap` is a column width in pixels). Block: {"x": 0, "y": 0, "w": 800, "h": 200, "color": "#f2c230", "rx": 12}. Circle: {"x": 300, "y": 300, "r": 40, "color": "#e8483b"}. Picture: {"src": "<picture name>", "x": 0, "y": 0, "w": 400, "h": 300}. Any: "opacity", "rotation", "scale", "anchor" ("center" or "topleft").]],
    from = agent.number "when it arrives, in seconds of the composition",
    to = agent.number_opt "when it has gone, in seconds (the end of the composition if left out)",
    enter = agent.one_of_opt "how it arrives: fade, rise (up from below its y), pop (grows in), wipe (a block grows to its w), type (writing types on), none" { "fade", "rise", "pop", "wipe", "type", "none" },
    exit = agent.one_of_opt "how it leaves: fade, drop, none" { "fade", "drop", "none" },
    over = agent.number_opt "how long the way in and the way out take, in seconds (0.45 if left out)",
  },
  run = function(c)
    return app(c).produce("draw", c.args)
  end,
}

agent.tool "captions" {
  about = "Put the words of a clip on screen while they are heard, a few at a time, following wherever its pieces now sit in the composition. Do it after the cut is settled; captions made before a re-cut do not follow it.",
  ask = true,
  args = {
    thing = agent.string "the clip whose words to show, by its name in the project",
    words = agent.number_opt "at most this many words on screen at once (5 if left out)",
    style = agent.table_opt [[how the captions look: {"x", "y", "size", "color", "anchor", "font", "shadow"}. Left out: centred near the bottom, white.]],
  },
  run = function(c)
    return app(c).produce("captions", c.args)
  end,
}

return agent
