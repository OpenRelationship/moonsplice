-- Meet Moonsplice launch spot — driven by editor __doc binding (doc.json).
-- Transcript words, keyframes, scenes, and param chips all compile into __doc.
local e = require("moonsplice")
local ease = require("moonsplice.ease")
local captions = require("moonsplice.captions")

local doc = __doc or {}
local p = doc.params or __doc_params or {}

local function scene_at(id, fallback)
  for _, sc in ipairs(doc.scenes or {}) do
    if sc.id == id then return sc.at, sc.duration end
  end
  return fallback, 2
end

local function kf_t(id, fallback)
  for _, kf in ipairs(doc.keyframes or {}) do
    if kf.id == id then return kf.t end
  end
  return fallback
end

local function word_start(needle, fallback)
  local want = needle:lower():gsub("[^%w]", "")
  for _, w in ipairs(doc.words or {}) do
    if w.text:lower():gsub("[^%w]", "") == want then return w.t0 end
  end
  return fallback
end

local function word_end(needle, fallback)
  local want = needle:lower():gsub("[^%w]", "")
  for _, w in ipairs(doc.words or {}) do
    if w.text:lower():gsub("[^%w]", "") == want then return w.t1 end
  end
  return fallback
end

local function parse_ease(name)
  if type(name) ~= "string" then return ease.cubicBezier(0.16, 1, 0.3, 1) end
  local x1, y1, x2, y2 = name:match("cubic%-bezier%(([%d%.]+),([%d%.]+),([%d%.]+),([%d%.]+)%)")
  if x1 then return ease.cubicBezier(tonumber(x1), tonumber(y1), tonumber(x2), tonumber(y2)) end
  local ok, fn = pcall(ease.get, name)
  if ok then return fn end
  return ease.cubicBezier(0.16, 1, 0.3, 1)
end

local logoScale = tonumber(p.logoScale) or 1.08
local logoDuration = tonumber(p.logoDuration) or 0.65
local uiBlur = tonumber(p.uiBlur) or 24
local uiStagger = tonumber(p.uiStagger) or 0.08
local montageBpm = tonumber(p.montageBpm) or 128
local ctaLabel = tostring(p.ctaLabel or "Start free")
local ctaUrl = tostring(p.ctaUrl or "moonsplice.video/start")
local brand = type(p.brandColor) == "table" and p.brandColor or { primary = "#7c3aed", bg = "#0f0f12" }
local brandPrimary = brand.primary or "#7c3aed"
local brandBg = brand.bg or "#0f0f12"
local logoEase = parse_ease(p.logoEasing)
local montageLabels = type(p.montageCuts) == "table" and p.montageCuts or { "Timeline", "Transcript", "Preview" }
local captionMode = tostring(p.captionMode or "phrase")
local captionWindow = tonumber(p.captionWindow) or 8
local captionWrap = tonumber(p.captionWrap) or 920
local captionTail = tonumber(p.captionTail) or 0.35

local duration = tonumber(doc.duration) or 28
local vo_end = tonumber(doc.voEnd) or 0
if vo_end <= 0 then
  for _, w in ipairs(doc.words or {}) do
    if w.t1 > vo_end then vo_end = w.t1 end
  end
end

local vo_cues = captions.from_lines(doc.lines or {}, {
  mode = captionMode,
  window = captionWindow,
})
if #vo_cues == 0 then
  vo_cues = captions.from_words(doc.words or {}, {
    mode = captionMode,
    window = captionWindow,
  })
end
vo_cues = captions.apply_tail(vo_cues, vo_end, captionTail)

local t_logo = kf_t("kf-logo-hit", word_start("Moonsplice", 0.78))
local t_scripts = word_start("scripts", scene_at("sc-ui", 3.6))
local t_fastest = kf_t("kf-fastest", word_start("fastest", 1.86))
local t_video = kf_t("kf-video", word_end("video", 4.36))
local t_ship = kf_t("kf-ship", word_start("ship", 6.32))
local sc_open_at = scene_at("sc-open", 0)
-- Shrink the cold-open so scale tweens finish before the aligned "Moonsplice" hit.
local openDur = math.min(logoDuration, math.max(0.18, t_logo - sc_open_at - 0.04))
local sc_montage_at, sc_montage_dur = scene_at("sc-montage", vo_end + 0.4)
local sc_cta_at = scene_at("sc-cta", sc_montage_at + sc_montage_dur + 0.3)
local montage_flash_at = sc_montage_at + sc_montage_dur * 0.55

return e.comp {
  width = 1280,
  height = 720,
  duration = duration,
  fps = doc.fps or 30,
  background = brandBg,

  scene = function(s)
    if doc.voPath and vo_end > 0 then
      s:audio {
        src = doc.voPath,
        at = 0,
        duration = vo_end,
        volume = 1,
      }
    end

    -- Layer 0: vignette + brand plate
    local vignette = s:rect {
      x = 640, y = 360, w = 1600, h = 1600, color = "#000000",
      anchor = "center", opacity = 0.5,
    }

    -- sc-open: logo cold open (synced to kf-logo-hit / "Moonsplice")
    local openGroup = s:group { x = 0, y = 0, opacity = 1 }
    local logo = s:text {
      parent = openGroup,
      x = 640, y = 420, text = "Moonsplice", size = 112, color = brandPrimary,
      anchor = "center", opacity = 0, scale = logoScale * 0.82,
    }
    local tagline = s:text {
      parent = openGroup,
      x = 640, y = 500, text = "Meet Moonsplice", size = 32, color = "#e8edf7",
      anchor = "center", opacity = 0,
    }

    -- VO captions — phrase/line/rolling modes via captionMode + captionWindow params
    local caption = s:captions {
      x = 640, y = 640, size = 36, color = "#f4f6fb",
      anchor = "center", wrap = captionWrap,
      opacity = 0,
      cues = vo_cues,
    }

    -- sc-ui: editor chrome (scene block + "scripts" word)
    local chrome = s:group { x = 0, y = 0, opacity = 0 }
    local panelL = s:rect {
      parent = chrome, x = 0, y = 0, w = 420, h = 720, color = "#141418", opacity = 0,
    }
    local panelR = s:rect {
      parent = chrome, x = 420, y = 0, w = 860, h = 720, color = "#0a0a0e", opacity = 0,
    }
    local uiLabel = s:text {
      parent = chrome, x = 48, y = 48, text = "Transcript · Scenes · Preview",
      size = 22, color = "#8b97b0", opacity = 0,
    }
    local blurOverlay = s:rect {
      parent = chrome, x = 640, y = 360, w = 1280, h = 720,
      color = "#ffffff08", anchor = "center", opacity = 0,
    }
    local fastestPulse = s:rect {
      parent = chrome, x = 640, y = 360, w = 1280, h = 720,
      color = brandPrimary, anchor = "center", opacity = 0,
    }

    -- sc-montage: beat-synced cards + earth clip
    local montage = s:group { x = 0, y = 0, opacity = 0 }
    s:video {
      parent = montage,
      src = "comps/assets/earth_night.webm",
      x = 640, y = 360, w = 1280, h = 720,
      anchor = "center", from = 0, duration = sc_montage_dur, media_start = 0,
    }
    local cards = {}
    local cardLabels = {}
    for i, label in ipairs(montageLabels) do
      local x = 200 + (i - 1) * 340
      cards[i] = s:rect {
        parent = montage, x = x, y = 560, w = 280, h = 96, rx = 12,
        color = brandPrimary, anchor = "center", opacity = 0,
      }
      cardLabels[i] = s:text {
        parent = montage, x = x, y = 560,
        text = label:sub(1, 1):upper() .. label:sub(2),
        size = 28, color = "#ffffff", anchor = "center", opacity = 0,
      }
    end
    local videoFlash = s:rect {
      parent = montage, x = 640, y = 360, w = 1280, h = 720,
      color = "#ffffff", anchor = "center", opacity = 0,
    }

    -- Brand hold between VO end and CTA
    local hold = s:group { x = 0, y = 0, opacity = 0 }
    s:text {
      parent = hold, x = 640, y = 320, text = "Moonsplice", size = 88,
      color = brandPrimary, anchor = "center",
    }
    s:text {
      parent = hold, x = 640, y = 400, text = "Scripts → polished video",
      size = 28, color = "#8b97b0", anchor = "center",
    }

    -- sc-cta: end card (param chips: ctaLabel, ctaUrl, brandColor)
    local cta = s:group { x = 0, y = 0, opacity = 0 }
    s:rect {
      parent = cta, x = 640, y = 400, w = 300, h = 68, rx = 14,
      color = brandPrimary, anchor = "center",
    }
    s:text {
      parent = cta, x = 640, y = 400, text = ctaLabel, size = 30,
      color = "#ffffff", anchor = "center",
    }
    s:text {
      parent = cta, x = 640, y = 480, text = ctaUrl, size = 22,
      color = "#8b97b0", anchor = "center",
    }

    s:script(function(t)
      -- sc-open @ scene + logo keyframe
      t:at(sc_open_at)
      t:tween(logo, openDur, { opacity = 1, y = 360, scale = logoScale }, logoEase)
      t:parallel(
        function() t:tween(tagline, 0.45, { opacity = 1 }, "sineOut") end,
        function() t:tween(vignette, 0.8, { opacity = 0.35 }, "sineOut") end
      )
      t:at(t_logo)
      t:tween(logo, 0.12, { scale = logoScale * 1.04 }, "sineOut")
      t:tween(logo, 0.18, { scale = logoScale }, "sineIn")
      t:at(math.max(t_scripts - 0.2, t_logo + 0.25))
      t:parallel(
        function() t:tween(logo, 0.3, { opacity = 0, y = 300 }, "sineIn") end,
        function() t:tween(tagline, 0.3, { opacity = 0 }, "sineIn") end
      )

      -- VO captions — fade out after VO with configurable tail (captionTail)
      if #vo_cues > 0 then
        t:at(vo_cues[1].t0)
        t:tween(caption, 0.12, { opacity = 1 }, "sineOut")
      end
      if vo_end > 0 then
        t:at(vo_end)
        t:tween(caption, captionTail, { opacity = 0 }, "sineIn")
      end

      -- sc-ui @ scripts word / scene block
      t:at(t_scripts)
      t:tween(chrome, 0.12, { opacity = 1 }, "linear")
      t:tween(blurOverlay, 0.3, { opacity = math.min(uiBlur / 48, 1) }, "sineOut")
      t:stagger({ panelL, panelR, uiLabel }, 0.3, { opacity = 1 }, { each = uiStagger, ease = "sineOut" })

      -- kf-fastest mid-beat pulse
      t:at(t_fastest)
      t:tween(fastestPulse, 0.08, { opacity = 0.12 }, "sineOut")
      t:tween(fastestPulse, 0.2, { opacity = 0 }, "sineIn")

      t:at(t_video)
      t:tween(chrome, 0.2, { opacity = 0 }, "sineIn")

      -- sc-montage @ scene block (editorial tail — after VO)
      t:at(sc_montage_at)
      t:tween(montage, 0.1, { opacity = 1 }, "linear")
      local beat = 60 / montageBpm
      for i, card in ipairs(cards) do
        local label = cardLabels[i]
        t:at(sc_montage_at + (i - 1) * beat)
        t:parallel(
          function() t:tween(card, beat * 0.5, { opacity = 1, y = 520 }, "sineOut") end,
          function() t:tween(label, beat * 0.5, { opacity = 1, y = 520 }, "sineOut") end
        )
        t:parallel(
          function() t:tween(card, beat * 0.35, { opacity = 0.25, y = 560 }, "sineIn") end,
          function() t:tween(label, beat * 0.35, { opacity = 0.25, y = 560 }, "sineIn") end
        )
      end
      t:at(montage_flash_at)
      t:tween(videoFlash, 0.06, { opacity = 0.25 }, "linear")
      t:tween(videoFlash, 0.15, { opacity = 0 }, "sineOut")
      t:at(sc_montage_at + sc_montage_dur)
      t:tween(montage, 0.25, { opacity = 0 }, "sineIn")

      -- Brand hold bridges VO close → montage
      t:at(t_ship + 0.3)
      t:tween(hold, 0.25, { opacity = 1 }, "sineOut")
      t:at(sc_montage_at - 0.1)
      t:tween(hold, 0.15, { opacity = 0 }, "sineIn")

      -- sc-cta @ scene block
      t:at(sc_cta_at)
      t:tween(cta, 0.4, { opacity = 1 }, "sineOut")
      t:at(duration)
    end)
  end,
}
