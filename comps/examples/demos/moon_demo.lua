-- Option 2 — "We choose to go to the Moon", dubbed live.
--
--   MOONSPLICE_ASPECT=4:5 moonsplice render comps/examples/demos/moon_demo.lua -o out.mp4
--
-- Structure: JFK's 1962 Rice speech runs full-bleed vertical while the DUB
-- changes language under him — his own voice, his own delivery, four more
-- languages — with a badge above his head naming each one. English captions
-- stay on throughout, so you read the same words while the voice changes. Then
-- it pivots into the product doing exactly that, and cuts to the wordmark.
--
-- The dubs are real: comps/examples/assets/jfk/dubs/*.audio.mp3 came back from
-- POST /v1/dubbing on the same clip, one job per language, timing preserved
-- (every return was 24.82s against a 24.79s source) — which is why one
-- continuous picture can carry all five audio tracks without drifting.
--
-- Source: JFK at Rice University, 12 Sep 1962. US Government work, public domain.
local e = require("moonsplice")
local ease = require("moonsplice.ease")
local demo = require("moonsplice.demo")

local B = "comps/examples/assets/jfk/"
local FPS = 30
local ASPECT = os.getenv("MOONSPLICE_ASPECT") or "4:5"
-- One concept, four shapes. The JFK plate is re-cropped per aspect (never
-- letterboxed), and act two uses the capture recorded at that same shape.
local LAY = {
  ["16:9"] = { W = 1920, H = 1080, rec = "/tmp/rec_a169", plate = "moon_v_169.mp4",
    cap_up = 150, logo = 0.40, pad = 80 * 1.35,
    cam = { drop = 1.22, near = 2.9, send = 3.1 } },
  ["1:1"]  = { W = 1080, H = 1080, rec = "/tmp/rec_a11",  plate = "moon_v_11.mp4",
    cap_up = 190, logo = 0.62, pad = 46 * 1.5,
    cam = { drop = 1.0, near = 2.5, send = 2.7 } },
  ["4:5"]  = { W = 1080, H = 1350, rec = "/tmp/rec_a45",  plate = "moon_v_45.mp4",
    cap_up = 250, logo = 0.62, pad = 46 * 1.5,
    cam = { drop = 1.0, near = 2.5, send = 2.7 } },
  ["9:16"] = { W = 1080, H = 1920, rec = "/tmp/rec_a916", plate = "moon_v_916.mp4",
    cap_up = 430, logo = 0.66, pad = 40 * 1.5,
    cam = { drop = 1.0, near = 2.4, send = 2.6 } },
}
local L = assert(LAY[ASPECT], "unknown MOONSPLICE_ASPECT: " .. ASPECT)
local W, H = L.W, L.H
local REC = L.rec
local META = dofile(REC .. "/meta.lua")
local MK = dofile(REC .. "/markers.lua")
local CUES = dofile(B .. "captions.lua")

local function mark(n)
  for _, m in ipairs(MK) do if m.name == n then return m.t end end
  error("no marker " .. n)
end
local T_UPLOAD, T_PICKER, T_SUBMIT = mark("upload"), mark("open_picker"), mark("submit")
local CUT_F = math.min(META.frames, math.floor((T_SUBMIT + 0.45) * FPS))
local REC_END = CUT_F / FPS

-- ---------- act one: the speech ----------
local SPEECH = 24.75
-- Language order is set by measurement, not taste. Every dub comes back the
-- same total length, but the SPEECH inside it does not: Japanese is far more
-- compact and stops at 21.1s, leaving 3.7s of silence, so it can never hold the
-- final slot — that is what made the voice cut short of the picture. Portuguese
-- runs to 24.1s against English's 24.2s, so it closes.
--   measured speech end: en 24.2 · es 24.0 · fr 24.1 · de 23.9 · pt 24.1 · ja 21.1
local LANGS = {
  { code = "en", name = "English",    flag = "us" },
  { code = "es", name = "Español",    flag = "es" },
  { code = "ja", name = "日本語",      flag = "jp", font = "assets/fonts/NotoSansJP-Bold.otf" },
  { code = "de", name = "Deutsch",    flag = "de" },
  { code = "pt", name = "Português",  flag = "pt" },
}
-- Switch inside the silences JFK actually leaves. These are measured off the
-- audio envelope (contiguous runs under -40 dB), not guessed from word gaps —
-- the real pauses sit at 4.28 / 8.18 / 10.18 / 13.54 / 15.62 / 19.62 / 22.40.
-- Picking 4.28 · 10.18 · 15.62 · 19.62 uses four of the longest (0.48-0.84s)
-- AND keeps the segments even (4.3 · 5.9 · 5.4 · 4.0 · 5.1s); each cut lands on
-- the midpoint of a silence, so the voice never changes on a syllable.
local CUTS = { 0, 4.28, 10.18, 15.62, 19.62, SPEECH }
local FONT = "assets/fonts/NotoSans-Bold.ttf"

local PIVOT = SPEECH                 -- act two starts on the hard cut
local LOGO_AT = PIVOT + REC_END
local DUR = LOGO_AT + 2.8

local SMOOTH = ease.cubicBezier(0.33, 0, 0.15, 1)
local SETTLE = ease.spring { stiffness = 150, damping = 23 }

-- simple procedural flags: reliable, deterministic, and they scale cleanly
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
    elseif kind == "de" then
      v:rect(0, 0, w, h / 3, { 0.05, 0.05, 0.05, 1 })
      v:rect(0, h / 3, w, h / 3, { 0.86, 0.09, 0.12, 1 })
      v:rect(0, 2 * h / 3, w, h / 3, { 1, 0.81, 0.00, 1 })
    elseif kind == "pt" then
      v:rect(0, 0, w * 0.40, h, { 0.00, 0.40, 0.25, 1 })
      v:rect(w * 0.40, 0, w * 0.60, h, { 0.85, 0.10, 0.15, 1 })
      v:circle(w * 0.40, h / 2, h * 0.22, { 1, 0.84, 0.15, 1 })
    else -- jp
      v:rect(0, 0, w, h, { 1, 1, 1, 1 })
      v:circle(w / 2, h / 2, h * 0.30, { 0.74, 0.00, 0.16, 1 })
    end
  end
end

return e.comp {
  width = W, height = H, duration = DUR, fps = FPS, background = "#08080a",

  scene = function(s)
    -- ===== audio =====
    s:music {
      prompt = "Inspirational cinematic bed. Warm sustained strings, soft piano " ..
        "arpeggio, gentle low pulse, hopeful and wide, slow build with an " ..
        "uplifting swell. No vocals, no drums until late, leaves room for a " ..
        "speaking voice. Reverent and forward-looking.",
      gen_duration = 45, at = 0, duration = DUR,
      volume = 0.17, fade_in = 1.2, fade_out = 2.0,
    }

    -- the speech: one continuous picture, the DUB changes underneath it
    for i, L in ipairs(LANGS) do
      local last = (i == #LANGS)
      s:audio { src = B .. "dubs/" .. L.code .. ".audio.mp3",
        at = CUTS[i], duration = (CUTS[i + 1] - CUTS[i]) + (last and 0.45 or 0),
        media_start = CUTS[i], volume = 1.0, duck = true,
        fade_out = last and 0.4 or 0 }
    end

    -- Act two narration, male. Written to convert, not to describe the UI:
    -- proof (what you just heard) -> offer (what it takes you) -> CTA.
    -- Chained with `after` so the lines can never collide inside the ~7.6s the
    -- capture actually runs; the closer lands on the end card.
    local vo1 = s:tts {
      text = "How much of history did you miss, because it wasn't in your language?",
      voice = "george", at = PIVOT + 0.12 }
    local vo2 = s:tts { text = "Upload once. Ship it in ninety two languages.",
      voice = "george", after = { vo1, 0.30 } }
    s:tts { text = "Try it on ElevenLabs.", voice = "george",
      after = { vo2, 0.40 } }

    s:sfx { prompt = "deep cinematic whoosh into soft impact, clean modern logo sting",
      gen_duration = 1.6, at = LOGO_AT - 0.12, volume = 0.5 }

    -- ===== act one visuals =====
    local speech = s:video { src = B .. L.plate, w = W, h = H,
      x = 0, y = 0, from = 0, duration = SPEECH + 0.02, media_start = 0 }

    -- language badge: directly above the caption line, not floating at the top
    local CAP_Y = H - L.cap_up
    local BADGE_W, BADGE_H = 258, 62
    local BADGE_Y = CAP_Y - 104
    local badge = s:group { x = W / 2, y = BADGE_Y + BADGE_H / 2 }
    s:rect { parent = badge, x = -BADGE_W / 2, y = -BADGE_H / 2,
      w = BADGE_W, h = BADGE_H, rx = 31, color = "#0e0e10e0" }
    s:rect { parent = badge, x = -BADGE_W / 2 + 2, y = -BADGE_H / 2 + 2,
      w = BADGE_W - 4, h = BADGE_H / 2, rx = 29, color = "#ffffff16" }
    local flags = {}
    for i, L in ipairs(LANGS) do
      flags[i] = s:vector { parent = badge, w = FLAG_W, h = FLAG_H,
        x = -BADGE_W / 2 + 24, y = -FLAG_H / 2, draw = flag_draw(L.flag),
        opacity = (i == 1) and 1 or 0 }
    end
    local blabel = s:text { parent = badge, x = 22, y = 0, text = LANGS[1].name,
      size = 29, color = "#ffffff", anchor = "center", font = FONT }

    -- captions: one node pair (shadow + face) whose text is SET, never crossfaded.
    -- No scrim behind them — the offset shadow carries legibility on its own.
    local capsh = s:text { x = W / 2 + 4, y = CAP_Y + 4, text = "", size = 47,
      color = "#000000cc", anchor = "center", font = FONT }
    local cap = s:text { x = W / 2, y = CAP_Y, text = "", size = 47,
      color = "#ffffff", anchor = "center", font = FONT }

    -- ===== act two: the product =====
    -- the mesh backdrop for act two lives behind the capture but above the speech
    local back = s:vector {
      w = W, h = H, opacity = 0,
      draw = function(v, t)
        v:rect(0, 0, W, H, { 0.84, 0.62, 0.68, 1 })
        local a, b = math.sin(t * 0.16) * 40, math.cos(t * 0.12) * 34
        local D = math.max(W, H)
        v:radial(W * 0.09 + a, H * 0.07 + b, D * 0.71, { 0.81, 0.35, 0.07, 0.94 }, { 0.81, 0.35, 0.07, 0 })
        v:radial(W * 0.94 - a, H * 0.17 - b, D * 0.68, { 0.80, 0.62, 0.78, 0.92 }, { 0.80, 0.62, 0.78, 0 })
        v:radial(W * 0.85 + b, H * 0.93 + a, D * 0.74, { 0.78, 0.60, 0.71, 0.92 }, { 0.78, 0.60, 0.71, 0 })
        v:radial(W * 0.17 - b, H * 0.97, D * 0.69, { 0.80, 0.54, 0.62, 0.90 }, { 0.80, 0.54, 0.62, 0 })
        v:grain(0.055, 11)
      end,
    }
    local d = demo.live(s, {
      dir = REC, track = dofile(REC .. "/cursor.lua"),
      comp_w = W, comp_h = H,
      cursor = "assets/cursors/pointer_b.png",
      frame = { pad = L.pad, rx = 16, backdrop = false },
      camera = { margin = 1.8, dolly = L.cam.drop, fov = 0.62, maxcoc = 30 },
    })
    d.video.initial.from = PIVOT
    d.video.initial.duration = REC_END
    local F_UP = math.floor(T_UPLOAD * FPS)

    local drag = d:drag(s, { thumb = "comps/examples/assets/el_demos/drag_thumb.png" })

    -- ===== end card =====
    local blackout = s:rect { x = 0, y = 0, w = W, h = H, color = "#08080800" }
    local LW = W * L.logo
    local LH = LW * (534 / 2640)
    local IIW = LW * 0.145
    local LX = W / 2 - LW / 2
    local SEAM = LX + IIW
    local LY = H / 2 - LH / 2
    local maskL = s:rect { x = SEAM, y = LY, w = 0, h = LH, color = "#00000000" }
    local maskR = s:rect { x = SEAM, y = LY, w = 0, h = LH, color = "#00000000" }
    local logoII = s:image { src = "comps/examples/assets/el_demos/wm_ii.png", w = IIW, h = LH,
      x = LX, y = LY, opacity = 0, clip_node = maskL }
    local logoTX = s:image { src = "comps/examples/assets/el_demos/wm_text.png", w = LW - IIW, h = LH,
      x = SEAM, y = LY, opacity = 0, clip_node = maskR }
    -- CTA under the wordmark, revealed by a centre-out wipe (no fades anywhere
    -- on this card), so it reads as part of the same logo move
    local CTA_Y = LY + LH + 54
    local ctaMask = s:rect { x = W / 2, y = CTA_Y - 8, w = 0, h = 62, color = "#00000000" }
    local cta = s:text { x = W / 2, y = CTA_Y + 22, text = "Try it on ElevenLabs",
      size = 40, color = "#e8e8ec", anchor = "center", font = FONT, opacity = 0,
      clip_node = ctaMask }

    s:script(function(t)
      local function at(x) t:wait(math.max(0, x - t.cursor)) end

      -- captions track the English transcript the whole way through, so the
      -- words hold still while the voice changes language underneath them
      -- Hold each line until the NEXT one starts. Blanking at t1 + a pad used
      -- to overrun the following cue, which pushed it late and left the opening
      -- English lines with no subtitle at all.
      local c0 = t.cursor
      for k, q in ipairs(CUES) do
        at(q.t0)
        t:set(cap, { text = q.text })
        t:set(capsh, { text = q.text })
        local nxt = CUES[k + 1]
        if nxt and nxt.t0 - q.t1 > 0.8 then   -- only blank on a real hold
          at(q.t1 + 0.35)
          t:set(cap, { text = "" })
          t:set(capsh, { text = "" })
        end
      end
      at(SPEECH - 0.12)
      t:set(cap, { text = "" })
      t:set(capsh, { text = "" })
      t.cursor = c0

      -- badge: instant swap at a pinch, no crossfade
      for i = 2, #LANGS do
        at(CUTS[i] - 0.1)
        t:tween(badge, 0.1, { scale = 0.9 }, "quadIn")
        t:set(flags[i - 1], { opacity = 0 })
        t:set(flags[i], { opacity = 1 })
        t:set(blabel, { text = LANGS[i].name, font = LANGS[i].font or FONT })
        t:tween(badge, 0.22, { scale = 1 }, SETTLE)
      end

      -- ===== hard cut into the product =====
      at(PIVOT)
      t:set(speech, { opacity = 0 })
      t:set(badge, { opacity = 0 })
      t:set(cap, { text = "" })
      t:set(capsh, { text = "" })
      t:set(back, { opacity = 1 })

      d:drag_play(t, drag, F_UP, { land = PIVOT + T_UPLOAD, ease = SMOOTH })
      local cdrop = t.cursor
      d:play_track(t, F_UP, CUT_F, PIVOT)

      -- camera: ease off the flat pose, truck to the picker, then to send
      t.cursor = cdrop
      local pu, pv = d:track_uv(math.floor(T_PICKER * FPS))
      local su, sv = d:track_uv(math.floor(T_SUBMIT * FPS))
      -- Hold the drop framing. There is no reason to push in on an empty upload
      -- card, and doing it read as a pointless zoom; the ONLY move is the
      -- travel to the language picker.
      at(PIVOT + T_PICKER - 1.15)
      t:parallel(
        function() t:tween(d.video, 1.45, { truck_u = pu, truck_v = pv }, SMOOTH) end,
        function() t:tween(d.video, 1.45, { dolly = L.cam.near, yaw = 0.12, pitch = -0.05 }, SMOOTH) end,
        function() t:tween(d.video, 1.45, { aperture = 44 }, SMOOTH) end
      )
      at(PIVOT + T_PICKER + 0.6)
      t:tween(d.video, 1.4, { yaw = 0.03, pitch = 0.05, roll = -0.015 }, SMOOTH)
      at(PIVOT + T_SUBMIT - 1.2)
      t:parallel(
        function() t:tween(d.video, 1.0, { truck_u = su, truck_v = sv }, SMOOTH) end,
        function() t:tween(d.video, 1.0, { yaw = -0.13, pitch = -0.04, roll = 0 }, SMOOTH) end,
        function() t:tween(d.video, 1.0, { dolly = L.cam.send }, SMOOTH) end
      )

      -- ===== send -> end card =====
      at(LOGO_AT)
      t:set(blackout, { color = "#080808ff" })
      t:set(logoII, { opacity = 1 })
      t:set(logoTX, { opacity = 1 })
      t:set(maskL, { x = SEAM, w = 0 })
      t:set(maskR, { x = SEAM, w = 0 })
      t:set(logoII, { x = LX + LW * 0.045 })
      t:set(logoTX, { x = SEAM - LW * 0.045 })
      t:set(cta, { opacity = 1 })
      t:parallel(
        function() t:tween(maskL, 0.42, { x = LX, w = IIW }, SMOOTH) end,
        function() t:tween(logoII, 0.52, { x = LX }, SMOOTH) end,
        function() t:wait(0.06); t:tween(maskR, 0.60, { w = LW - IIW }, SMOOTH) end,
        function() t:wait(0.06); t:tween(logoTX, 0.66, { x = SEAM }, SMOOTH) end,
        function()
          t:wait(0.44)
          t:tween(ctaMask, 0.50, { x = W / 2 - 320, w = 640 }, SMOOTH)
        end
      )
    end)
  end,
}
