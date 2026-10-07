-- Generated sound: text to speech, music and effects (ElevenLabs) and word alignment. Part of resolve.
local F = require("resolve.files")
local sh, sha1, cache_root, exists = F.sh, F.sha1, F.cache_root, F.exists

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


return {
  tts_generate = tts_generate,
  music_generate = music_generate,
  sfx_generate = sfx_generate,
  normword = normword,
  align_generate = align_generate,
}
