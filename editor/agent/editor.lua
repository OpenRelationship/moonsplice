-- The editor: Moonsplice Studio's agent, as a malleable declaration.
--
-- This file builds a table and runs nothing. What it *does* is `editor.feature`, which is
-- also its test suite:
--
--     lua packages/malleable/bin/malleable.lua --verify editor/agent/editor.lua
--
-- The app's host (`editor/src-tauri/src/agent.rs`) puts a `moonsplice` table on the port,
-- and `src/turn.lua` passes any extra port key through to a tool body — so `c.moonsplice` is
-- the real app, and every function on it is the same command the UI calls. There is exactly
-- one way into a composition, whichever side asked for the change.
--
-- With no host — `--verify`, `--check`, an eval — `DOUBLE` at the bottom stands in, so the
-- feature file runs with no glue code written anywhere.
--
-- The tools hold no policy. `ask = true` says the gate decides, and a refusal comes back as
-- an ordinary result the model reads (malleable rule 4).

-- The sandbox hands the declaration surface in as a global; a host requires it.
local agent = agent or require("agent")

local DOUBLE -- defined at the bottom; the closures below read the upvalue

local function app(c)
  return c.moonsplice or DOUBLE
end

agent.name "editor"

-- MiniMax M3: 1M context, and the only one of the two models here allowed near a
-- composition. .robot/docs/desktop.robot §6 sets the split, and it is load-bearing — a pixel model
-- edits rendered frames, and a rendered frame is not expressible in a pure f(t).
agent.model "openrouter:minimax/minimax-m3"

-- Rule 5: the loop always ends.
agent.budget(20)

agent.system [[
You edit video compositions in Moonsplice Studio, for someone who never wants to see code.

A composition is a pure function of time. Nothing in it is a file or a frame: it is a set of
things with properties, and movements that relate one value to another over a duration. You
change it by naming a thing and what should be true of it.

How to work:

- Start with `holds`, which tells you what the composition contains. Use `at` when you need
  the actual numbers at one moment — where something sits, how bright it is, what it says.
- `change` is the only way anything is altered. Put every edit for one intention in a single
  call: the person gets one undo step for what they asked for, not twelve.
- Say what you did in the words the person used. Never mention Lua, file names, extensions,
  or a property as a raw number when a word will do. "The title now fades in over half a
  second", not "text1.opacity tween 0.5 quadOut".
- If an edit is refused, the refusal is the answer. Say what cannot be done in one sentence
  and offer the nearest thing that can.
- Name a thing exactly as `holds` names it. Those names are what the person sees in the app,
  and they are what `change` takes; there is no other identifier and you never need one.
- Do not guess at a thing's name. If you cannot tell which one is meant, ask.
- `project` is what the person has to work with; the composition is what is already in this one.
  They are different questions, and a clip that is not in the composition may still be in the
  project.
- `move_clip` moves a clip or a sound along the timeline, and trims either end of it. Only
  things with a length of their own -- footage and sound -- can be moved this way; a shape is on
  screen for as long as the composition says, and what moves that is a movement.
- `cut_clip` cuts a clip in two where you say. The half that is made carries on from where the
  first stops, in its own footage as well as on the timeline, so the picture does not jump at
  the join. The cut has to fall inside the clip.
- `note` pins a note to a moment. It is not in the picture and not in the mix: it is a note
  about the edit, drawn as a flag on the ruler. A line of writing that should appear on screen is
  a different thing and is placed, not noted.
- `close_gap` closes a hole in the timeline, and with `take_out` takes the clip out and closes
  the hole it leaves. Only things of the same kind move: a line taken out of the narration slides
  the rest of the narration, and the pictures stay where they are. It is refused, with a reason,
  when something that would move is animated -- a movement is written against the composition's
  clock and would be left behind.
- `move_when` moves when a movement starts. What follows it in the same run moves with it,
  because a script runs in order; say so when it matters.
- `restack` moves a thing up or down the stack -- what paints over what. Name the thing it should
  now be in front of; leave `over` out to send it to the very back. Sound has no front or back.
- `place` puts something the project already holds -- a clip, a picture, a sound -- into the
  composition. It is the only way anything new gets in: there is no making a shape or a line of
  writing out of nothing.
- Some things cannot be done at all. There is no way to remove a thing, to make one that is not
  already in the project, or to set a property a thing does not have. Say so plainly: "I cannot change the stacking order", not "set_prop
  refused". Never name your own tools -- the person does not know they exist and they read as
  code.
]]

-- ------------------------------------------------------------------------------ the tools

agent.tool "holds" {
  about = "What the composition contains right now: its things, their movements, its spoken lines and its audio.",
  args = {},
  run = function(c)
    return app(c).outline()
  end,
}

agent.tool "at" {
  about = "What every property actually is at one moment. Use this instead of guessing where something sits.",
  args = { t = agent.number "the moment, in seconds from the start" },
  run = function(c)
    return app(c).at(c.args.t)
  end,
}

agent.tool "shows" {
  about = "What the rendered video shows, as facts that each name the producer that measured them. Use it to check a claim about the picture rather than about the composition.",
  args = {},
  run = function(c)
    return app(c).shows()
  end,
}

-- The one tool that leaves a mark on the composition.
agent.tool "change" {
  about = "Change the composition. Takes every edit for one intention at once, so the person gets a single undo step.",
  ask = true,
  args = {
    edits = agent.list [[the edits, each an object. `node` is the thing's name exactly as
      `holds` gave it -- "EDITOR", "Block 2", "Captions" -- not an invented one:
      {"verb":"set_prop","node":"<name>","key":"<one of: Across, Down, Width, Height, Radius, Corner, Type size, Visibility, Turn, Size, Colour, Words, Letter spacing>","value":<number|string|boolean>}
      {"verb":"set_ease","node":"<name>","ease":"<one of: Even, Soft stop, Gentle stop, Slow stop, Arriving, Overshoot, Springy, Bouncing, Soft both ends, Slow both ends, Building and arriving>"}
      {"verb":"set_tween_duration","node":"<name>","seconds":<number>}
      {"verb":"set_cue","node":"<name>","index":<0-based>,"t0":<sec>,"t1":<sec>,"text":"<words>"}
      {"verb":"pin_prop","node":"<name>","t":<sec>,"key":"<one of the same words>","value":<number>}]],
    why = agent.string "what this changes, in the person's words, in one short line",
  },
  run = function(c)
    local out, why = app(c).change(c.args.edits, c.args.why)
    if not out then return nil, why end
    c.note(c.args.why)
    return out
  end,
}

agent.tool "project" {
  about = "What the project holds that can go into a composition: its clips, pictures and sounds, by the names the person sees in the app.",
  args = {},
  run = function(c)
    return app(c).project()
  end,
}

agent.tool "place" {
  about = "Put something the project already holds -- a clip, a picture, a sound -- into the composition. It goes in front of everything else, at the moment you give.",
  ask = true,
  args = {
    thing = agent.string "what it is called in the project, exactly as the person would say it",
    at = agent.number_opt "the moment it starts, in seconds from the beginning",
  },
  run = function(c)
    return app(c).place(c.args.thing, c.args.at)
  end,
}

agent.tool "move_clip" {
  about = "Move a clip or a sound along the timeline, or trim one of its ends. `to` moves the whole thing so it begins there. `trim` takes hold of one end: \"in\" moves where it starts, in the composition and in its own footage at once, and \"out\" moves where it stops.",
  ask = true,
  args = {
    node = agent.string "the clip or sound, by the name the composition gave it",
    to = agent.number_opt "the moment it begins, in seconds",
    trim = agent.string_opt 'which end to move instead: "in" or "out"',
    at = agent.number_opt "where that end lands, in seconds",
  },
  run = function(c)
    return app(c).move_clip(c.args.node, c.args.to, c.args.trim, c.args.at)
  end,
}

agent.tool "note" {
  about = "Pin a note to a moment. It is neither seen nor heard -- it is a note about the edit, and it shows up as a flag on the ruler. Use it to mark somewhere that needs work, not to put writing on screen; writing on screen is a thing you place.",
  ask = true,
  args = {
    at = agent.number "the moment to pin it to, in seconds from the start",
    text = agent.string "what the note says",
  },
  run = function(c)
    return app(c).note(c.args.at, c.args.text)
  end,
}

agent.tool "close_gap" {
  about = "Close a hole in the timeline. With `take_out`, the clip goes and everything of its own kind after it moves up by its length; without it, the empty stretch after the clip closes. Only its own kind moves -- taking a line out of the narration does not slide the pictures.",
  ask = true,
  args = {
    node = agent.string "the clip or sound the hole is after, by the name the composition gave it",
    take_out = agent.boolean_opt "take that clip out first, then close the hole it leaves",
  },
  run = function(c)
    return app(c).close_gap(c.args.node, c.args.take_out)
  end,
}

agent.tool "cut_clip" {
  about = "Cut a clip or a sound in two at a moment. Both halves stay where they are; what changes is that there are now two of them, and either can be moved, trimmed or taken out on its own.",
  ask = true,
  args = {
    node = agent.string "the clip or sound, by the name the composition gave it",
    at = agent.number "the moment to cut it, in seconds from the start of the composition",
  },
  run = function(c)
    return app(c).cut_clip(c.args.node, c.args.at)
  end,
}

agent.tool "move_when" {
  about = "Move when one of a thing's movements begins. `at` is where it should start, in seconds. `which` picks the movement when a thing has several, counting from 1 in the order they happen. What follows it in the same run of the script moves with it.",
  ask = true,
  args = {
    node = agent.string "the thing, by the name the composition gave it",
    at = agent.number "when the movement should begin, in seconds",
    which = agent.number_opt "which of its movements, counting from 1",
  },
  run = function(c)
    return app(c).move_when(c.args.node, c.args.at, c.args.which)
  end,
}

agent.tool "restack" {
  about = "Move a thing up or down the stack: what paints over what. `over` is the thing it should now be in front of. Leave it out to send it to the very back, behind everything.",
  ask = true,
  args = {
    node = agent.string "the thing, by the name the composition gave it",
    over = agent.string_opt "the thing it should now be in front of",
  },
  run = function(c)
    return app(c).restack(c.args.node, c.args.over)
  end,
}

agent.tool "undo" {
  about = "Put the composition back the way it was before the last change.",
  ask = true,
  args = {},
  run = function(c)
    return app(c).undo()
  end,
}

agent.tool "export" {
  about = "Render the composition to a finished video. Slow, and it writes a file, so it is always put to the person.",
  ask = true,
  args = {
    quality = agent.one_of_opt "draft, standard or high" { "draft", "standard", "high" },
  },
  run = function(c)
    return app(c).export(c.args.quality or "standard")
  end,
}

-- The pixel model. It never sees the composition — it is handed a rendered video and gives
-- back another one, which enters the project as a new piece of footage.
agent.tool "repaint" {
  about = "Ask the pixel model to alter a rendered video — remove a sign, add an object. The result is new footage; the composition is untouched.",
  ask = true,
  args = { instruction = agent.string "what to change in the picture" },
  run = function(c)
    return app(c).repaint(c.args.instruction)
  end,
}

-- ------------------------------------------------------------------------------ the double
--
-- Reached only when the port carries no app. Stateless on purpose: `--verify` walks every
-- scenario in one process, and a double that remembered would make the order matter.

DOUBLE = {
  project = function()
    return "The project holds:\n- Earth night — a clip"
  end,
  place = function(thing, at)
    return ("put %s in at %ss"):format(thing, tostring(at or 0))
  end,
  move_clip = function(node, to, trim, at)
    if trim then
      return ("trimmed the %s of %s to %ss"):format(trim, node, tostring(at or 0))
    end
    return ("moved %s to %ss"):format(node, tostring(to or 0))
  end,
  move_when = function(node, at, which)
    return ("%s's move %d now starts at %ss"):format(node, which or 1, tostring(at or 0))
  end,
  restack = function(node, over)
    if over then
      return ("put %s in front of %s"):format(node, over)
    end
    return ("sent %s to the back"):format(node)
  end,
  cut_clip = function(node, at)
    return ("cut %s in two at %ss"):format(node, tostring(at or 0))
  end,
  outline = function()
    return table.concat({
      "2 things, 3.6s long, 1280x720.",
      "- text1 (text) — Hold the cut.",
      "- rect2 (rect)",
      "- rect2's width moves from 0.15s to 0.55s on an expoOut curve",
    }, "\n")
  end,
  at = function(t)
    return ("at %.2fs: text1 is invisible, rect2 is 640 wide"):format(tonumber(t) or 0)
  end,
  shows = function()
    return "holds(in_third(text1, left), 0.55, 3.6)\nsrc(yolo_world, 0.86)"
  end,
  change = function(edits, why)
    if type(edits) ~= "table" or #edits == 0 then
      return nil, "no edits were given, so nothing changed"
    end
    for i = 1, #edits do
      if edits[i].node == "ghost" then
        return nil, 'there is nothing called "ghost" in this composition'
      end
    end
    return ("changed %d thing(s): %s"):format(#edits, why or "")
  end,
  undo = function()
    return "put the composition back the way it was"
  end,
  export = function(q)
    return ("rendered at %s quality"):format(tostring(q))
  end,
  repaint = function(instruction)
    return ("new footage from the pixel model: %s — the composition is unchanged")
      :format(tostring(instruction))
  end,
}

return agent
