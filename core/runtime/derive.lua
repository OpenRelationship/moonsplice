-- Derive: media and facts made from a source in the resolve phase, cached by content hash.
-- .robot/docs/capcut-parity.robot's pattern: a node asks, resolve derives, the comp reads. Render never
-- runs any of this; it sees an ordinary file and a table of numbers.
--
--   s:video { src = "boat.mp4", derive = { stabilize = true, slowmo = 4, cutout = "person" } }
--   local a = s:derive("song.mp3", { beats = true })     -- a.beats = { 0.52, 1.04, ... }
--   local v = s:derive("boat.mp4", { reframe = "9:16" }) -- v.src = the cropped file
--
-- Video steps run in this order whatever order they are written in, each cached on the one
-- before it: stabilize, deflicker, denoise, slowmo, motion_blur, reframe, cutout.
-- Audio: loudness (target LUFS, two-pass loudnorm), denoise; facts: beats, words, silence.
--
-- VideoToolbox does slowmo and motion blur where it exists (tools/apple, macOS 15.4+); ffmpeg's
-- minterpolate and tblend are the fallback. Every result names its producer in `src`.
local D = {}

local function sh(cmd)
  local p = assert(_MOONSPLICE_POPEN(cmd .. " 2>&1", "r"))
  local out = p:read("*a")
  local ok = p:close()
  return ok, out
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function sha1(s)
  return love.data.encode("string", "hex", love.data.hash("sha1", s))
end

local function exists(path)
  local f = _MOONSPLICE_IOOPEN(path, "r")
  if f then f:close() return true end
  return false
end

local function slurp(path)
  local f = _MOONSPLICE_IOOPEN(path, "rb")
  if not f then return nil end
  local s = f:read("*a"); f:close()
  return s
end

local function root()
  return os.getenv("MOONSPLICE_ROOT")
    or (love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", ""))
    or "."
end

local function cache(sub)
  local base = os.getenv("MOONSPLICE_CACHE") or ((os.getenv("HOME") or "/tmp") .. "/.cache/moonsplice")
  local dir = base .. "/derived/" .. sub
  assert(sh("mkdir -p " .. q(dir)))
  return dir
end

-- What a file is, for a cache key: its path, size and modification time.
local function identity(file)
  local _, out = sh("stat -f '%z %m' " .. q(file) .. " 2>/dev/null || stat -c '%s %Y' " .. q(file))
  return file .. "|" .. (out:match("%d+ %d+") or "?")
end

-- A stable text for an op's argument, for cache keys: keys sorted, numbers in %.17g.
local function ser(v)
  if type(v) == "table" then
    local keys = {}
    for k in pairs(v) do keys[#keys + 1] = tostring(k) end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do parts[#parts + 1] = k .. "=" .. ser(v[k] ~= nil and v[k] or v[tonumber(k)]) end
    return "{" .. table.concat(parts, ",") .. "}"
  elseif type(v) == "number" then
    return ("%.17g"):format(v)
  end
  return tostring(v)
end

local function run(cmd, what)
  local ok, out = sh(cmd)
  if not ok then error("moonsplice derive: " .. what .. " failed:\n" .. out, 0) end
  return out
end

local function apple()
  local bin = root() .. "/native/target/release/moonsplice-apple"
  if exists(bin) and not os.getenv("MOONSPLICE_NO_VT") then return bin end
end

local function probe(file)
  local out = run(("ffprobe -v error -select_streams v:0 -show_entries stream=width,height,r_frame_rate"
    .. " -show_entries format=duration -of default=nw=1 %s"):format(q(file)), "ffprobe")
  local n, d = out:match("r_frame_rate=(%d+)/(%d+)")
  return {
    w = tonumber(out:match("width=(%d+)")), h = tonumber(out:match("height=(%d+)")),
    fps = n and tonumber(n) / tonumber(d) or 30,
    duration = tonumber(out:match("duration=([%d%.]+)")) or 0,
  }
end

-- Intermediate video: near-lossless, CPU-encoded so a cached step is the same on every run.
local MEZZ = "-an -c:v libx264 -preset fast -crf 12 -pix_fmt yuv420p"

local function ffstep(file, out, vf, what)
  run(("ffmpeg -hide_banner -loglevel error -y -i %s -vf %s %s %s"):format(q(file), q(vf), MEZZ, q(out)), what)
end

-- A crop path that follows what Vision finds salient, smoothed so the frame glides rather than
-- twitches: centred moving average over `window` seconds, then a speed limit.
local function reframe_path(file, info, aspect, follow, out_cmds)
  local bin = apple()
  if not bin then error("moonsplice derive: reframe needs tools/apple (macOS)", 0) end
  local facts = out_cmds .. ".json"
  run(("%s %s %s %s --fps 6"):format(q(bin), follow == "faces" and "faces" or "saliency", q(file), q(facts)), "saliency")
  local doc = require("moonsplice.json").decode(slurp(facts))
  local num, den = aspect:match("^(%d+):(%d+)$")
  assert(num, "moonsplice derive: reframe takes \"W:H\", e.g. \"9:16\"")
  local want = tonumber(num) / tonumber(den)
  local cw, ch = info.w, info.h
  if info.w / info.h > want then cw = math.floor(info.h * want / 2) * 2 else ch = math.floor(info.w / want / 2) * 2 end
  -- centre of attention per sample, in 0..1; held through gaps
  local xs, ts, last = {}, {}, { 0.5, 0.5 }
  for _, f in ipairs(doc.frames or {}) do
    local sx, sy, sw = 0, 0, 0
    for _, v in ipairs(f.v or {}) do
      local b, c = v.box, (v.confidence or 1) * v.box[3] * v.box[4] + 1e-6
      sx, sy, sw = sx + (b[1] + b[3] / 2) * c, sy + (b[2] + b[4] / 2) * c, sw + c
    end
    if sw > 0 then last = { sx / sw, sy / sw } end
    xs[#xs + 1], ts[#ts + 1] = last, f.t
  end
  local window, cmds, prev = 1.2, {}, nil
  for i, t in ipairs(ts) do
    local ax, ay, k = 0, 0, 0
    for j = 1, #ts do
      if math.abs(ts[j] - t) <= window / 2 then ax, ay, k = ax + xs[j][1], ay + xs[j][2], k + 1 end
    end
    local cx, cy = ax / k * info.w, ay / k * info.h
    if prev then -- at most a fifth of the frame a second
      local lim = 0.2 * info.w * (t - prev.t)
      cx = math.max(prev.x - lim, math.min(prev.x + lim, cx))
      cy = math.max(prev.y - lim, math.min(prev.y + lim, cy))
    end
    prev = { t = t, x = cx, y = cy }
    local x = math.floor(math.max(0, math.min(info.w - cw, cx - cw / 2)))
    local y = math.floor(math.max(0, math.min(info.h - ch, cy - ch / 2)))
    cmds[#cmds + 1] = ("%.3f crop x %d, crop y %d;"):format(t, x, y)
  end
  local f = assert(_MOONSPLICE_IOOPEN(out_cmds, "wb"))
  f:write(table.concat(cmds, "\n"), "\n"); f:close()
  return cw, ch, doc
end

local VIDEO_ORDER = { "stabilize", "deflicker", "denoise", "slowmo", "motion_blur", "reframe", "cutout" }

--- Apply `ops` to a video file; returns the final file and what was learnt on the way.
function D.video(file, ops)
  local cur, key, facts = file, identity(file), { src = file, steps = {} }
  for _, op in ipairs(VIDEO_ORDER) do
    local arg = ops[op]
    if arg ~= nil and arg ~= false then
      key = sha1(key .. "|" .. op .. "=" .. ser(arg))
      local dir = cache("video")
      local ext = op == "cutout" and ".mov" or (op == "slowmo" or op == "motion_blur") and ".mov" or ".mp4"
      local out = dir .. "/" .. key .. ext
      local producer
      if op == "stabilize" then
        producer = "ffmpeg/deshake"
        if not exists(out) then ffstep(cur, out, "deshake=rx=32:ry=32,crop=iw-32:ih-32,scale=iw+32:ih+32", "stabilize") end
      elseif op == "deflicker" then
        producer = "ffmpeg/deflicker"
        if not exists(out) then ffstep(cur, out, "deflicker=size=7:mode=pm", "deflicker") end
      elseif op == "denoise" then
        producer = "ffmpeg/hqdn3d"
        local s = type(arg) == "number" and arg or 4
        if not exists(out) then ffstep(cur, out, ("hqdn3d=%g:%g:%g:%g"):format(s, s * 0.75, s * 1.5, s * 1.1), "denoise") end
      elseif op == "slowmo" then
        local factor = math.floor(tonumber(arg) or 2)
        local bin = apple()
        producer = bin and "apple/videotoolbox/frame-rate-conversion" or "ffmpeg/minterpolate"
        if not exists(out) then
          if bin then
            run(("%s slowmo %s %s --factor %d"):format(q(bin), q(cur), q(out), factor), "slowmo")
          else
            local fps = probe(cur).fps
            run(("ffmpeg -hide_banner -loglevel error -y -i %s -vf %s -r %s %s %s"):format(q(cur),
              q(("minterpolate=fps=%g:mi_mode=mci:mc_mode=aobmc:vsbmc=1,setpts=%d*PTS"):format(fps * factor, factor)),
              tostring(fps), MEZZ, q(out)), "slowmo")
          end
        end
        facts.slowmo = factor
      elseif op == "motion_blur" then
        local strength = math.floor(tonumber(arg) or 50)
        local bin = apple()
        producer = bin and "apple/videotoolbox/motion-blur" or "ffmpeg/tmix"
        if not exists(out) then
          if bin then
            run(("%s motionblur %s %s --strength %d"):format(q(bin), q(cur), q(out), strength), "motion blur")
          else
            ffstep(cur, out, "tmix=frames=3:weights='1 2 1'", "motion blur")
          end
        end
      elseif op == "reframe" then
        local aspect = type(arg) == "table" and arg.aspect or arg
        local follow = type(arg) == "table" and arg.follow or "saliency"
        producer = "apple/vision/" .. follow
        local cmds = dir .. "/" .. key .. ".crop"
        local info = probe(cur)
        if not exists(out) or not exists(cmds) then
          local cw, ch = reframe_path(cur, info, aspect, follow, cmds)
          ffstep(cur, out, ("sendcmd=f=%s,crop=%d:%d:0:0"):format(cmds, cw, ch), "reframe")
        end
        facts.reframe = { aspect = aspect, follow = follow, path = cmds }
      elseif op == "cutout" then
        local kind = arg == true and "person" or arg
        local bin = apple()
        if not bin then error("moonsplice derive: cutout needs tools/apple (macOS)", 0) end
        producer = "apple/vision/" .. (kind == "person" and "person-segmentation" or "foreground-instance-mask")
        if not exists(out) then
          local masks = dir .. "/" .. key .. ".masks"
          run(("rm -rf %s && %s segment %s %s --kind %s --fps 0"):format(q(masks), q(bin), q(cur), q(masks), q(kind)), "cutout")
          local fps = probe(cur).fps
          run(("ffmpeg -hide_banner -loglevel error -y -i %s -framerate %s -i %s/%%05d.png -filter_complex %s"
            .. " -map '[v]' -an -c:v prores_ks -profile:v 4444 -pix_fmt yuva444p10le %s"):format(q(cur), tostring(fps), q(masks),
            q("[1:v][0:v]scale2ref[m][c];[m]format=gray[g];[c][g]alphamerge[v]"), q(out)), "cutout")
        end
        facts.cutout = kind
      end
      cur = out
      facts.steps[#facts.steps + 1] = { op = op, src = producer, file = out }
    end
  end
  facts.file = cur
  return cur, facts
end

local AUDIO_FACTS = { beats = true, words = true, silence = true }

--- Apply `ops` to an audio (or video) file: a processed file, and facts.
function D.audio(file, ops)
  local cur, key, facts = file, identity(file), { src = file, steps = {} }
  if ops.denoise then
    key = sha1(key .. "|denoise=" .. tostring(ops.denoise))
    local out = cache("audio") .. "/" .. key .. ".wav"
    if not exists(out) then
      local nf = type(ops.denoise) == "number" and ops.denoise or -25
      run(("ffmpeg -hide_banner -loglevel error -y -i %s -vn -af %s %s"):format(q(cur), q(("afftdn=nf=%g"):format(nf)), q(out)), "denoise")
    end
    cur = out
    facts.steps[#facts.steps + 1] = { op = "denoise", src = "ffmpeg/afftdn", file = out }
  end
  if ops.loudness then
    local target = tonumber(ops.loudness) or -14
    key = sha1(key .. "|loudness=" .. target)
    local out = cache("audio") .. "/" .. key .. ".wav"
    if not exists(out) then
      local first = run(("ffmpeg -hide_banner -nostats -i %s -vn -af loudnorm=I=%g:TP=-1.5:LRA=11:print_format=json -f null -")
        :format(q(cur), target), "loudness measure")
      local block
      for b in first:gmatch("%b{}") do if b:match('"input_i"') then block = b end end
      if not block then error("moonsplice derive: loudnorm printed no measurement:\n" .. first, 0) end
      local m = require("moonsplice.json").decode(block)
      run(("ffmpeg -hide_banner -loglevel error -y -i %s -vn -af %s -ar 48000 %s"):format(q(cur),
        q(("loudnorm=I=%g:TP=-1.5:LRA=11:measured_I=%s:measured_TP=%s:measured_LRA=%s:measured_thresh=%s:offset=%s:linear=true")
          :format(target, m.input_i, m.input_tp, m.input_lra, m.input_thresh, m.target_offset)), q(out)), "loudness")
    end
    cur = out
    facts.loudness = target
    facts.steps[#facts.steps + 1] = { op = "loudness", src = "ffmpeg/loudnorm-2pass", file = out }
  end
  local want = {}
  for k in pairs(AUDIO_FACTS) do if ops[k] then want[#want + 1] = k end end
  table.sort(want)
  if #want > 0 then
    -- facts are measured on the source, not the processed file: a beat is where the music has it
    local fkey = sha1(identity(file) .. "|facts=" .. table.concat(want, ","))
    local out = cache("facts") .. "/" .. fkey .. ".json"
    if not exists(out) then
      local py = root() .. "/vision/.venv/bin/python"
      run(("cd %s && PYTHONPATH=vision %s -m moonsplice_vision.derive %s %s %s")
        :format(q(root()), q(py), q(file), q(out), table.concat(want, " ")), "audio facts")
    end
    local doc = require("moonsplice.json").decode(slurp(out))
    if doc.beats then
      facts.beats, facts.onsets, facts.tempo = doc.beats.beats, doc.beats.onsets, doc.beats.tempo
    end
    if doc.words then facts.words, facts.speech = doc.words.words, doc.words.spans end
    if doc.silence then facts.silent = doc.silence.silent end
    facts.facts_src = doc
  end
  facts.file = cur
  return cur, facts
end

local VIDEO_EXT = { mp4 = 1, mov = 1, webm = 1, mkv = 1, m4v = 1, avi = 1 }

--- The comp-facing entry (`s:derive`): video ops make a video, audio ops an audio file; the
--- facts come back with `src` set to whichever file the ops produced.
function D.derive(file, ops)
  local any_video = false
  for _, op in ipairs(VIDEO_ORDER) do if ops[op] then any_video = true end end
  local ext = (file:match("%.(%w+)$") or ""):lower()
  if any_video or (VIDEO_EXT[ext] and not (ops.beats or ops.words or ops.silence or ops.loudness)) then
    local out, facts = D.video(file, ops)
    if ops.beats or ops.words or ops.silence then
      local _, af = D.audio(file, { beats = ops.beats, words = ops.words, silence = ops.silence })
      for k, v in pairs(af) do if facts[k] == nil then facts[k] = v end end
    end
    facts.src = out
    return facts
  end
  local out, facts = D.audio(file, ops)
  facts.src = out
  return facts
end

return D
