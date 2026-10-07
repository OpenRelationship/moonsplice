-- Yumion promo: a 22 second vertical motion piece for the iPhone app (yumion.com), upbeat and warm rather
-- than corporate. The brand is the app's own: paper and ink, a leaf green highlighter, heavy type, hard ink
-- shadows, graph paper, and Oni the onion. Timed to 120 bpm (a beat is 0.5s) so a music bed can be laid under it.
--
-- Seven scenes, each its own comp, laid end to end as precomps; a two-layer wipe (ink, then leaf) covers
-- each cut. hello, pricey, scan, card, deal, dinner, end.
--
-- Type is SF Pro (Heavy, Semibold, Medium), cut as static instances from the system's variable font into
-- ~/.cache/moonsplice/fonts with fontTools (instancer: wght 820/590/510, wdth 100, opsz 96/28, GRAD 400).
-- Apple's licence does not let SF be committed here, so a machine without those files has no type.
local e = require("moonsplice")
local PAPER, INK, LEAF = "#F8F6EF", "#24221D", "#7FA848"

local scenes = { { "hello", 0.0 }, { "pricey", 2.5 }, { "scan", 5.0 }, { "card", 9.0 }, { "deal", 13.0 },
  { "dinner", 16.5 }, { "end", 19.0 } }

local nodes = {
  -- graph paper, drifting up slowly
  { id = "grid", kind = "vector", x = 0, y = 0, w = 1080, h = 1920, draw = { fn = [[
    return function(v, t)
      local step, c = 60, "#5E8F3A24"
      local off = (t * 18) % step
      for x = 0, 1080, step do v:rect(x, 0, 2, 1920, c) end
      for y = -step, 1920, step do v:rect(0, y - off, 1080, 2, c) end
    end ]] } },
}
for _, s in ipairs(scenes) do
  nodes[#nodes + 1] = { id = s[1], kind = "precomp", src = s[1] .. ".lua", start = s[2] }
end
nodes[#nodes + 1] = { id = "wipe_ink", kind = "rect", x = -1100, y = 0, w = 1080, h = 1920, color = INK }
nodes[#nodes + 1] = { id = "wipe_leaf", kind = "rect", x = -1100, y = 0, w = 1080, h = 1920, color = LEAF }

-- each cut (where a scene hands over) is covered: ink sweeps in, leaf right behind it, both sweep out
local keys = {}
for i = 2, #scenes do
  local c = scenes[i][2] + 0.05
  for j, id in ipairs({ "wipe_ink", "wipe_leaf" }) do
    local d = (j - 1) * 0.05
    keys[#keys + 1] = { id, "x", c - 0.3 + d, -1100, "step" }
    keys[#keys + 1] = { id, "x", c - 0.08 + d, 0, "cubicIn" }
    keys[#keys + 1] = { id, "x", c + 0.04 + d, 0 }
    keys[#keys + 1] = { id, "x", c + 0.3 + d, 1100, "expoOut" }
  end
end

return e.comp {
  width = 1080, height = 1920, duration = 22, fps = 30, background = PAPER,
  nodes = nodes,
  keys = keys,
}
