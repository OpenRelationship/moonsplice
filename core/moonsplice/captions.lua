-- Caption parsers (SRT, CSV). LÖVE has no lpeg.so; this is a PEG-style
-- combinator over strings so cue tables are host-free and seek-safe.
local C = {}

local function to_sec(h, m, s, ms)
  return tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s) + tonumber(ms) / 1000
end

function C.parse_srt(src)
  src = (src or ""):gsub("\r\n", "\n") .. "\n\n"
  local cues = {}
  for block in src:gmatch("(.-)\n\n") do
    local t0h, t0m, t0s, t0ms, t1h, t1m, t1s, t1ms, rest = block:match(
      "(%d+):(%d+):(%d+)[,.](%d+)%s*%-%-%>%s*(%d+):(%d+):(%d+)[,.](%d+)%s*\n(.*)")
    if t0h then
      local text = rest:gsub("\n", " "):gsub("^%s+", ""):gsub("%s+$", "")
      cues[#cues + 1] = {
        t0 = to_sec(t0h, t0m, t0s, t0ms),
        t1 = to_sec(t1h, t1m, t1s, t1ms),
        text = text,
      }
    end
  end
  return cues
end

function C.parse_csv(src)
  local cues = {}
  for line in (src .. "\n"):gmatch("(.-)\n") do
    if not line:match("^%s*#") and line:find(",") then
      local t0, t1, text = line:match("^%s*([^,]+)%s*,%s*([^,]+)%s*,%s*(.*)$")
      if t0 and t1 then
        text = text:gsub("^%s*\"", ""):gsub("\"%s*$", "")
        cues[#cues + 1] = { t0 = tonumber(t0) or 0, t1 = tonumber(t1) or 0, text = text }
      end
    end
  end
  return cues
end

function C.normalize(cues)
  local out = {}
  for _, c in ipairs(cues or {}) do
    if type(c) == "table" then
      out[#out + 1] = {
        t0 = c.t0 or c[1] or 0,
        t1 = c.t1 or c[2] or (c.t0 or c[1] or 0),
        text = c.text or c[3] or "",
      }
    end
  end
  table.sort(out, function(a, b) return a.t0 < b.t0 end)
  return out
end

local function normalize_words(words)
  local out = {}
  for _, w in ipairs(words or {}) do
    if type(w) == "table" then
      local t0 = w.t0 or w["start"] or 0
      local t1 = w.t1 or w["end"] or t0
      out[#out + 1] = { text = w.text or "", t0 = t0, t1 = t1 }
    end
  end
  return out
end

local function join_words(words, from_i, to_i)
  local parts = {}
  for i = from_i, to_i do
    local w = words[i]
    if w and w.text and w.text ~= "" then parts[#parts + 1] = w.text end
  end
  return table.concat(parts, " ")
end

-- Build seek-safe caption cues from flat aligned words.
-- opts.mode: "word" | "phrase" | "rolling" | "line" (line treats all words as one cue)
-- opts.window: max words visible for phrase/rolling (default 6)
function C.from_words(words, opts)
  opts = opts or {}
  local mode = (opts.mode or "phrase"):lower()
  local window = math.max(1, math.floor(tonumber(opts.window) or 6))
  words = normalize_words(words)
  if #words == 0 then return {} end

  if mode == "line" then
    return C.normalize({
      {
        t0 = words[1].t0,
        t1 = words[#words].t1,
        text = join_words(words, 1, #words),
      },
    })
  end

  if mode == "word" then
    local cues = {}
    for i, w in ipairs(words) do
      local t1 = words[i + 1] and words[i + 1].t0 or w.t1
      cues[#cues + 1] = { t0 = w.t0, t1 = t1, text = w.text }
    end
    return C.normalize(cues)
  end

  local cues = {}
  for i, w in ipairs(words) do
    local from_i = mode == "rolling" and 1 or math.max(1, i - window + 1)
    local t1 = words[i + 1] and words[i + 1].t0 or w.t1
    cues[#cues + 1] = {
      t0 = w.t0,
      t1 = t1,
      text = join_words(words, from_i, i),
    }
  end
  return C.normalize(cues)
end

-- Build cues from transcript lines (__doc.lines). Phrase/rolling reset at each line.
function C.from_lines(lines, opts)
  opts = opts or {}
  local mode = (opts.mode or "phrase"):lower()
  if mode == "line" then
    local cues = {}
    for _, line in ipairs(lines or {}) do
      local words = normalize_words(line.words)
      if #words > 0 then
        cues[#cues + 1] = {
          t0 = words[1].t0,
          t1 = words[#words].t1,
          text = join_words(words, 1, #words),
        }
      end
    end
    return C.normalize(cues)
  end

  local cues = {}
  for _, line in ipairs(lines or {}) do
    local line_cues = C.from_words(line.words, opts)
    for _, cue in ipairs(line_cues) do
      cues[#cues + 1] = cue
    end
  end
  return C.normalize(cues)
end

-- Clamp captions to VO and append a clear step so text does not hold through editorial.
function C.apply_tail(cues, vo_end, tail)
  cues = C.normalize(cues)
  vo_end = tonumber(vo_end) or 0
  tail = math.max(0, tonumber(tail) or 0.35)
  if #cues == 0 or vo_end <= 0 then return cues end

  local out = {}
  for _, c in ipairs(cues) do
    if c.t0 < vo_end + 1e-6 then
      out[#out + 1] = {
        t0 = c.t0,
        t1 = math.min(c.t1 or c.t0, vo_end),
        text = c.text,
      }
    end
  end
  out[#out + 1] = { t0 = vo_end, t1 = vo_end + tail, text = "" }
  return C.normalize(out)
end

function C.active(cues, t)
  for i = #cues, 1, -1 do
    local c = cues[i]
    if t >= c.t0 and t < (c.t1 > c.t0 and c.t1 or 1e9) then return c.text end
    if t >= c.t0 then return c.text end
  end
  return ""
end

return C
