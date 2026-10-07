-- Tier-1 static analyzer: rules over the compiled timeline + scene graph.
-- Pure Lua, no rendering — frame-grid evaluation of the timeline (the same
-- pure seek the renderer uses) plus segment metadata. See .robot/docs/checks.robot.
--
-- lint.run(comp, opts) -> findings[]
--   opts.measure_text = function(text, size, font) -> w, h   (host-provided)
--   opts.brand = { palette = {"#hex", ...}, fonts = true }   (optional)
--   opts.fps = sampling rate (default 30)
--
-- finding = { code, severity ("error"|"warn"|"info"), node, t0, t1,
--             measured, threshold, detail, suggestion? }

local color = require("moonsplice.color")
local Clip = require("moonsplice.clip")

local L = {}

local TH = {
  motion_density = 3.0,
  competing_amp = 0.4,
  ease_repeat = 2,
  overshoot_budget = 0.20,
  stagger_span = 0.5,
  flash_rate = 3,
  wall_span = 4.0,
  frozen_span = 2.0,
  frozen_error = 3.0,
  text_min = 30,
  safe_x = 80,
  safe_y = 100,
  contrast_normal = 4.5,
  contrast_large = 3.0,
  large_size = 48,
  palette_max = 8,
  brand_de = 0.12,
  duck_vol = 0.30,
  gap_span = 2.0,
  subpixel = 1.0,
}

local AUDIO_KINDS = { audio = true, tts = true, sfx = true, music = true }
-- Kinds whose *content* moves without any property changing. The sampler reads node
-- properties, so a video playing real footage is indistinguishable from a still image
-- to it, and a comp that is nothing but a playing clip was reported "visible but static".
local MOVING_CONTENT = { video = true, lottie = true, spritesheet = true, rive = true,
  particles = true, world = true, html = true, page = true }

local BOXED = { rect = true, html = true, page = true, image = true, svg = true, vector = true, lottie = true, video = true, spritesheet = true, displace = true, fx = true, surface = true, world = true }

local function rel_lum(c)
  local function lin(v) if v <= 0.03928 then return v / 12.92 end return ((v + 0.055) / 1.055) ^ 2.4 end
  return 0.2126 * lin(c[1]) + 0.7152 * lin(c[2]) + 0.0722 * lin(c[3])
end

local function contrast_ratio(a, b)
  local la, lb = rel_lum(a), rel_lum(b)
  if la < lb then la, lb = lb, la end
  return (la + 0.05) / (lb + 0.05)
end

local function oklab_dist(a, b)
  -- coarse perceptual distance via rgb -> approx: reuse color.lerp space by
  -- comparing midpoints; cheap proxy: euclidean in linearized rgb
  local d = 0
  for i = 1, 3 do d = d + (a[i] - b[i]) ^ 2 end
  return math.sqrt(d)
end

-- expect values: a color compares as a color whatever form it is written in ("#f2a541", "f2a541",
-- {0.95, 0.65, 0.25, 1}, {242, 165, 65, 255}, {r=, g=, b=, a=}), to within one step of 8-bit; a
-- number to within float noise. Anything else compares as written.
local function as_rgba(v)
  if type(v) == "string" then
    local s = v:gsub("^#", "")
    if (#s == 3 or #s == 4 or #s == 6 or #s == 8) and s:match("^%x+$") then return color.parse(s) end
    return nil
  end
  if type(v) ~= "table" then return nil end
  local c = { v[1] or v.r, v[2] or v.g, v[3] or v.b, v[4] or v.a or 1 }
  for i = 1, 4 do if type(c[i]) ~= "number" then return nil end end
  if c[1] > 1 or c[2] > 1 or c[3] > 1 or c[4] > 1 then
    for i = 1, 4 do c[i] = c[i] / 255 end
  end
  return c
end
local function same(a, b)
  if type(a) == "number" and type(b) == "number" then return math.abs(a - b) <= 1e-6 * math.max(1, math.abs(b)) end
  if type(a) == "table" or type(b) == "table" then
    local ca, cb = as_rgba(a), as_rgba(b)
    if not (ca and cb) then return false end
    for i = 1, 4 do if math.abs(ca[i] - cb[i]) > 1.01 / 255 then return false end end
    return true
  end
  if type(a) == "string" and type(b) == "string" and as_rgba(a) and as_rgba(b) and a:match("^#") then
    return same(as_rgba(a), b)
  end
  return a == b
end
local shown
function shown(v)
  local c = type(v) == "table" and as_rgba(v)
  if c then
    local h = ("#%02x%02x%02x"):format(math.floor(c[1] * 255 + 0.5), math.floor(c[2] * 255 + 0.5), math.floor(c[3] * 255 + 0.5))
    return c[4] < 1 and h .. ("%02x"):format(math.floor(c[4] * 255 + 0.5)) or h
  end
  if type(v) == "number" then return ("%.4g"):format(v) end
  if type(v) == "table" then
    local parts = {}
    for i, x in ipairs(v) do parts[i] = shown(x) end
    return "[" .. table.concat(parts, ", ") .. "]"
  end
  return tostring(v)
end
L.expect_same, L.expect_shown = same, shown

local function allowed(node, code, comp)
  local la = node and node.initial and node.initial.lint_allow
  if la then for _, c in ipairs(la) do if c == code then return true end end end
  if comp.lint_allow then
    for _, c in ipairs(comp.lint_allow) do if c == code then return true end end
  end
  return false
end


-- what the parts share (they load after this table is registered as moonsplice.lint)
L._ = {
  color = color, Clip = Clip, TH = TH, AUDIO_KINDS = AUDIO_KINDS,
  MOVING_CONTENT = MOVING_CONTENT, BOXED = BOXED, rel_lum = rel_lum, contrast_ratio = contrast_ratio,
  oklab_dist = oklab_dist, as_rgba = as_rgba, same = same, shown = shown,
  allowed = allowed,
}
package.loaded["moonsplice.lint"] = L
local parts = {}
for _, p in ipairs({ "sample", "motion", "frame", "audio", "world", "expect" }) do
  parts[p] = require("moonsplice.lint." .. p)
end

function L.run(comp, opts)
  opts = opts or {}
  local fps = opts.fps or 30
  local dur = comp.duration
  local n_samples = math.floor(dur * fps) + 1
  local findings = {}
  -- comp.lint_allow / node.lint_allow already silence a rule. What was missing is that
  -- they silenced it *invisibly*: count what they take out and report it, so an allow is
  -- a decision on the record rather than a way to make a rule disappear.
  local suppressed = {}

  local function add(code, sev, node, t0, t1, measured, threshold, detail, suggestion)
    if allowed(node, code, comp) then
      suppressed[code] = (suppressed[code] or 0) + 1
      return
    end
    findings[#findings + 1] = { code = code, severity = sev,
      node = node and node.id or nil, t0 = t0, t1 = t1,
      measured = measured, threshold = threshold, detail = detail,
      suggestion = suggestion }
  end

  -- classify nodes
  local visual, audio = {}, {}
  for _, n in ipairs(comp.nodes) do
    if AUDIO_KINDS[n.kind] then audio[#audio + 1] = n
    elseif n.kind ~= "flex" and n.kind ~= "kinetic" and n.kind ~= "draw"
      and n.kind ~= "marker" then
      -- A marker is neither: it is a note about a moment, not a thing in the picture or the
      -- mix. Counting it as a visual would have every rule about what is on screen say
      -- something about a thing that is never on screen.
      visual[#visual + 1] = n
    end
    -- anchor has one value; anything else is silently top-left, which reads as a layout bug
    local an = n.initial.anchor
    if an ~= nil and an ~= "center" and an ~= "topleft" then
      add("unknown_anchor", "warn", n, 0, dur, nil, nil,
        "anchor = \"" .. tostring(an) .. "\" is not an anchor; the node is placed top-left",
        "use anchor = \"center\" or \"topleft\", or offset x/y yourself for right or bottom alignment")
    end
    -- GLSL escape hatches: the pass is opaque to lint, like s:draw
    if n.kind == "fx" then
      for _, name in ipairs(n.initial.chain or {}) do
        if name == "worley" or name == "shadertoy" then
          add("fx_opaque", "info", n, 0, dur, nil, nil,
            "fx pass '" .. name .. "' is GLSL: lint cannot see what it does to the picture",
            "keep the beat readable without it, or express the look as bloom/glow/vignette/chroma/grain")
        end
      end
    end
  end

  -- text measurement cache
  local tdims = {}
  if opts.measure_text then
    for _, n in ipairs(visual) do
      if n.kind == "text" then
        local w, h = opts.measure_text(n.initial.text or "", n.initial.size or 32, n.initial.font)
        tdims[n] = { w = w, h = h, size0 = n.initial.size or 32 }
      end
    end
  end
  -- each part reads what it needs from ctx; sample adds the frame grid the later rules read
  local ctx = { comp = comp, opts = opts, fps = fps, dur = dur, n_samples = n_samples, add = add, visual = visual,
    audio = audio, tdims = tdims }
  parts.sample(ctx)
  parts.motion(ctx)
  parts.frame(ctx)
  parts.audio(ctx)

  -- ============ composition (core/moonsplice/cliplint.lua): clips, tracks, transitions ============
  require("moonsplice.cliplint").run(comp, add, ctx.ever_live, dur)

  parts.world(ctx)
  parts.expect(ctx)

  -- one line per acknowledged rule, so a reader sees what was set aside and how much
  for code, n in pairs(suppressed) do
    findings[#findings + 1] = { code = "suppressed", severity = "info", node = nil,
      t0 = 0, t1 = dur, measured = n, threshold = nil,
      detail = n .. " x " .. code .. " allowed by this comp",
      suggestion = "remove it from lint_allow to see them again" }
  end
  table.sort(findings, function(a, b)
    local sev = { error = 1, warn = 2, info = 3 }
    if sev[a.severity] ~= sev[b.severity] then return sev[a.severity] < sev[b.severity] end
    return (a.t0 or 0) < (b.t0 or 0)
  end)
  return findings
end

return L
