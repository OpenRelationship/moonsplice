-- Moonsplice Unified Audio Module: single entrypoint for web and local audio resolution.
-- Supports ONNX neural models (PocketTTS, Kokoro, Qwen-TTS), cloud providers
-- (Fish Audio, Cartesia, ElevenLabs, Ollama), and local forced alignment.

local M = {}

M.PROVIDERS = {
  onnx = { name = "ONNX Local Neural", local_only = true },
  kokoro = { name = "Kokoro 82M ONNX", local_only = true },
  pocket = { name = "PocketTTS ONNX", local_only = true },
  qwen = { name = "Qwen2-Audio/TTS ONNX", local_only = true },
  fish = { name = "Fish Audio", env = "FISH_AUDIO_API_KEY" },
  cartesia = { name = "Cartesia Sonic", env = "CARTESIA_API_KEY" },
  elevenlabs = { name = "ElevenLabs", env = "ELEVENLABS_API_KEY" },
  ollama = { name = "Ollama Local Speech", env = "OLLAMA_URL" },
}

function M.resolve_provider(opts)
  if opts and opts.provider and opts.provider ~= "" then
    return opts.provider:lower()
  end
  local env_p = (os.getenv and (os.getenv("MOONSPLICE_TTS_PROVIDER") or os.getenv("MOONSPLICE_AUDIO_PROVIDER")))
  if env_p and env_p ~= "" then
    return env_p:lower()
  end
  return "onnx"
end

function M.estimate_words(text, duration)
  local words = {}
  for w in (text or ""):gmatch("%S+") do
    words[#words + 1] = w
  end
  if #words == 0 then return {} end
  duration = duration or math.max(1, #words * 0.35)
  local step = duration / #words
  local out = {}
  for i, w in ipairs(words) do
    local t0 = (i - 1) * step
    local t1 = i * step
    out[#out + 1] = {
      text = w,
      start = t0,
      ["end"] = t1,
      t0 = t0,
      t1 = t1,
    }
  end
  return out
end

return M
