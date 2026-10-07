-- ElevenLabs Dubbing — screen demo, retargetable to any aspect.
--
--   MOONSPLICE_ASPECT=16:9 moonsplice render comps/examples/demos/dub_demo.lua -o out_169.mp4
--   MOONSPLICE_ASPECT=1:1  moonsplice render comps/examples/demos/dub_demo.lua -o out_11.mp4
--   MOONSPLICE_ASPECT=4:5  moonsplice render comps/examples/demos/dub_demo.lua -o out_45.mp4
--
-- One comp, three shapes. The recording for each aspect is captured at a
-- viewport that is ALREADY that shape (tools/record.mjs --aspect=), so nothing
-- is ever a widescreen capture squeezed into a vertical frame. Under 1024 CSS px
-- the app's sidebar collapses on its own, which is what the square/tall crops
-- want. demo.live() reads the recording's meta.lua and fits itself.
--
-- Timing is split by who owns it:
--   · VISUALS are deterministic — driven by the recorder's markers.
--   · NARRATION is placed by ElevenLabs forced alignment: `align_at` slides a
--     line so a chosen WORD is spoken exactly on a chosen frame. Each aspect
--     records slightly different cursor travel, so the marker times differ —
--     and the voiceover re-syncs itself to each one with no hand-editing.
local e = require("moonsplice")
local ease = require("moonsplice.ease")
local demo = require("moonsplice.demo")

local ASPECT = os.getenv("MOONSPLICE_ASPECT") or "16:9"
-- MOONSPLICE_CAM3D=1 puts the capture on a plane in 3D: the camera trucks across the
-- page to whatever the cursor is doing, with real defocus falling off the tilt.
-- Off by default so the shipped flat renders stay byte-identical.
local CAM3D = os.getenv("MOONSPLICE_CAM3D") == "1"
local B = "comps/examples/assets/el_demos/"

-- ---------- per-aspect layout ----------
-- `tabs = "inline"` overlays the language pills on the video (wide frames have
-- the room). `tabs = "below"` puts them under a full-bleed video, with the
-- cursor working down there too — the only sane read on square/vertical.
local LAY = {
  ["16:9"] = { rec = "/tmp/rec_a169", W = 1920, H = 1080, tabs = "inline",
    PW = 1760, PH = 990, PY = 540, TW = 226, TH = 58, GAP = 12, TSZ = 29,
    LOGO_W = 0.40, PAD = 80,
    cam = { padx = 1.35, drop = 1.22, rise = 1.7, near = 2.9, send = 3.1 } },
  ["1:1"] = { rec = "/tmp/rec_a11", W = 1080, H = 1080, tabs = "below",
    PW = 1080, PH = 608, PY = 470, TW = 196, TH = 54, GAP = 10, TSZ = 25,
    LOGO_W = 0.62, PAD = 46,
    cam = { padx = 1.5, drop = 1.0, rise = 1.45, near = 2.5, send = 2.7 } },
  ["4:5"] = { rec = "/tmp/rec_a45", W = 1080, H = 1350, tabs = "below",
    PW = 1080, PH = 608, PY = 620, TW = 196, TH = 54, GAP = 10, TSZ = 25,
    LOGO_W = 0.62, PAD = 46,
    cam = { padx = 1.5, drop = 1.0, rise = 1.45, near = 2.5, send = 2.7 } },
  ["9:16"] = { rec = "/tmp/rec_a916", W = 1080, H = 1920, tabs = "below",
    PW = 1080, PH = 608, PY = 840, TW = 196, TH = 54, GAP = 10, TSZ = 25,
    LOGO_W = 0.66, PAD = 40,
    cam = { padx = 1.5, drop = 1.0, rise = 1.45, near = 2.4, send = 2.6 } },
}
local L = assert(LAY[ASPECT], "unknown MOONSPLICE_ASPECT: " .. ASPECT)
local W, H, FPS = L.W, L.H, 30

local META = dofile(L.rec .. "/meta.lua")
local MK = dofile(L.rec .. "/markers.lua")
local function mark(name)
  for _, m in ipairs(MK) do if m.name == name then return m.t end end
  error("no marker named " .. name)
end

local T_UPLOAD = mark("upload")
local T_PICKER = mark("open_picker")
local T_SUBMIT = mark("submit")
-- trim the dead tail after the submit click; never past what was captured
local CUT_F = math.min(META.frames, math.floor((T_SUBMIT + 0.5) * FPS))
local REC_END = CUT_F / FPS

local SMOOTH = ease.cubicBezier(0.33, 0, 0.15, 1)
local EASEOUT = "cubicOut"
local SETTLE = ease.spring { stiffness = 150, damping = 23 }

local LANGS = {
  { "English", "ny5ykdiwmb.mp3" }, { "Español", "v9grnli26c.mp3" },
  { "Português", "ovfai5i88jd.mp3" }, { "Deutsch", "jicvfwkdre9.mp3" },
  { "Italiano", "jv1qox38gml.mp3" },
}
local ROW_W = #LANGS * L.TW + (#LANGS - 1) * L.GAP
local function tabx(i) return -ROW_W / 2 + (i - 1) * (L.TW + L.GAP) end
-- inline: pills sit inside the video's lower edge. below: under a full-bleed video.
local ROW_Y = L.tabs == "inline" and (L.PH / 2 - 104) or (L.PH / 2 + 54)

local ARRIVE = REC_END + 0.15
-- vo4 ("Every voice...") is 2.65s and must land clear of the dubbed audio, so
-- the player holds on its poster while the line plays, then the cursor hits
-- play. Nothing overlaps; ducking below is the safety net, not the plan.
local VO4_AT = ARRIVE + 0.15
local VO4_LEN = 2.65
local PLAY_AT = VO4_AT + VO4_LEN + 0.4
local SEG = 2.55
local LOGO_AT = PLAY_AT + #LANGS * SEG
local DUR = LOGO_AT + 2.6

return e.comp {
  width = W, height = H, duration = DUR, fps = FPS, background = "#d8969f",

  scene = function(s)
    -- mesh-gradient backdrop (never a flat background), sized to the frame
    s:vector {
      w = W, h = H,
      draw = function(v, t)
        v:rect(0, 0, W, H, { 0.84, 0.62, 0.68, 1 })
        local a, b = math.sin(t * 0.16) * 54, math.cos(t * 0.12) * 46
        local D = math.max(W, H)
        v:radial(W * 0.09 + a, H * 0.07 + b, D * 0.71, { 0.81, 0.35, 0.07, 0.94 }, { 0.81, 0.35, 0.07, 0 })
        v:radial(W * 0.94 - a, H * 0.17 - b, D * 0.68, { 0.80, 0.62, 0.78, 0.92 }, { 0.80, 0.62, 0.78, 0 })
        v:radial(W * 0.85 + b, H * 0.93 + a, D * 0.74, { 0.78, 0.60, 0.71, 0.92 }, { 0.78, 0.60, 0.71, 0 })
        v:radial(W * 0.17 - b, H * 0.97, D * 0.69, { 0.80, 0.54, 0.62, 0.90 }, { 0.80, 0.54, 0.62, 0 })
        v:radial(W * 0.5, H * 0.46, D * 0.45, { 1, 1, 1, 0.30 }, { 1, 1, 1, 0 })
        v:grain(0.055, 11)
      end,
    }

    -- ===== audio =====
    -- Each line is positioned by forced alignment: the named word lands on the
    -- frame where the thing actually happens. Marker times differ per aspect;
    -- these three lines retime themselves accordingly.
    s:tts { text = "Drop in any video.", voice = "sarah",
      align_at = { word = "Drop", at = T_UPLOAD } }
    s:tts { text = "Pick from over ninety languages.", voice = "sarah",
      align_at = { word = "Pick", at = T_PICKER } }
    s:tts { text = "Then send it.", voice = "sarah",
      align_at = { word = "send", at = T_SUBMIT } }
    s:tts { text = "Every voice, every emotion, carried across.",
      voice = "sarah", at = VO4_AT }

    s:music {
      prompt = "Upbeat modern electronic pop bed for a product launch. Bright plucky " ..
        "synth arpeggio, punchy four-on-the-floor kick, crisp claps, warm sub bass, " ..
        "optimistic and playful. Energetic but clean, no vocals, steady 118 BPM, " ..
        "loopable, leaves space for a voiceover.",
      gen_duration = 30, at = 0, duration = DUR,
      volume = 0.13, fade_in = 0.5, fade_out = 1.8,
    }

    -- dubbed clip audio: one continuous performance, language swaps on the grid.
    -- `duck = true` puts these on the sidechain — system audio drops only while
    -- the narrator is actually speaking, then comes straight back to full,
    -- because hearing the dub IS the demo. The last one tails past the hard cut
    -- with a fade so the track never pops off.
    for i, La in ipairs(LANGS) do
      local last = (i == #LANGS)
      s:audio { src = B .. La[2], at = PLAY_AT + (i - 1) * SEG,
        duration = SEG + (last and 0.85 or 0),
        media_start = 0.3 + (i - 1) * SEG,
        volume = 1.0, duck = true,
        fade_out = last and 0.8 or 0 }
    end

    -- transition sfx, mixed well under the voice: presence, not punctuation
    s:sfx { prompt = "soft muted thud, single ui drop impact, short", gen_duration = 0.6,
      at = T_UPLOAD, volume = 0.42 }
    s:sfx { prompt = "very short soft click, ui button press", gen_duration = 0.5,
      at = T_SUBMIT, volume = 0.33 }
    s:sfx { prompt = "smooth fast whoosh, air swoosh transition, short clean",
      gen_duration = 0.9, at = ARRIVE - 0.28, volume = 0.3 }
    for i = 2, #LANGS do
      s:sfx { prompt = "tiny soft tick, subtle ui toggle", gen_duration = 0.5,
        at = PLAY_AT + (i - 1) * SEG, volume = 0.22 }
    end
    s:sfx { prompt = "deep cinematic whoosh into soft impact, clean modern logo sting",
      gen_duration = 1.6, at = LOGO_AT - 0.12, volume = 0.5 }

    -- ===== recording: self-fits from the recorder's meta.lua =====
    local d = demo.live(s, {
      dir = L.rec, track = dofile(L.rec .. "/cursor.lua"),
      comp_w = W, comp_h = H,
      cursor = "assets/cursors/pointer_b.png",
      -- a 16:9 capture in a 16:9 frame already fills it, so a camera that
      -- pushes in would only ever crop. Park it smaller when CAM3D is on and
      -- the push-in has somewhere to go.
      frame = { pad = CAM3D and (L.PAD * L.cam.padx) or L.PAD, rx = 16, backdrop = false },
      -- identity pose: at yaw/pitch/roll 0, dolly 1, truck centred, the 3D
      -- projection IS the flat render, so the drag-and-drop below still lands
      -- on the right pixels. The camera only leaves identity after the drop.
      camera = CAM3D and { margin = 1.8, dolly = L.cam.drop, fov = 0.62, maxcoc = 30 } or nil,
    })
    local F_UP = math.floor(T_UPLOAD * FPS)
    local rest_y = d.video.initial.y
    d.video.initial.duration = REC_END
    d.video.initial.y = rest_y + 90

    -- Drag ghost + grab cursor. Sizes and the carry offset come from the
    -- recording scale inside demo.lua, so this is aspect-correct by
    -- construction — there is nothing here to re-tune per aspect.
    local drag = d:drag(s, { thumb = B .. "drag_thumb.png" })

    -- ===== player: ONE video, audio switches under it =====
    local player = s:group { x = W / 2, y = H + L.PH }
    s:video { parent = player, src = B .. "dp_EN.mp4", w = L.PW, h = L.PH,
      x = 0, y = 0, anchor = "center", rx = 22,
      shadow = { blur = 70, alpha = 0.34, dy = 26 },
      from = PLAY_AT, duration = #LANGS * SEG, media_start = 0.3 }
    local poster = s:image { parent = player, src = B .. "poster.png",
      w = L.PW, h = L.PH, x = 0, y = 0, anchor = "center", rx = 22,
      shadow = { blur = 70, alpha = 0.34, dy = 26 } }
    local pbtn = s:vector { parent = player, w = 240, h = 240, x = 0, y = 0,
      anchor = "center",
      draw = function(v)
        v:circle(120, 120, 74, { 0, 0, 0, 0.34 })
        v:circle(120, 120, 66, { 1, 1, 1, 0.96 })
        v:move(104, 88); v:line(160, 120); v:line(104, 152)
        v:fill({ 0.05, 0.05, 0.05, 1 })
      end }

    s:rect { parent = player, x = -ROW_W / 2 - 12, y = ROW_Y - 9,
      w = ROW_W + 24, h = L.TH + 18, rx = 22,
      color = L.tabs == "inline" and "#121212a6" or "#12121266" }
    local pillsh = s:rect { parent = player, x = tabx(1), y = ROW_Y + 3,
      w = L.TW, h = L.TH, rx = 14, color = "#00000038" }
    local pill = s:rect { parent = player, x = tabx(1), y = ROW_Y,
      w = L.TW, h = L.TH, rx = 14, color = "#fdfcfc" }
    local pillhi = s:rect { parent = player, x = tabx(1) + 2, y = ROW_Y + 1,
      w = L.TW - 4, h = L.TH / 2, rx = 12, color = "#ffffff55" }
    local lbl, lblDark = {}, {}
    for i, La in ipairs(LANGS) do
      lbl[i] = s:text { parent = player, x = tabx(i) + L.TW / 2, y = ROW_Y + L.TH / 2,
        text = La[1], size = L.TSZ, color = "#f2f2f2", anchor = "center" }
    end
    -- dark copy of every label, clipped to the pill: the colour inverts exactly
    -- where the pill covers it, so it tracks the slide instead of cross-fading
    for i, La in ipairs(LANGS) do
      lblDark[i] = s:text { parent = player, x = tabx(i) + L.TW / 2, y = ROW_Y + L.TH / 2,
        text = La[1], size = L.TSZ, color = "#101010", anchor = "center", clip_node = pill }
    end
    -- pointer_b.png is 32x32 with the arrow at (8,6); tabcur positions are the
    -- TARGET point, and CUR_HX/CUR_HY back the sprite off so its tip lands there
    local CUR_W = 44
    local CUR_HX, CUR_HY = CUR_W * 8 / 32, CUR_W * 6 / 32
    local tabcur = s:image { parent = player, src = "assets/cursors/pointer_b.png",
      w = CUR_W, h = CUR_W, x = -8, y = 6, opacity = 0 }

    local blackout = s:rect { x = 0, y = 0, w = W, h = H, color = "#08080800" }
    -- end card: "II" and "ElevenLabs" unmask outward from the seam between them
    local LW = W * L.LOGO_W
    local LH = LW * (534 / 2640)
    local IIW = LW * 0.145
    local LX = W / 2 - LW / 2
    local SEAM = LX + IIW
    local LY = H / 2 - LH / 2
    local maskL = s:rect { x = SEAM, y = LY, w = 0, h = LH, color = "#00000000" }
    local maskR = s:rect { x = SEAM, y = LY, w = 0, h = LH, color = "#00000000" }
    local logoII = s:image { src = B .. "wm_ii.png", w = IIW, h = LH,
      x = LX, y = LY, opacity = 0, clip_node = maskL }
    local logoTX = s:image { src = B .. "wm_text.png", w = LW - IIW, h = LH,
      x = SEAM, y = LY, opacity = 0, clip_node = maskR }
    -- CTA under the wordmark, centre-out wipe to match the logo move
    local CTA_Y = LY + LH + LH * 0.35
    local CTA_SZ = math.floor(W * 0.037)
    local ctaMask = s:rect { x = W / 2, y = CTA_Y - CTA_SZ * 0.2, w = 0, h = CTA_SZ * 1.6,
      color = "#00000000" }
    local cta = s:text { x = W / 2, y = CTA_Y + CTA_SZ * 0.55, text = "Try it on ElevenLabs",
      size = CTA_SZ, color = "#e8e8ec", anchor = "center", opacity = 0, clip_node = ctaMask }

    s:script(function(t)
      local function at(x) t:wait(math.max(0, x - t.cursor)) end

      t:tween(d.video, 0.7, { y = rest_y }, SMOOTH)

      -- drag in and drop on the real upload frame; the grab cursor hands off
      -- to the recorded track on the same pixel, so it never blinks out
      -- drag_play leaves the head at the drop instant (its pulse rides alongside)
      d:drag_play(t, drag, F_UP, { land = T_UPLOAD, ease = SMOOTH })
      local cdrop = t.cursor
      d:play_track(t, F_UP, CUT_F, 0)

      if CAM3D then
        -- Camera pass, recorded over the top of the track playback. Truck
        -- targets come from the recorded cursor at each marker, so the shot
        -- travels to the dropdown and then to the send button rather than
        -- pivoting the middle of the page the whole time.
        t.cursor = cdrop
        local pu, pv = d:track_uv(math.floor(T_PICKER * FPS))
        local su, sv = d:track_uv(math.floor(T_SUBMIT * FPS))

        -- Hold the drop framing — pushing in on an empty upload card reads as a
        -- pointless zoom. The only move is the travel to the language picker.
        at(T_PICKER - 1.2)
        t:parallel(
          function() t:tween(d.video, 1.5, { truck_u = pu, truck_v = pv }, SMOOTH) end,
          function() t:tween(d.video, 1.5, { dolly = L.cam.near, yaw = 0.12, pitch = -0.05 }, SMOOTH) end,
          function() t:tween(d.video, 1.5, { aperture = 40 }, SMOOTH) end
        )
        -- hold on the dropdown while it is typed into, drifting slightly
        at(T_PICKER + 0.6)
        t:tween(d.video, 1.5, { yaw = 0.03, pitch = 0.05, roll = -0.015 }, SMOOTH)
        -- then travel to the send button and settle square-on for the click
        at(T_SUBMIT - 1.25)
        t:parallel(
          function() t:tween(d.video, 1.05, { truck_u = su, truck_v = sv }, SMOOTH) end,
          function() t:tween(d.video, 1.05, { yaw = -0.14, pitch = -0.04, roll = 0 }, SMOOTH) end,
          function() t:tween(d.video, 1.05, { dolly = L.cam.send }, SMOOTH) end
        )
        -- pull back wide and deep so the cut to the player reads clean
        at(T_SUBMIT + 0.12)
        t:parallel(
          function() t:tween(d.video, 0.55, { dolly = L.cam.drop, yaw = 0, pitch = 0, roll = 0 }, SMOOTH) end,
          function() t:tween(d.video, 0.55, { truck_u = 0.5, truck_v = 0.5 }, SMOOTH) end,
          function() t:tween(d.video, 0.55, { aperture = 0 }, SMOOTH) end
        )
        t.cursor = cdrop
      end

      -- submit → cut straight to the player, no dead frames
      at(REC_END)
      t:set(d.video, { y = H * 2 })
      t:set(d.cursor, { y = H * 2 })
      t:tween(player, 0.6, { y = L.PY }, SETTLE)

      -- cursor presses PLAY, then picture and clip audio start together
      -- the VO line runs while the player holds on its poster; walk the cursor
      -- in across that whole window so nothing sits frozen waiting for audio
      at(ARRIVE + 0.5)
      t:set(tabcur, { x = L.PW * 0.30, y = L.PH * 0.30, opacity = 1 })
      t:path(tabcur, (PLAY_AT - 0.28) - (ARRIVE + 0.5),
        { { L.PW * 0.13, L.PH * 0.10 }, { -CUR_HX, -CUR_HY } }, SMOOTH)
      at(PLAY_AT - 0.1)
      t:tween(tabcur, 0.08, { scale = 0.85 }, "quadIn")
      at(PLAY_AT)
      t:parallel(
        function() t:tween(tabcur, 0.14, { scale = 1 }, EASEOUT) end,
        function() t:tween(pbtn, 0.12, { scale = 0.86 }, "quadOut") end
      )
      t:set(poster, { opacity = 0 })
      t:set(pbtn, { opacity = 0 })
      t:tween(tabcur, 0.35, { x = tabx(1) + L.TW / 2 - CUR_HX, y = ROW_Y + L.TH / 2 - CUR_HY }, SMOOTH)

      -- language switches: only audio + pill move; the picture never cuts
      for i = 2, #LANGS do
        local tc = PLAY_AT + (i - 1) * SEG
        at(tc - 0.4)
        t:path(tabcur, 0.28, { { tabx(i) + L.TW / 2 - CUR_HX, ROW_Y + L.TH / 2 - CUR_HY } }, SMOOTH)
        at(tc - 0.08)
        t:tween(tabcur, 0.07, { scale = 0.85 }, "quadIn")
        at(tc)
        t:parallel(
          function() t:tween(tabcur, 0.13, { scale = 1 }, EASEOUT) end,
          function() t:tween(pill, 0.26, { x = tabx(i) }, SMOOTH) end,
          function() t:tween(pillsh, 0.26, { x = tabx(i) }, SMOOTH) end,
          function() t:tween(pillhi, 0.26, { x = tabx(i) + 2 }, SMOOTH) end
        )
      end

      -- hard cut to black; the wordmark unmasks outward from the seam
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
          t:tween(ctaMask, 0.50, { x = W / 2 - LW * 0.46, w = LW * 0.92 }, SMOOTH)
        end
      )
    end)
  end,
}
