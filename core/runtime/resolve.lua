-- Resolve phase (host code, runs AFTER comp load, BEFORE render).
-- Network/disk allowed here — render itself stays I/O-free per canon.
-- v0 video path: extract frames at comp fps, cover-cropped to node w×h, into a
-- content-addressed cache. Long-term this is replaced by the moonsplice-decode sidecar.
local R = {}

local function sh(cmd)
  local p = assert(_MOONSPLICE_POPEN(cmd .. " 2>&1", "r"))
  local out = p:read("*a")
  local ok = p:close()
  return ok, out
end

local function sha1(s)
  return love.data.encode("string", "hex", love.data.hash("sha1", s))
end

local function cache_root()
  local custom = os.getenv("MOONSPLICE_CACHE")
  if custom then return custom end
  return (os.getenv("HOME") or "/tmp") .. "/.cache/moonsplice"
end

local function exists(path)
  local f = _MOONSPLICE_IOOPEN(path, "r")
  if f then f:close() return true end
  return false
end

local MEDIA_EXT = { mp4=1, mov=1, webm=1, mkv=1, m4v=1, avi=1, ogv=1, mp3=1, wav=1, m4a=1,
                    png=1, jpg=1, jpeg=1, webp=1, gif=1 }

local function localize(src)
  -- A page URL (YouTube, TikTok, Vimeo, ...) is not a file: bin/moonsplice-fetch downloads it with
  -- yt-dlp into the shared media store (vision/moonsplice_vision/fetch.py) and keeps it.
  local ext = src:match("^https?://[^?#]*%.(%w+)[?#]?")
  if src:match("^https?://") and not (ext and MEDIA_EXT[ext:lower()]) then
    local root = os.getenv("MOONSPLICE_ROOT")
      or (love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", ""))
      or "."
    local ok, out = sh(("'%s/bin/moonsplice-fetch' '%s'"):format(root, src:gsub("'", "'\\''")))
    local path = out:match('"path": "([^"]+)"')
    if not ok or not path then error("moonsplice resolve: fetch failed: " .. src .. "\n" .. out) end
    return path
  end
  if src:match("^https?://") then
    local dst = cache_root() .. "/dl/" .. sha1(src) .. ".bin"
    if not exists(dst) then
      assert(sh(("mkdir -p '%s/dl'"):format(cache_root())))
      local ok, out = sh(("curl -fsSL -o '%s' '%s'"):format(dst, src))
      if not ok then error("moonsplice resolve: download failed: " .. src .. "\n" .. out) end
    end
    return dst
  end
  if not src:match("^/") then
    return (os.getenv("MOONSPLICE_CWD") or ".") .. "/" .. src
  end
  return src
end

-- Layout pass: runs as compile's post_scene hook (before scripts record), so
-- tweens resolve from solved positions.
R.localize = localize

function R.layout(nodes)
  local layout = require("layout")
  for _, n in ipairs(nodes) do
    if n.kind == "kinetic" then
      -- measure per-char widths with the real font, center the run on i.x
      local i = n.initial
      local scene = require("scene")
      local font = (not scene.enabled) and require("painter").font(i.size, i.font) or nil
      local fid = scene.enabled and scene.font_id(i.font) or nil
      local widths, total = {}, 0
      for ch in i.text:gmatch(".") do
        local w = font and font:getWidth(ch) or scene.measure(fid, i.size, ch)
        widths[#widths + 1] = { ch = ch, w = w }
        total = total + w + i.spacing
      end
      total = total - i.spacing
      local cursor = i.x - total / 2
      local ci = 0
      for _, e in ipairs(widths) do
        if e.ch ~= " " then
          ci = ci + 1
          local node = n.chars[ci]
          node.initial.x = cursor + e.w / 2
          node.initial.y = i.y
        end
        cursor = cursor + e.w + i.spacing
      end
    elseif n.kind == "flex" then
      if not layout.available then error("moonsplice resolve: layout dylib missing (build layout/)") end
      local i = n.initial
      local items = {}
      for k, child in ipairs(i.items) do
        items[k] = { w = child.initial.w or (child.initial.r and child.initial.r * 2),
                     h = child.initial.h or (child.initial.r and child.initial.r * 2),
                     grow = child.initial.grow, margin = child.initial.margin }
      end
      local solved = layout.solve(i, items)
      for k, child in ipairs(i.items) do
        local sl = solved[k]
        local ci = child.initial
        ci.w = ci.w and sl.w or ci.w
        ci.h = ci.h and sl.h or ci.h
        local centered = ci.anchor == "center" or child.kind == "circle"
        local ax = centered and sl.w / 2 or 0
        local ay = centered and sl.h / 2 or 0
        ci.x = i.x + sl.x + ax
        ci.y = i.y + sl.y + ay
      end
    end
  end
end

-- How long a file is, asked once.
--
-- This used to shell out to ffprobe every time it was called, which meant once per sound every
-- time the composition was loaded -- and the desktop app re-loads on every single edit, because
-- there is one representation and it re-reads it. A ten minute edit with seventy sounds in it
-- paid seventy subprocesses, four seconds, for every nudge of a clip. The duration of a file
-- does not change while nobody is writing to it, so it is remembered: in this process for the
-- reloads, and on disk for the next time the project is opened.
--
-- The key is the path and the size. A file replaced between runs by a different file of exactly
-- the same size would be read from the cache and be wrong; that is the trade, it is stated here,
-- and the alternative was four seconds a keystroke.
local probed = {}

local function file_size(path)
  local f = _MOONSPLICE_IOOPEN(path, "rb")
  if not f then return nil end
  local n = f:seek("end")
  f:close()
  return n
end

--- Where the remembered length of a file is kept.
local function probe_slot(file)
  local size = file_size(file)
  if not size then return nil end
  return cache_root() .. "/probe/" .. sha1(file .. "|" .. tostring(size)) .. ".txt"
end

--- What was remembered last time, if anything.
local function probe_recall(file)
  if probed[file] then return probed[file] end
  local slot = probe_slot(file)
  if not slot then return nil end
  local f = _MOONSPLICE_IOOPEN(slot, "r")
  if not f then return nil end
  local d = tonumber(f:read("*a"))
  f:close()
  if d then probed[file] = d end
  return d
end

--- Keep it, here and for next time. Best effort on disk: a cache that cannot be written is a
--- cache that is not used, not a failure, and the composition has its answer either way.
local function probe_keep(file, d)
  probed[file] = d
  local slot = probe_slot(file)
  if not slot then return end
  local f = _MOONSPLICE_IOOPEN(slot, "w")
  if f then
    f:write(tostring(d))
    f:close()
  end
end

--- Ask how long many files are at once.
---
--- ffprobe costs about sixty milliseconds of process start whatever it is asked about, and the
--- answers do not depend on each other. Seventy sounds asked one after another is four seconds of
--- a person looking at a blank window; asked eight at a time it is half a second. Anything that
--- does not answer is left out and falls back to being asked on its own, where it can fail with a
--- sentence about which file it was.
local function probe_many(files)
  if #files == 0 then return end
  local dir = cache_root() .. "/probe"
  sh(("mkdir -p '%s'"):format(dir))
  local list = dir .. "/.asking-" .. sha1(table.concat(files, "\n"))
  local f = _MOONSPLICE_IOOPEN(list, "w")
  if not f then return end
  for _, path in ipairs(files) do f:write(path, "\0") end
  f:close()
  -- Each answer is one short line written by one printf, which is atomic at this length, so the
  -- eight of them interleave safely.
  local runner = dir .. "/ask.sh"
  local rf = _MOONSPLICE_IOOPEN(runner, "w")
  if rf then
    rf:write([==[
#!/bin/sh
# Written by core/runtime/resolve.lua. How long is each of these, eight at a time.
exec xargs -0 -P 8 -n 1 sh -c 'printf "%s\t%s\n" "$0" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$0")"'
]==])
    rf:close()
  end
  local _, out = sh(("sh '%s' < '%s'"):format(runner, list))
  for line in tostring(out):gmatch("[^\n]+") do
    local path, secs = line:match("^(.*)\t([%d%.]+)$")
    local d = secs and tonumber(secs)
    if path and d then probe_keep(path, d) end
  end
  sh(("rm -f '%s'"):format(list))
end

local function ffprobe_duration(file)
  local known = probe_recall(file)
  if known then return known end
  local ok, out = sh(("ffprobe -v error -show_entries format=duration -of csv=p=0 '%s'"):format(file))
  local d = ok and tonumber(out:match("[%d%.]+"))
  if not d then error("moonsplice resolve: cannot probe duration of " .. file) end
  probe_keep(file, d)
  return d
end

local function bake_energy(file, start, dur)
  local rate = 50
  local key = sha1(table.concat({ tostring(file), tostring(start), tostring(dur), tostring(rate) }, "|"))
  local dst = cache_root() .. "/energy/" .. key .. ".f32"
  if not exists(dst) then
    assert(sh(("mkdir -p '%s/energy'"):format(cache_root())))
    local ok, out = sh(("ffmpeg -y -hide_banner -loglevel error -ss %s -t %s -i '%s' -ac 1 -ar %d -f f32le '%s'")
      :format(start or 0, dur, file, rate, dst))
    if not ok then error("moonsplice resolve: energy bake failed\n" .. out) end
  end
  local f = assert(_MOONSPLICE_IOOPEN(dst, "rb"), "moonsplice resolve: energy file missing")
  local raw = f:read("*a")
  f:close()
  local ffi = require("ffi")
  local n = math.floor(#raw / 4)
  local buf = ffi.new("uint8_t[?]", #raw)
  ffi.copy(buf, raw)
  local fl = ffi.cast("float*", buf)
  local samples, peak = {}, 0
  for i = 0, n - 1 do
    local v = math.abs(fl[i])
    samples[i + 1] = v
    if v > peak then peak = v end
  end
  if peak < 1e-6 then peak = 1 end
  for i = 1, #samples do samples[i] = samples[i] / peak end
  return samples
end

local function elevenlabs_key()
  local key = os.getenv("ELEVENLABS_API_KEY")
  if not key or key == "" then
    error("moonsplice resolve: ELEVENLABS_API_KEY not set — export it to use tts{}/sfx{} nodes", 0)
  end
  return key
end

local VOICES = { -- premade voices (free-tier API-safe); any raw voice_id also accepted
  sarah = "EXAVITQu4vr4xnSDxMaL",
  roger = "CwhRBWXzGAHq8TQ4Fs17",
  george = "JBFqnCBsd6RMkjVDRZzb",
  alice = "Xb7hH8MSUJpSbSDYk0k2",
  liam = "TX3LPaxmHKxFdv7VOQHJ",
  laura = "FGY2WhTYpPnrIDTdsKH5",
  rachel = "EXAVITQu4vr4xnSDxMaL", -- alias → Sarah (Rachel is library-gated on free API)
}

-- LuaJIT popen:close() doesn't return exit status — verify the artifact instead:
-- a failed ElevenLabs call writes a JSON error body where audio should be.
local function verify_audio(dst, what, out)
  local f = _MOONSPLICE_IOOPEN(dst, "rb")
  local head = f and f:read(2)
  if f then f:close() end
  if not head or head == "{" or head:sub(1, 1) == "{" then
    local body = ""
    local g = _MOONSPLICE_IOOPEN(dst, "rb")
    if g then body = g:read("*a") or ""; g:close() end
    os.remove(dst)
    error(("moonsplice resolve: %s failed: %s%s"):format(what, body ~= "" and body or "(no output)",
      out and ("\n" .. out) or ""), 0)
  end
end

-- Draft tiering: MOONSPLICE_DRAFT=1 swaps un-pinned models to Flash (fast/cheap
-- iteration); finals re-render without the flag. Cache keys include the model,
-- so draft and final audio never collide.
local function tts_model(i)
  if i.model then return i.model end
  if os.getenv("MOONSPLICE_DRAFT") == "1" then return "eleven_flash_v2_5" end
  return "eleven_multilingual_v2"
end

-- Build the TTS request body. Beyond text/model:
--   seed          — deterministic generation (same seed+text+voice → same audio)
--   speed         — voice_settings.speed (0.7–1.2): fit narration to a scene
--   stability/style — passthrough voice_settings
--   previous_text/next_text — request stitching: consecutive lines generated as
--     one continuous read instead of N cold opens (auto-filled from after/at_word)
--   dictionaries  — pronunciation_dictionary_locators = {{id=,version_id=},...}
local function tts_body(i, model)
  local parts = { string.format('"text":%q,"model_id":%q', i.text, model) }
  if i.seed then parts[#parts + 1] = ('"seed":%d'):format(i.seed) end
  if i.previous_text then parts[#parts + 1] = string.format('"previous_text":%q', i.previous_text) end
  if i.next_text then parts[#parts + 1] = string.format('"next_text":%q', i.next_text) end
  if i.speed or i.stability or i.style then
    local vs = {}
    if i.speed then vs[#vs + 1] = ('"speed":%s'):format(i.speed) end
    if i.stability then vs[#vs + 1] = ('"stability":%s'):format(i.stability) end
    if i.style then vs[#vs + 1] = ('"style":%s'):format(i.style) end
    parts[#parts + 1] = '"voice_settings":{' .. table.concat(vs, ",") .. '}'
  end
  if i.dictionaries then
    local ds = {}
    for _, d in ipairs(i.dictionaries) do
      ds[#ds + 1] = string.format('{"pronunciation_dictionary_id":%q,"version_id":%q}',
        d.id or d[1], d.version_id or d[2])
    end
    parts[#parts + 1] = '"pronunciation_dictionary_locators":[' .. table.concat(ds, ",") .. ']'
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

local function tts_cache_key(i, voice, model)
  return sha1(table.concat({ i.text, voice, model, i.seed or "", i.speed or "",
    i.stability or "", i.style or "", i.previous_text or "", i.next_text or "",
    i.dictionaries and #i.dictionaries or "" }, "|"))
end

-- Group the with-timestamps character alignment into word timings, in the same
-- shape forced-alignment produces, so downstream code has one format.
local function chars_to_words(al)
  local words, cur, t0, t1 = {}, {}, nil, nil
  local chars = al.characters or {}
  local starts = al.character_start_times_seconds or {}
  local ends = al.character_end_times_seconds or {}
  for k = 1, #chars do
    local ch = chars[k]
    if ch:match("%s") then
      if #cur > 0 then
        words[#words + 1] = { text = table.concat(cur), start = t0, ["end"] = t1 }
        cur, t0 = {}, nil
      end
    else
      cur[#cur + 1] = ch
      t0 = t0 or starts[k]
      t1 = ends[k]
    end
  end
  if #cur > 0 then words[#words + 1] = { text = table.concat(cur), start = t0, ["end"] = t1 } end
  return words
end

-- want_align: generate through /with-timestamps — the response carries the
-- character alignment, so the word times come back WITH the audio and the
-- separate forced-alignment round-trip is skipped entirely.
local function tts_cache_key(i, voice, model)
  return sha1(table.concat({ i.text, voice or "", model or "", i.provider or "", i.seed or "", i.speed or "",
    i.stability or "", i.style or "", i.previous_text or "", i.next_text or "",
    i.dictionaries and #i.dictionaries or "" }, "|"))
end

local function moonsplice_audio_bin()
  local root = (os.getenv("MOONSPLICE_ROOT") or (N and N.root and N.root()))
  if not root then
    root = love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", "")
  end
  root = root or "."
  local p = root .. "/bin/moonsplice-audio"
  if exists(p) then return p end
  return "bin/moonsplice-audio"
end

local function tts_generate(i, want_align)
  local provider = (i.provider or os.getenv("MOONSPLICE_TTS_PROVIDER") or os.getenv("MOONSPLICE_AUDIO_PROVIDER") or ""):lower()
  local voice = VOICES[(i.voice or "sarah"):lower()] or i.voice
  local model = tts_model(i)
  local base = cache_root() .. "/tts/" .. tts_cache_key(i, voice, model)
  local dst = base .. ".mp3"
  local align_dst = base .. ".align.json"

  if not exists(dst) then
    assert(sh(("mkdir -p '%s/tts'"):format(cache_root())))
    
    -- If an open/local/alternative provider is specified (or ElevenLabs key is absent)
    local has_eleven_key = pcall(elevenlabs_key)
    if provider ~= "" or not has_eleven_key then
      local abin = moonsplice_audio_bin()
      -- 2>&1 is load-bearing: without it the helper's stderr goes to the terminal and
      -- `out` is empty, so a failed call reports "TTS failed: (no output)" while the
      -- actual reason (a 400 naming the bad model) is nowhere in the error.
      local cmd = string.format("%s tts --text %q --out %q 2>&1", abin, i.text, dst)
      if provider ~= "" then cmd = cmd .. string.format(" --provider %q", provider) end
      if voice and voice ~= "" then cmd = cmd .. string.format(" --voice %q", voice) end
      if model and model ~= "" then cmd = cmd .. string.format(" --model %q", model) end
      if i.speed then cmd = cmd .. string.format(" --speed %s", i.speed) end
      if want_align then cmd = cmd .. string.format(" --align-out %q", align_dst) end
      local ok, out = sh(cmd)
      if not ok then error("moonsplice resolve: TTS failed:\n" .. out) end
      verify_audio(dst, "TTS", out)
      return dst
    end

    local key = elevenlabs_key()
    local body = tts_body(i, model)
    if want_align then
      local raw = base .. ".wt.json"
      local ok, out = sh(string.format(
        "curl -fsS -X POST 'https://api.elevenlabs.io/v1/text-to-speech/%s/with-timestamps?output_format=mp3_44100_128'" ..
        " -H 'xi-api-key: %s' -H 'content-type: application/json' -d '%s' -o '%s'",
        voice, key, body:gsub("'", "'\\''"), raw))
      if not ok then error("moonsplice resolve: TTS (with-timestamps) failed:\n" .. out) end
      local f = assert(_MOONSPLICE_IOOPEN(raw, "rb")); local resp = f:read("*a"); f:close()
      local doc_ok, doc = pcall(function() return require("moonsplice.json").decode(resp) end)
      if not doc_ok or not doc.audio_base64 then
        os.remove(raw)
        error("moonsplice resolve: TTS with-timestamps returned no audio: " .. resp:sub(1, 200), 0)
      end
      local audio = love.data.decode("string", "base64", doc.audio_base64)
      local a = assert(_MOONSPLICE_IOOPEN(dst, "wb")); a:write(audio); a:close()
      -- persist word times where align_generate() looks for them → no second call
      local words = chars_to_words(doc.normalized_alignment or doc.alignment or {})
      local j = { '{"words":[' }
      for k, w in ipairs(words) do
        j[#j + 1] = string.format('%s{"text":%q,"start":%s,"end":%s}',
          k > 1 and "," or "", w.text, w.start or 0, w["end"] or 0)
      end
      j[#j + 1] = "]}"
      local g = assert(_MOONSPLICE_IOOPEN(align_dst, "wb"))
      g:write(table.concat(j)); g:close()
      os.remove(raw)
    else
      local ok, out = sh(string.format(
        "curl -fsS -X POST 'https://api.elevenlabs.io/v1/text-to-speech/%s?output_format=mp3_44100_128'" ..
        " -H 'xi-api-key: %s' -H 'content-type: application/json' -d '%s' -o '%s'",
        voice, key, body:gsub("'", "'\\''"), dst))
      if not ok then error("moonsplice resolve: TTS failed:\n" .. out) end
    end
    verify_audio(dst, "TTS", nil)
  end
  return dst
end

local function music_generate(i)
  local dst = cache_root() .. "/music/" ..
    sha1(table.concat({ i.prompt, i.gen_duration or 30, i.model or "music_v1" }, "|")) .. ".mp3"
  if not exists(dst) then
    local key = elevenlabs_key()
    assert(sh(("mkdir -p '%s/music'"):format(cache_root())))
    local body = string.format('{"prompt":%q,"music_length_ms":%d}',
      i.prompt, math.floor((i.gen_duration or 30) * 1000))
    local ok, out = sh(string.format(
      "curl -fsS -X POST 'https://api.elevenlabs.io/v1/music?output_format=mp3_44100_128'" ..
      " -H 'xi-api-key: %s' -H 'content-type: application/json' -d '%s' -o '%s'",
      key, body:gsub("'", "'\\''"), dst))
    if not ok then error("moonsplice resolve: music failed:\n" .. out) end
    verify_audio(dst, "music (note: Music API requires a paid ElevenLabs plan)", out)
  end
  return dst
end

-- the sound-generation endpoint rejects anything under 0.5s with a bare 400
local function sfx_generate(i)
  if i.gen_duration and i.gen_duration < 0.5 then
    error(("moonsplice: sfx{gen_duration=%.2f} too short — the API minimum is 0.5s"):format(
      i.gen_duration), 0)
  end
  local dst = cache_root() .. "/sfx/" ..
    sha1(table.concat({ i.prompt, i.gen_duration or "" }, "|")) .. ".mp3"
  if not exists(dst) then
    local key = elevenlabs_key()
    assert(sh(("mkdir -p '%s/sfx'"):format(cache_root())))
    local dur = i.gen_duration and (',"duration_seconds":' .. i.gen_duration) or ""
    local body = string.format('{"text":%q%s}', i.prompt, dur)
    local ok, out = sh(string.format(
      "curl -fsS -X POST 'https://api.elevenlabs.io/v1/sound-generation'" ..
      " -H 'xi-api-key: %s' -H 'content-type: application/json' -d '%s' -o '%s'",
      key, body:gsub("'", "'\\''"), dst))
    if not ok then error("moonsplice resolve: SFX failed:\n" .. out) end
    verify_audio(dst, "SFX", out)
  end
  return dst
end

-- ElevenLabs Forced Alignment: given the clip and its transcript, returns
-- per-word start/end times. Lets scripts pace motion off what the narration is
-- ACTUALLY saying instead of hand-guessed offsets — reflow the copy and every
-- cue that referenced a word moves with it. Cached beside the audio.
local function normword(w) return (w:lower():gsub("[^%w']", "")) end

local function align_generate(afile, text)
  local dst = afile:gsub("%.mp3$", "") .. ".align.json"
  if not exists(dst) then
    local has_eleven_key, key = pcall(elevenlabs_key)
    if has_eleven_key and key and key ~= "" and (not os.getenv("MOONSPLICE_LOCAL_ALIGN")) then
      local ok, out = sh(string.format(
        "curl -fsS -X POST 'https://api.elevenlabs.io/v1/forced-alignment'" ..
        " -H 'xi-api-key: %s' -F 'file=@%s' -F 'text=%s' -o '%s'",
        key, afile, text:gsub("'", "'\\''"), dst))
      if not ok then
        -- Fallback to local CTC aligner
        local abin = moonsplice_audio_bin()
        sh(string.format("%s align --file %q --text %q --out %q", abin, afile, text, dst))
      end
    else
      -- Run local CTC forced alignment directly
      local abin = moonsplice_audio_bin()
      local ok, out = sh(string.format("%s align --file %q --text %q --out %q", abin, afile, text, dst))
      if not ok then error("moonsplice resolve: local alignment failed:\n" .. out) end
    end
  end
  local f = assert(_MOONSPLICE_IOOPEN(dst, "rb"), "moonsplice resolve: alignment unreadable")
  local raw = f:read("*a"); f:close()
  local doc = require("moonsplice.json").decode(raw)
  local words = {}
  for _, w in ipairs(doc.words or {}) do
    local clean = (w.text or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if clean ~= "" then
      words[#words + 1] = { text = clean, t0 = w.start or w.t0, t1 = w["end"] or w.t1 }
    end
  end
  return words, doc.phonemes
end

-- ------------------------------------------------------------------------ offline media

-- Why one thing could not be made ready, in a word.
--
-- A word and not the renderer's sentence, because the sentence names a file and a file name is
-- the one thing this app never shows. The word becomes English in `editor/vocabulary.json`,
-- next to every other word the UI is allowed to say.
local WHY_OFFLINE = {
  { "ELEVENLABS_API_KEY", "needs a key" },
  { "OPENROUTER_API_KEY", "needs a key" },
  { "API_KEY", "needs a key" },
  { "not found", "missing" },
  { "No such file", "missing" },
  { "cannot read", "missing" },
  { "cannot open", "missing" },
  { "unreadable", "missing" },
  { "download failed", "missing" },
  { "fetch failed", "missing" },
  { "cannot probe", "unreadable" },
  { "no frames extracted", "unreadable" },
  { "load failed", "unreadable" },
  { "failed", "unreadable" },
}

function R.why_offline(err)
  local s = tostring(err)
  for _, rule in ipairs(WHY_OFFLINE) do
    if s:find(rule[1], 1, true) then return rule[2] end
  end
  return "would not load"
end

-- One thing that cannot be made ready takes itself off the air; the composition still opens.
--
-- Every editor does this and calls the clip offline, because the alternative is what this used
-- to do: one file moved, and a ten minute edit would not open at all -- no picture, no timeline,
-- and nothing on screen to say which of two hundred things was the problem or that the other
-- hundred and ninety-nine were fine.
--
-- It is off by default and the app turns it on (`MOONSPLICE_OFFLINE_OK`, set by
-- `editor/src-tauri/src/engine.rs`). A render must still refuse: a slate that quietly ships
-- inside an export is a far worse failure than one that stops the export.
local function went_offline(n, err)
  n.offline = R.why_offline(err)
  io.stderr:write(("moonsplice resolve: %s is offline (%s): %s\n"):format(
    tostring(n.id), n.offline, tostring(err):gsub("%s+", " ")))
  -- Whatever it was going to hold, it does not. Everything downstream already checks for nil,
  -- because a node that never named a file has had these nil all along.
  n.dec, n.file, n.afile, n.frames_dir, n.frame_count = nil, nil, nil, nil, nil
  local i = n.initial
  -- A sound with no length is a sound the timeline cannot draw and the mix cannot place, and
  -- the length usually came off the file that is not there. It keeps what it was written with,
  -- and falls back to a plain few seconds when it was never written with one.
  if n.kind == "audio" or n.kind == "tts" or n.kind == "sfx" or n.kind == "music" then
    n.media_duration = n.media_duration or i.duration or 3
    i.duration = i.duration or n.media_duration
    i.at = i.at or 0
  end
end

function R.media(nodes, fps)
  local decode = require("decode")

  -- Learn how long every sound is before anything else needs to know. Only `audio` nodes, whose
  -- file is simply the file they name: a generated one (tts, sfx, music) is found by a content
  -- hash that is not settled until the loop below has run, and asking early would be asking
  -- about the wrong file.
  do
    local ask, seen = {}, {}
    for _, n in ipairs(nodes) do
      if n.kind == "audio" and type(n.initial.src) == "string" then
        local ok, file = pcall(localize, n.initial.src)
        if ok and file and not seen[file] and not probe_recall(file) then
          seen[file] = true
          ask[#ask + 1] = file
        end
      end
    end
    probe_many(ask)
  end

  -- Everything one node needs, made ready. Separated from the walk below only so that one of
  -- these can fail on its own; see `went_offline`.
  local function resolve_one(n)
    if n.kind == "video" and decode.available then
      -- fast path: in-process FFI decoder, no extraction, frame-exact by PTS.
      -- yuv420 sources come back as raw planes (GPU converts); others as RGBA.
      local i = n.initial
      local file = localize(i.src)
      if i.derive then file, n.derived = require("derive").video(file, i.derive) end
      n.dec = decode.open(file, i.w, i.h)
      if i.cursor_src then n.cursor_file = localize(i.cursor_src) end
    elseif n.kind == "video" then
      local i = n.initial
      local file = localize(i.src)
      if i.derive then file, n.derived = require("derive").video(file, i.derive) end
      local key = sha1(table.concat({ file, i.media_start, i.duration, fps, i.w, i.h }, "|"))
      local dir = cache_root() .. "/frames/" .. key
      if not exists(dir .. "/DONE") then
        assert(sh(("mkdir -p '%s'"):format(dir)))
        local cmd = string.format(
          "ffmpeg -hide_banner -loglevel error -y -i '%s' -ss %f -t %f" ..
          " -vf 'fps=%d,scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d'" ..
          " -q:v 2 '%s/%%05d.jpg'",
          file, i.media_start, i.duration, fps, i.w, i.h, i.w, i.h, dir)
        local ok, out = sh(cmd)
        if not ok then error("moonsplice resolve: frame extraction failed:\n" .. out) end
        assert(sh(("touch '%s/DONE'"):format(dir)))
      end
      local _, count = sh(("ls '%s' | grep -c jpg"):format(dir))
      n.frames_dir = dir
      n.frame_count = tonumber(count:match("%d+")) or 0
      if n.frame_count == 0 then error("moonsplice resolve: no frames extracted for " .. i.src) end
    elseif n.kind == "image" and not n.initial.src and n.initial.prompt then
      local i = n.initial
      local aspect = i.aspect or (i.w and i.h and (i.w >= i.h * 1.5 and "16:9" or i.h >= i.w * 1.5 and "9:16" or "1:1")) or "16:9"
      local dst = cache_root() .. "/generated/" .. sha1(table.concat({ "minimax", i.model or "image-01", i.prompt, aspect,
        tostring(i.seed or "") }, "|")) .. ".png"
      if not exists(dst) then
        local root = os.getenv("MOONSPLICE_ROOT")
          or (love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", "")) or "."
        local cmd = ("'%s/bin/moonsplice-minimax' image --prompt %q --out %q --aspect %s"):format(root, i.prompt, dst, aspect)
        if i.seed then cmd = cmd .. " --seed " .. tonumber(i.seed) end
        if i.model then cmd = cmd .. (" --model %q"):format(i.model) end
        local ok, out = sh(cmd)
        if not ok or not exists(dst) then error("moonsplice resolve: image generation failed:\n" .. out, 0) end
      end
      n.file = dst
    elseif n.kind == "image" then
      n.file = localize(n.initial.src)
      if n.initial.cursor_src then n.cursor_file = localize(n.initial.cursor_src) end
      if not exists(n.file) then error("moonsplice resolve: image not found: " .. n.initial.src) end
    elseif n.kind == "lottie" then
      n.file = localize(n.initial.src)
      if not exists(n.file) then error("moonsplice resolve: lottie not found: " .. n.initial.src) end
    elseif n.kind == "mesh" and n.initial.src then
      n.file = localize(n.initial.src)
      if not exists(n.file) then error("moonsplice resolve: mesh not found: " .. n.initial.src) end
      local scene3d = require("scene3d")
      -- a built solid (.robot/docs/solids.robot) is drawn by Bevy from its .msh; scene3d reads glTF only
      if scene3d.available and not n.file:match("%.msh$") then
        n.mesh_id = scene3d.load(n.file)
        if not n.mesh_id or n.mesh_id == 0 then
          error("moonsplice resolve: glTF load failed: " .. n.file)
        end
      end
    elseif n.kind == "audio" or n.kind == "tts" or n.kind == "sfx" or n.kind == "music" then
      local i = n.initial
      if n.kind == "audio" then
        n.afile = localize(i.src)
        if i.derive then n.afile, n.derived = require("derive").audio(n.afile, i.derive) end
        if not exists(n.afile) then error("moonsplice resolve: audio not found: " .. i.src) end
      elseif n.kind == "tts" then
        -- auto request-stitching: a line chained to an earlier TTS clip inherits
        -- it as previous_text, so consecutive lines read as one narration
        local ref = (i.after and (i.after[1] or i.after.node)) or (i.at_word and i.at_word[1])
        if ref and ref.kind == "tts" and i.previous_text == nil and ref.initial.text then
          i.previous_text = ref.initial.text
        end
        n.afile = tts_generate(i, (i.align or i.align_at or i.at_word) and true or false)
      elseif n.kind == "music" then
        n.afile = music_generate(i)
      else
        n.afile = sfx_generate(i)
      end
      n.media_duration = ffprobe_duration(n.afile)
      -- default clip window = whole file; scripts can read i.duration after resolve
      i.duration = i.duration or (n.media_duration - i.media_start)
      -- sequential chaining: after = {ref_node, gap} places this clip when the
      -- referenced (earlier-created) clip ends. Resolution is in creation order,
      -- so the ref's at/duration are already final.
      if i.after then
        local ref = i.after[1] or i.after.node
        local gap = i.after[2] or i.after.gap or 0
        assert(ref and ref.initial and ref.initial.duration,
          "moonsplice: audio after={ref} must reference an earlier audio node")
        i.at = ref.initial.at + ref.initial.duration + gap
      end
      -- Forced alignment. Runs before the align_* scheduling props below, which
      -- need word offsets to place the clip at all.
      if (i.align or i.align_at or i.at_word) and (n.kind == "tts" or n.kind == "audio") then
        local words, phonemes = align_generate(n.afile, i.align_text or i.text or "")
        n.words = words
        n.phonemes = phonemes
      end
      -- align_at = { word = "Drop", at = 1.57 } OR { event = "beat", at = ... }
      if i.align_at then
        local target = i.align_at.at or i.align_at[2]
        if type(target) == "table" and target.initial then
          target = target.initial.at or 0
        end
        if i.align_at.word or i.align_at[1] then
          local want = normword(i.align_at.word or i.align_at[1])
          local hit
          for _, w in ipairs(n.words or {}) do
            if normword(w.text) == want then hit = w break end
          end
          if not hit then
            error(("moonsplice resolve: align_at word %q not spoken in %q"):format(
              i.align_at.word or i.align_at[1], i.text or ""), 0)
          end
          i.at = target - hit.t0
        elseif i.align_at.event then
          local want = (i.align_at.event):lower()
          local hit
          for _, ev in ipairs(n.events or {}) do
            if (ev.name and ev.name:lower() == want) or (ev.type and ev.type:lower() == want) then
              hit = ev break
            end
          end
          if hit then
            i.at = target - hit.t0
          end
        end
        if i.at and i.at < 0 then
          io.stderr:write(("moonsplice: align_at pulled %q to %.2fs (before zero) — clamped\n"):format(i.text or "?", i.at))
          i.at = 0
        end
      end
      -- at_word = { ref_node, "languages", gap } — start when another aligned
      -- clip finishes saying a given word.
      if i.at_word then
        local ref = i.at_word[1]
        assert(ref and ref.words, "moonsplice: at_word needs an earlier aligned node")
        local want, hit = normword(i.at_word[2]), nil
        for _, w in ipairs(ref.words) do
          if normword(w.text) == want then hit = w break end
        end
        assert(hit, "moonsplice: at_word word not found: " .. tostring(i.at_word[2]))
        i.at = ref.initial.at + hit.t1 + (i.at_word[3] or 0)
      end
      if i.follow then
        i.energy = bake_energy(n.afile, i.media_start or 0, i.duration)
      end
    elseif n.kind == "html" then
      if n.initial.src and not n.initial.html then
        local f = assert(_MOONSPLICE_IOOPEN(localize(n.initial.src), "r"),
          "moonsplice resolve: html src not found: " .. n.initial.src)
        n.initial.html = f:read("*a")
        f:close()
      end
    elseif n.kind == "page" then
      -- Fetch HTML + subresources here, then cache a viewport PNG. Painter is
      -- a static image draw — no network and no JS in evaluate(t).
      local html = require("html")
      if not html.available then
        error("moonsplice resolve: html dylib missing (build html/)")
      end
      local i = n.initial
      local src = i.src
      local base = i.base
      if src and src:match("^https?://") then
        base = base or src
        if not i.html then
          local f = assert(_MOONSPLICE_IOOPEN(localize(src), "r"),
            "moonsplice resolve: page src not found: " .. src)
          i.html = f:read("*a")
          f:close()
        end
      elseif src then
        local path = localize(src)
        if not i.html then
          local f = assert(_MOONSPLICE_IOOPEN(path, "r"),
            "moonsplice resolve: page src not found: " .. src)
          i.html = f:read("*a")
          f:close()
        end
        base = base or path
      end
      assert(i.html, "moonsplice resolve: page{html=} or page{src=} required")
      local w, h = i.w, i.h
      local png = cache_root() .. "/page/" .. sha1(table.concat({
        i.html, tostring(base or ""), tostring(w), tostring(h),
        i.bake == false and "0" or "1",
      }, "|")) .. ".png"
      if not exists(png) then
        assert(sh(("mkdir -p '%s/page'"):format(cache_root())))
        html.render_page_png(i.html, base or "", w, h, 1.0, png, i.bake ~= false)
      end
      n.file = png
    elseif n.kind == "svg" then
      local i = n.initial
      local src = localize(i.src)
      local png = cache_root() .. "/svg/" .. sha1(table.concat({ i.src, i.w, i.h }, "|")) .. ".png"
      if not exists(png) then
        assert(sh(("mkdir -p '%s/svg'"):format(cache_root())))
        local ok, out = sh(("resvg '%s' '%s' --width %d --height %d"):format(src, png, i.w, i.h))
        if not ok then error("moonsplice resolve: resvg failed:\n" .. out) end
      end
      n.file = png
    elseif n.kind == "spritesheet" then
      local i = n.initial
      local src = localize(i.src)
      local json_path = i.json and localize(i.json) or (src:match("%.json$") and src)
      if json_path then
        local f = assert(_MOONSPLICE_IOOPEN(json_path, "r"),
          "moonsplice resolve: spritesheet json not found: " .. json_path)
        local raw = f:read("*a")
        f:close()
        local data = require("moonsplice.json").decode(raw)
        local frames = {}
        if data.frames[1] then
          for _, fr in ipairs(data.frames) do
            frames[#frames + 1] = {
              x = fr.frame.x, y = fr.frame.y, w = fr.frame.w, h = fr.frame.h,
              duration = (fr.duration or 100) / 1000,
            }
          end
        else
          local list = {}
          for name, fr in pairs(data.frames) do
            list[#list + 1] = { name = name, fr = fr }
          end
          table.sort(list, function(a, b) return a.name < b.name end)
          for _, item in ipairs(list) do
            local fr = item.fr
            frames[#frames + 1] = {
              x = fr.frame.x, y = fr.frame.y, w = fr.frame.w, h = fr.frame.h,
              duration = (fr.duration or 100) / 1000,
            }
          end
        end
        assert(#frames > 0, "moonsplice resolve: spritesheet json has no frames")
        n.sheet = { frames = frames }
        if src:match("%.json$") then
          local img = i.image or (data.meta and data.meta.image)
          assert(img, "moonsplice resolve: spritesheet json missing meta.image")
          local dir = json_path:match("^(.*)/") or "."
          n.file = img:match("^/") and img or (dir .. "/" .. img)
        else
          n.file = src
        end
      else
        n.file = src
        n.sheet = { grid = true, cols = i.cols, rows = i.rows }
      end
      if not exists(n.file) then
        error("moonsplice resolve: spritesheet image not found: " .. n.file)
      end
    elseif n.kind == "displace" then
      if n.initial.src then
        n.file = localize(n.initial.src)
        if not exists(n.file) then
          error("moonsplice resolve: displace image not found: " .. n.initial.src)
        end
      end
    elseif n.kind == "text" and n.initial.src and not n.initial.cues then
      local path = localize(n.initial.src)
      local f = assert(_MOONSPLICE_IOOPEN(path, "r"), "moonsplice resolve: captions src not found: " .. n.initial.src)
      local raw = f:read("*a")
      f:close()
      local cap = require("moonsplice.captions")
      if path:match("%.csv$") then
        n.initial.cues = cap.normalize(cap.parse_csv(raw))
      else
        n.initial.cues = cap.normalize(cap.parse_srt(raw))
      end
    elseif n.kind == "spine" and n.initial.src and not n.initial.skeleton then
      local path = localize(n.initial.src)
      local f = assert(_MOONSPLICE_IOOPEN(path, "r"), "moonsplice resolve: spine src not found: " .. n.initial.src)
      local raw = f:read("*a")
      f:close()
      n.initial.skeleton = require("moonsplice.json").decode(raw)
    end
  end

  local tolerant = (os.getenv("MOONSPLICE_OFFLINE_OK") or "0") ~= "0"
  for _, n in ipairs(nodes) do
    if tolerant then
      local ok, err = pcall(resolve_one, n)
      if not ok then went_offline(n, err) end
    else
      resolve_one(n)
    end
  end
end

return R
