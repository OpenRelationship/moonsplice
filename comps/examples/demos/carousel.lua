-- Instagram carousel — "One Speech, Ten Languages".
--
--   MOONSPLICE_LANG=es moonsplice render comps/examples/demos/carousel.lua -o out.mp4
--
-- One slide per language: the full 1962 moon speech at 4:5, JFK's own voice
-- dubbed by Dubbing v2, English captions held still so the words stay readable
-- while the language changes between slides. The English slide (slide 1)
-- carries a "swipe" label pointing at the other nine.
--
-- Dubs are real API returns (POST /v1/dubbing, one job per language) against
-- the same 24.8s clip, timing preserved, so every slide shares one picture.
--
-- Source: JFK at Rice University, 12 Sep 1962. US Government work, public domain.
local e = require("moonsplice")
local ease = require("moonsplice.ease")

local B = "comps/examples/assets/jfk/"
local FPS = 30
local W, H = 1080, 1350

local SPEECH = 24.75
local DUR = SPEECH + 0.9

local LANG = os.getenv("MOONSPLICE_LANG") or "en"
local FONT = "assets/fonts/NotoSans-Bold.ttf"
local LANGS = {
  en = { name = "English",   flag = "us" },
  es = { name = "Español",   flag = "es" },
  hi = { name = "हिन्दी",     flag = "in", font = "assets/fonts/NotoSansDevanagari-Bold.ttf" },
  fr = { name = "Français",  flag = "fr" },
  pt = { name = "Português", flag = "pt" },
  de = { name = "Deutsch",   flag = "de" },
  ja = { name = "日本語",     flag = "jp", font = "assets/fonts/NotoSansJP-Bold.otf" },
  ko = { name = "한국어",     flag = "kr", font = "assets/fonts/NotoSansKR-Bold.otf" },
  it = { name = "Italiano",  flag = "it" },
  zh = { name = "中文",       flag = "cn", font = "assets/fonts/NotoSansSC-Bold.otf" },
}
local L = assert(LANGS[LANG], "unknown MOONSPLICE_LANG: " .. LANG)
local CUES = dofile(B .. "captions.lua")

local SETTLE = ease.spring { stiffness = 150, damping = 23 }

-- procedural flags, same family as moon_demo — deterministic and scale-clean
local FLAG_W, FLAG_H = 44, 30
local function flag_draw(kind)
  return function(v)
    local w, h = FLAG_W, FLAG_H
    if kind == "us" then
      v:rect(0, 0, w, h, { 0.70, 0.11, 0.18, 1 })
      for i = 0, 5 do v:rect(0, h * (2 * i + 1) / 13, w, h / 13, { 1, 1, 1, 1 }) end
      v:rect(0, 0, w * 0.42, h * 7 / 13, { 0.16, 0.20, 0.45, 1 })
    elseif kind == "es" then
      v:rect(0, 0, w, h, { 0.67, 0.06, 0.13, 1 })
      v:rect(0, h * 0.25, w, h * 0.5, { 0.98, 0.78, 0.09, 1 })
    elseif kind == "fr" then
      v:rect(0, 0, w / 3, h, { 0.00, 0.14, 0.58, 1 })
      v:rect(w / 3, 0, w / 3, h, { 1, 1, 1, 1 })
      v:rect(2 * w / 3, 0, w / 3, h, { 0.93, 0.16, 0.22, 1 })
    elseif kind == "it" then
      v:rect(0, 0, w / 3, h, { 0.00, 0.55, 0.27, 1 })
      v:rect(w / 3, 0, w / 3, h, { 1, 1, 1, 1 })
      v:rect(2 * w / 3, 0, w / 3, h, { 0.81, 0.13, 0.16, 1 })
    elseif kind == "de" then
      v:rect(0, 0, w, h / 3, { 0.05, 0.05, 0.05, 1 })
      v:rect(0, h / 3, w, h / 3, { 0.86, 0.09, 0.12, 1 })
      v:rect(0, 2 * h / 3, w, h / 3, { 1, 0.81, 0.00, 1 })
    elseif kind == "pt" then
      v:rect(0, 0, w * 0.40, h, { 0.00, 0.40, 0.25, 1 })
      v:rect(w * 0.40, 0, w * 0.60, h, { 0.85, 0.10, 0.15, 1 })
      v:circle(w * 0.40, h / 2, h * 0.22, { 1, 0.84, 0.15, 1 })
    elseif kind == "in" then
      v:rect(0, 0, w, h / 3, { 1.00, 0.60, 0.20, 1 })
      v:rect(0, h / 3, w, h / 3, { 1, 1, 1, 1 })
      v:rect(0, 2 * h / 3, w, h / 3, { 0.07, 0.53, 0.03, 1 })
      v:circle(w / 2, h / 2, h * 0.16, { 0.00, 0.00, 0.55, 1 })
      v:circle(w / 2, h / 2, h * 0.11, { 1, 1, 1, 1 })
      v:circle(w / 2, h / 2, h * 0.045, { 0.00, 0.00, 0.55, 1 })
    elseif kind == "cn" then
      v:rect(0, 0, w, h, { 0.87, 0.16, 0.06, 1 })
      v:circle(w * 0.20, h * 0.32, h * 0.16, { 1, 0.87, 0.00, 1 })
      v:circle(w * 0.38, h * 0.14, h * 0.05, { 1, 0.87, 0.00, 1 })
      v:circle(w * 0.44, h * 0.32, h * 0.05, { 1, 0.87, 0.00, 1 })
      v:circle(w * 0.44, h * 0.52, h * 0.05, { 1, 0.87, 0.00, 1 })
      v:circle(w * 0.38, h * 0.68, h * 0.05, { 1, 0.87, 0.00, 1 })
    elseif kind == "kr" then
      v:rect(0, 0, w, h, { 1, 1, 1, 1 })
      v:circle(w / 2, h / 2, h * 0.28, { 0.77, 0.16, 0.25, 1 })
      v:rect(w / 2 - h * 0.28, h / 2, h * 0.56, h * 0.28, { 1, 1, 1, 1 })
      v:circle(w / 2 - h * 0.14, h / 2, h * 0.14, { 0.77, 0.16, 0.25, 1 })
      v:circle(w / 2 + h * 0.14, h / 2, h * 0.14, { 0.06, 0.22, 0.58, 1 })
      v:rect(w / 2 - h * 0.28, h / 2 + h * 0.14, h * 0.56, h * 0.14, { 0.06, 0.22, 0.58, 1 })
    else -- jp
      v:rect(0, 0, w, h, { 1, 1, 1, 1 })
      v:circle(w / 2, h / 2, h * 0.30, { 0.74, 0.00, 0.16, 1 })
    end
  end
end

return e.comp {
  width = W, height = H, duration = DUR, fps = FPS, background = "#08080a",

  scene = function(s)
    -- ===== audio: the dub, plus the cinematic bed from the reel render =====
    s:audio { src = B .. "dubs/" .. LANG .. ".audio.mp3",
      at = 0, duration = SPEECH + 0.45, media_start = 0,
      volume = 1.0, duck = true, fade_out = 0.4 }
    s:audio { src = B .. "music_bed.mp3", at = 0, duration = DUR,
      volume = 0.17, fade_in = 1.2, fade_out = 0.8 }

    -- ===== picture: the 4:5 plate, full speech =====
    s:video { src = B .. "moon_v_45.mp4", w = W, h = H,
      x = 0, y = 0, from = 0, duration = DUR, media_start = 0 }

    -- language badge above the caption line, same anatomy as the reel
    local CAP_Y = H - 250
    local BADGE_W, BADGE_H = 258, 62
    local BADGE_Y = CAP_Y - 104
    local badge = s:group { x = W / 2, y = BADGE_Y + BADGE_H / 2 }
    s:rect { parent = badge, x = -BADGE_W / 2, y = -BADGE_H / 2,
      w = BADGE_W, h = BADGE_H, rx = 31, color = "#0e0e10e0" }
    s:rect { parent = badge, x = -BADGE_W / 2 + 2, y = -BADGE_H / 2 + 2,
      w = BADGE_W - 4, h = BADGE_H / 2, rx = 29, color = "#ffffff16" }
    s:vector { parent = badge, w = FLAG_W, h = FLAG_H,
      x = -BADGE_W / 2 + 24, y = -FLAG_H / 2, draw = flag_draw(L.flag) }
    s:text { parent = badge, x = 22, y = 0, text = L.name,
      size = 29, color = "#ffffff", anchor = "center", font = L.font or FONT }

    -- English captions, held still while the voice speaks another language
    local capsh = s:text { x = W / 2 + 4, y = CAP_Y + 4, text = "", size = 47,
      color = "#000000cc", anchor = "center", font = FONT }
    local cap = s:text { x = W / 2, y = CAP_Y, text = "", size = 47,
      color = "#ffffff", anchor = "center", font = FONT }

    -- slide 1 only: tell people the other nine languages exist
    local swipe
    if LANG == "en" then
      local SW_W, SW_H = 640, 56
      swipe = s:group { x = W / 2, y = 96, opacity = 0 }
      s:rect { parent = swipe, x = -SW_W / 2, y = -SW_H / 2,
        w = SW_W, h = SW_H, rx = 28, color = "#0e0e10d6" }
      s:text { parent = swipe, x = 0, y = 0,
        text = "swipe to hear it in 9 more languages  »",
        size = 27, color = "#ffffff", anchor = "center", font = FONT }
    end

    s:script(function(t)
      local function at(x) t:wait(math.max(0, x - t.cursor)) end

      -- badge settles in
      t:set(badge, { scale = 0.9 })
      t:tween(badge, 0.35, { scale = 1 }, SETTLE)

      if swipe then
        at(0.7)
        t:tween(swipe, 0.4, { opacity = 1 }, "quadOut")
        at(5.4)
        t:tween(swipe, 0.5, { opacity = 0 }, "quadIn")
      end

      -- captions: hold each line until the next starts (same rule as the reel)
      local c0 = 0
      t.cursor = c0
      for k, q in ipairs(CUES) do
        at(q.t0)
        t:set(cap, { text = q.text })
        t:set(capsh, { text = q.text })
        local nxt = CUES[k + 1]
        if nxt and nxt.t0 - q.t1 > 0.8 then
          at(q.t1 + 0.35)
          t:set(cap, { text = "" })
          t:set(capsh, { text = "" })
        end
      end
      at(SPEECH - 0.12)
      t:set(cap, { text = "" })
      t:set(capsh, { text = "" })
    end)
  end,
}
