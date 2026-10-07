-- What the models are told. .robot/docs/direction.robot §3: a director writes treatments before any code, a
-- builder writes the Lua at low temperature, a critic looks at frames against a rubric.
local H = require("host")

local P = {}

local function reference()
  return H.read(H.root .. "/agent/REFERENCE.md") or "(.robot/docs/reference.robot is missing)"
end

P.bans = [[
Banned defaults (each allowed only if the treatment argues for it): a centred white title over footage;
fade in / fade out as the way things arrive; lower-thirds; drop shadows for legibility; captions with no
speech; stock "pop" entrances; more than two typefaces; colour not taken from the subject; evenly spaced
cuts or beats with no reason; decoration that relates to nothing in the picture.]]

P.exemplar = [[
Exemplar treatment ("Tide Table", 60 s, harbour footage):
- Premise: one tide, low to high to low, compressed into a minute; the town shown the way the water sees it.
- Governing rule: one horizontal waterline rises and falls on a semidiurnal curve; every shot is placed so
  its real waterline sits on that line, so cuts are match cuts on the water.
- Grammar: condensed grotesk with tabular figures for almanac data above the line, one serif italic human
  sentence per movement below it; palette sampled from the water at slack tide and sodium harbour light;
  the line itself 1.5 px off-white, the brightest thing on screen. Signature motion: the flood (shots
  masked below the line). Bans: fades, wipes, centred titles.
- Structure: low water 0-8 s, flood 8-20, high water 20-32 (line leaves frame), slack 32-40 (dead still),
  ebb 40-52, night 52-60.
- Every element names its source: the line from the tide curve, cut points from beats where the curve
  crosses a shot's waterline, type positions from the line.
- What a viewer remembers: the four seconds of slack water, the only stillness in the film.]]

function P.director(ask, kind)
  return {
    system = "You are the director of a small studio that makes " .. (kind == "game" and "small, striking games" or
      "short films and motion pieces") .. " in Moonsplice, a Lua engine where a piece is a pure function of time "
      .. "(and, for games, of the input log). You think before anything is built.\n\n" .. P.exemplar .. "\n\n" .. P.bans,
    user = "The ask: " .. ask .. "\n\nWrite three different treatments in the exemplar's shape (premise; the ONE "
      .. "governing rule that decides framing, motion, type and timing; grammar: at most two typefaces and their jobs, "
      .. "a palette, ONE signature motion, a ban list; structure in timed movements; for each visual element what it "
      .. "is computed from; the one thing a viewer remembers). Each must be buildable in the engine described by the "
      .. "reference below in under 200 lines of Lua. Then pick the strongest and restate it in full under the heading "
      .. "CHOSEN. Be concrete: numbers, colours as hex, times in seconds.\n\nEngine reference:\n" .. reference(),
    temperature = 1.0,
  }
end

local function lua_rules(kind)
  return "Reply with exactly one ```lua code block holding the complete file, nothing after it. The file must `return "
    .. "e.comp{...}` with `local e = require(\"moonsplice\")` first. Keep it under 260 lines. Pure: no os.*, io.*, "
    .. "math.random or clocks" .. (kind == "game" and "; randomness only from g.random inside the game; the game "
    .. "must carry a `script` of input events that plays it well on its own for the whole duration" or "") .. "."
end

function P.write(ask, kind, treatment, prior, critique)
  local user = "The ask: " .. ask .. "\n\nThe treatment to build, exactly:\n" .. (treatment or "(none yet: make one up "
    .. "that follows the rules above)") .. "\n\n"
  if prior and critique then
    user = user .. "The current file:\n```lua\n" .. prior .. "\n```\n\nThe critic's notes on its frames:\n" .. critique
      .. "\n\nRevise the file to answer the notes without breaking what works.\n\n"
  end
  return {
    system = "You build Moonsplice compositions in Lua, exactly to a treatment. You use the engine's real API and "
      .. "nothing else.\n\n" .. P.bans .. "\n\nEngine reference:\n" .. reference(),
    user = user .. lua_rules(kind), temperature = 0.4,
  }
end

function P.fix(ask, kind, treatment, prior, gate)
  return {
    system = "You repair Moonsplice compositions so they pass the engine's lint and check, changing as little of the "
      .. "design as you can.\n\nEngine reference:\n" .. reference(),
    user = "The ask: " .. ask .. "\n\nThe treatment:\n" .. (treatment or "(none)") .. "\n\nThe current file:\n```lua\n"
      .. (prior or "") .. "\n```\n\nWhat the gate said:\n" .. table.concat(gate.findings or {}, "\n")
      .. "\n\nFix every error (warnings where cheap). " .. lua_rules(kind),
    temperature = 0.3,
  }
end

P.rubric = {
  rule = "Can the piece's governing rule be inferred from these frames alone?",
  relationship = "Is every graphic in a stated relationship with the picture (behind, attached to, cut by, measured "
    .. "from, timed to something), rather than floating on it?",
  defaults = "How free of the banned defaults is it? 5 = none present, 1 = several.",
  rhythm = "Do motion and changes across the frames follow a structure rather than even spacing or randomness?",
  memory = "Is there one frame someone would screenshot? 5 = unmistakably, 1 = nothing distinctive.",
  craft = "Type, colour, spacing and legibility at the level of a good studio (no clipped text, no overlaps, "
    .. "intentional palette).",
}
P.rubric_order = { "rule", "relationship", "defaults", "rhythm", "memory", "craft" }

function P.critic(ask, kind, treatment, sheet_b64, picks)
  local lines = {}
  for i, k in ipairs(P.rubric_order) do lines[i] = ("%s: %s"):format(k, P.rubric[k]) end
  return {
    messages = { { role = "user", content = {
      { type = "text", text = "You are a demanding creative director reviewing a " .. (kind == "game" and "game (a "
        .. "recording of it playing itself)" or "motion piece") .. ". The ask was: " .. ask .. "\n\n"
        .. (treatment and ("Its treatment:\n" .. treatment .. "\n\n") or "")
        .. "The contact sheet shows frames at " .. table.concat(picks or {}, ", ") .. " seconds, left to right, top "
        .. "to bottom.\n\n" .. P.bans .. "\n\nScore each from 1 to 5 (5 = work you would show a client):\n"
        .. table.concat(lines, "\n") .. "\n\nReply with one JSON object only: {\"scores\": {" .. table.concat(
          (function() local t = {} for i, k in ipairs(P.rubric_order) do t[i] = '"' .. k .. '": n' end return t end)(),
          ", ") .. "}, \"banned\": [\"...\"], \"broken\": [\"anything visibly wrong\"], \"notes\": \"the three most "
        .. "important changes, concrete\"}" },
      { type = "image_url", image_url = { url = "data:image/png;base64," .. sheet_b64 } },
    } } },
    temperature = 0.2,
  }
end

-- the one lua block in a reply
function P.code(text)
  local code = text:match("```lua%s*\n(.-)\n```") or text:match("```%w*%s*\n(.-)\n```")
  if not code and text:match("return%s+e%.comp") then code = text end
  return code
end

function P.chosen(text)
  return text:match("CHOSEN[%*:#%s]*\n?(.*)$") or text
end

return P
