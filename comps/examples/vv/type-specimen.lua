-- Type specimen reel: seven non-default faces, seven kinds of text motion.
-- Black field, VV register. Rendered through moonsplice-scene (MOONSPLICE_SCENE=1).
local e = require("moonsplice")

local W, H = 1080, 1080
local F = "comps/examples/vv/fonts/"
local DIM = "#8a8f98"

return e.comp {
  width = W, height = H, duration = 28, fps = 30, background = "#000000",

  scene = function(s)
    -- plate corners
    s:vector { x = 0, y = 0, w = W, h = H, draw = function(v, t)
      local m, l = 60, 26
      for _, c in ipairs({ { m, m, 1, 1 }, { W - m, m, -1, 1 }, { m, H - m, 1, -1 }, { W - m, H - m, -1, -1 } }) do
        v:move(c[1], c[2] + c[4] * l); v:line(c[1], c[2]); v:line(c[1] + c[3] * l, c[2]); v:stroke(2, { 1, 1, 1, 0.35 })
      end
    end }

    local function label(text)
      return s:text { x = 540, y = 820, text = text, size = 30, anchor = "center", color = DIM, opacity = 0, tracking = 3,
        font = F .. "DMMono-Regular.ttf" }
    end

    -- 1  Instrument Serif · tracking breathes open, italic answers
    local a1 = s:text { x = 540, y = 430, text = "Instrument", size = 150, anchor = "center", color = "#ffffff", opacity = 0,
      font = F .. "InstrumentSerif-Regular.ttf", tracking = -6 }
    local a2 = s:text { x = 540, y = 560, text = "serif, in italic", size = 72, anchor = "center", color = "#ffffff", opacity = 0,
      font = F .. "InstrumentSerif-Italic.ttf", tracking = 0 }
    local l1 = label("01  instrument serif · tracking")

    -- 2  Bebas Neue · kinetic rise, per character, backOut
    local b1 = s:kinetic { x = 540, y = 470, text = "IMPACT", size = 260, color = "#ffffff", opacity = 0, spacing = 18,
      font = F .. "BebasNeue-Regular.ttf" }
    local l2 = label("02  bebas neue · kinetic stagger")

    -- 3  Space Grotesk · wrapped paragraph types on, tagged colour
    local c1 = s:text { x = 150, y = 330, wrap = 780, leading = 1.15, reveal = 0, size = 54, opacity = 0, color = "#e8edf7",
      font = F .. "SpaceGrotesk[wght].ttf",
      text = "A paragraph is a {c:#3ee0c6}shape{/c} too. It wraps to a column, keeps its {c:#5e8bff}leading{/c}, and types on in seek-safe time." }
    local l3 = label("03  space grotesk · wrap + reveal")

    -- 4  DM Mono · typewriter with a blinking block cursor
    local d1 = s:text { x = 150, y = 470, text = "moonsplice render comp.lua -o out.mp4", size = 36, reveal = 0, opacity = 0,
      color = "#ffffff", font = F .. "DMMono-Regular.ttf" }
    local cursor = s:rect { x = 150, y = 474, w = 20, h = 42, color = "#3ee0c6", opacity = 0 }
    local l4 = label("04  dm mono · typewriter")

    -- 5  Playfair Display · outline breathes into fill
    local p1 = s:text { x = 540, y = 470, text = "Playfair", size = 210, anchor = "center", color = "#000000",
      outline = 0.9, weight = 0, outline_color = "#ffffff", opacity = 0,
      font = "comps/assets/fonts/PlayfairDisplay.ttf" }
    local l5 = label("05  playfair · outline to fill")

    -- 6  Cormorant Garamond · characters settle from rotation and scale
    local g1 = s:kinetic { x = 540, y = 470, text = "settle", size = 240, color = "#ffffff", opacity = 0, spacing = 6,
      rotation = -0.35, scale = 1.6, font = F .. "CormorantGaramond[wght].ttf" }
    local l6 = label("06  cormorant · rotate + scale")

    -- 7  Unbounded · wide display, tracking collapses, opacity pulse across chars
    local u1 = s:kinetic { x = 540, y = 470, text = "WIDE", size = 220, color = "#ffffff", opacity = 0, spacing = 40,
      font = F .. "Unbounded[wght].ttf" }
    local l7 = label("07  unbounded · opacity wave")

    -- end: Syne
    local z1 = s:text { x = 540, y = 500, text = "moonsplice", size = 110, anchor = "center", color = "#ffffff", opacity = 0,
      tracking = 30, font = F .. "Syne[wght].ttf" }
    local z2 = label("type is a path. every property, a curve.")

    local function fade_out(t, nodes, d)
      local fns = {}
      for _, n in ipairs(nodes) do fns[#fns + 1] = function() t:tween(n, d, { opacity = 0 }, "sineIn") end end
      t:parallel(unpack(fns))
    end

    s:script(function(t)
      -- 01 (0–4)
      t:wait(0.4)
      t:parallel(
        function() t:tween(a1, 1.4, { opacity = 1, tracking = 4 }, "cubicOut") end,
        function() t:wait(0.6); t:tween(a2, 1.0, { opacity = 1 }, "sineOut") end,
        function() t:wait(0.3); t:tween(l1, 0.5, { opacity = 1 }, "sineOut") end)
      t:wait(1.4)
      fade_out(t, { a1, a2, l1 }, 0.4)
      -- 02 (4–8)
      t:parallel(
        function() t:stagger(b1.chars, 0.7, { y = 470 }, { each = 0.06, ease = "backOut" }) end,
        function() t:stagger(b1.chars, 0.5, { opacity = 1 }, { each = 0.06, ease = "sineOut" }) end,
        function() t:wait(0.3); t:tween(l2, 0.5, { opacity = 1 }, "sineOut") end)
      t:wait(1.6)
      t:parallel(
        function() t:stagger(b1.chars, 0.35, { opacity = 0, y = 420 }, { each = 0.04, ease = "sineIn" }) end,
        function() t:tween(l2, 0.4, { opacity = 0 }, "sineIn") end)
      -- 03 (8–13)
      t:parallel(
        function() t:set(c1, { opacity = 1 }); t:tween(c1, 2.6, { reveal = 1 }, "linear") end,
        function() t:wait(0.3); t:tween(l3, 0.5, { opacity = 1 }, "sineOut") end)
      t:wait(1.3)
      fade_out(t, { c1, l3 }, 0.4)
      -- 04 (13–17)
      t:parallel(
        function() t:set(d1, { opacity = 1 }); t:tween(d1, 2.0, { reveal = 1 }, "linear") end,
        function() t:set(cursor, { opacity = 1 }); t:tween(cursor, 2.0, { x = 150 + 36 * 21.6 }, "linear")
          for _ = 1, 3 do t:tween(cursor, 0.25, { opacity = 0 }, "linear"); t:tween(cursor, 0.25, { opacity = 1 }, "linear") end end,
        function() t:wait(0.3); t:tween(l4, 0.5, { opacity = 1 }, "sineOut") end)
      t:wait(0.2)
      fade_out(t, { d1, cursor, l4 }, 0.4)
      -- 05 (17–21)
      t:parallel(
        function() t:tween(p1, 0.5, { opacity = 1 }, "sineOut"); t:tween(p1, 1.8, { color = "#ffffff", outline = 0.25, weight = 0.15 }, "cubicInOut") end,
        function() t:wait(0.3); t:tween(l5, 0.5, { opacity = 1 }, "sineOut") end)
      t:wait(1.2)
      fade_out(t, { p1, l5 }, 0.4)
      -- 06 (21–24.5)
      t:parallel(
        function() t:stagger(g1.chars, 0.9, { opacity = 1, rotation = 0, scale = 1 }, { each = 0.08, ease = "expoOut" }) end,
        function() t:wait(0.3); t:tween(l6, 0.5, { opacity = 1 }, "sineOut") end)
      t:wait(1.4)
      t:parallel(
        function() t:stagger(g1.chars, 0.4, { opacity = 0 }, { each = 0.03, ease = "sineIn" }) end,
        function() t:tween(l6, 0.4, { opacity = 0 }, "sineIn") end)
      -- 07 (24.5–26.5)
      t:parallel(
        function()
          t:stagger(u1.chars, 0.5, { opacity = 1 }, { each = 0.1, ease = "sineOut" })
          t:stagger(u1.chars, 0.4, { opacity = 0.25 }, { each = 0.1, ease = "sineInOut" })
          t:stagger(u1.chars, 0.4, { opacity = 1 }, { each = 0.1, ease = "sineInOut" })
        end,
        function() t:wait(0.3); t:tween(l7, 0.5, { opacity = 1 }, "sineOut") end)
      t:wait(0.2)
      t:parallel(
        function() t:stagger(u1.chars, 0.3, { opacity = 0 }, { each = 0.03, ease = "sineIn" }) end,
        function() t:tween(l7, 0.3, { opacity = 0 }, "sineIn") end)
      -- end (≈26.5–28)
      t:parallel(
        function() t:tween(z1, 0.8, { opacity = 1, tracking = 6 }, "cubicOut") end,
        function() t:wait(0.3); t:tween(z2, 0.5, { opacity = 1 }, "sineOut") end)
    end)
  end,
}
