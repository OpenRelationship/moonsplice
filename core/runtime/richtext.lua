-- Wrapped + tagged type. Host-only (needs Font:getWidth / getWrap / print).
-- Tags: {c:#rrggbb}...{/c}  {#rrggbb}...{/}  {b}...{/b}  {i}...{/i}
-- Type-on is `reveal` in 0..1 over visible characters (tags do not count).
local R = {}

local function hexcolor(s)
  s = s:gsub("^#", "")
  if #s == 6 then
    return {
      tonumber(s:sub(1, 2), 16) / 255,
      tonumber(s:sub(3, 4), 16) / 255,
      tonumber(s:sub(5, 6), 16) / 255,
      1,
    }
  end
end

local function utf8_len(s, i)
  local c = s:byte(i)
  if not c then return 0 end
  if c < 0x80 then return 1 end
  if c < 0xE0 then return 2 end
  if c < 0xF0 then return 3 end
  return 4
end

local function utf8_sub(s, i)
  return s:sub(i, i + utf8_len(s, i) - 1), utf8_len(s, i)
end

function R.parse(text, default_color)
  local runs, buf = {}, {}
  local color, bold, italic = default_color, false, false
  local stack = {}
  local i, n = 1, #text
  local function flush()
    if #buf == 0 then return end
    runs[#runs + 1] = {
      text = table.concat(buf),
      color = color,
      bold = bold,
      italic = italic,
    }
    buf = {}
  end
  local function push_style()
    stack[#stack + 1] = { color = color, bold = bold, italic = italic }
  end
  local function pop_style()
    local prev = table.remove(stack)
    if prev then
      color, bold, italic = prev.color, prev.bold, prev.italic
    else
      color, bold, italic = default_color, false, false
    end
  end
  while i <= n do
    if text:sub(i, i) == "{" then
      local close = text:find("}", i + 1, true)
      if not close then
        local ch, len = utf8_sub(text, i)
        buf[#buf + 1] = ch
        i = i + len
      else
        local inner = text:sub(i + 1, close - 1)
        flush()
        if inner == "/c" or inner == "/" or inner == "/b" or inner == "/i" then
          pop_style()
        elseif inner == "b" then
          push_style()
          bold = true
        elseif inner == "i" then
          push_style()
          italic = true
        else
          local hex = inner:match("^c:(#%x%x%x%x%x%x)$") or inner:match("^(#%x%x%x%x%x%x)$")
          if hex then
            push_style()
            color = hexcolor(hex) or color
          else
            buf[#buf + 1] = text:sub(i, close)
          end
        end
        i = close + 1
      end
    else
      local ch, len = utf8_sub(text, i)
      buf[#buf + 1] = ch
      i = i + len
    end
  end
  flush()
  return runs
end

function R.plain(runs)
  local parts = {}
  for _, run in ipairs(runs) do parts[#parts + 1] = run.text end
  return table.concat(parts)
end

function R.reveal(runs, k)
  if k == nil or k >= 1 then return runs end
  if k <= 0 then return {} end
  local function ulen(s)
    local n, i = 0, 1
    while i <= #s do
      n = n + 1
      i = i + utf8_len(s, i)
    end
    return n
  end
  local function usub(s, nchars)
    local i, seen = 1, 0
    while i <= #s and seen < nchars do
      i = i + utf8_len(s, i)
      seen = seen + 1
    end
    return s:sub(1, i - 1)
  end
  local budget = 0
  for _, run in ipairs(runs) do budget = budget + ulen(run.text) end
  local remain = math.floor(budget * k + 0.0001)
  local out = {}
  for _, run in ipairs(runs) do
    if remain <= 0 then break end
    local n = ulen(run.text)
    local take = math.min(n, remain)
    out[#out + 1] = {
      text = usub(run.text, take),
      color = run.color,
      bold = run.bold,
      italic = run.italic,
    }
    remain = remain - take
  end
  return out
end

-- Word-wrap tagged runs to `width` using Font:getWidth. Spaces stay attached
-- to the following word so a wrap never starts with a space.
local function tokens(text)
  local out, i, n = {}, 1, #text
  while i <= n do
    local ch, len = utf8_sub(text, i)
    if ch == "\n" then
      out[#out + 1] = { kind = "nl", text = "\n" }
      i = i + len
    else
      local j = i
      while j <= n do
        local cj, lj = utf8_sub(text, j)
        if cj == " " or cj == "\n" then break end
        j = j + lj
      end
      local k = j
      while k <= n do
        local ck, lk = utf8_sub(text, k)
        if ck ~= " " then break end
        k = k + lk
      end
      out[#out + 1] = { kind = "word", text = text:sub(i, k - 1) }
      i = k
    end
  end
  return out
end

function R.wrap(font, runs, width)
  local lines, line, x = {}, {}, 0
  local function newline()
    lines[#lines + 1] = line
    line, x = {}, 0
  end
  for _, run in ipairs(runs) do
    for _, tok in ipairs(tokens(run.text)) do
      if tok.kind == "nl" then
        newline()
      else
        local w = font:getWidth(tok.text)
        if width and x > 0 and x + w > width then newline() end
        line[#line + 1] = {
          text = tok.text,
          color = run.color,
          bold = run.bold,
          italic = run.italic,
          w = w,
        }
        x = x + w
      end
    end
  end
  if #line > 0 or #lines == 0 then lines[#lines + 1] = line end
  return lines
end

function R.draw(g, font, lines, leading, opacity, ox, oy)
  local lh = font:getHeight() * (leading or 1.15)
  g.setFont(font)
  for li, line in ipairs(lines) do
    local x = ox
    local y = oy + (li - 1) * lh
    for _, run in ipairs(line) do
      local c = run.color or { 1, 1, 1, 1 }
      g.setColor(c[1], c[2], c[3], (c[4] or 1) * opacity)
      g.print(run.text, x, y)
      if run.bold then g.print(run.text, x + 1, y) end
      x = x + (run.w or font:getWidth(run.text))
    end
  end
end

function R.measure(font, lines, leading)
  local lh = font:getHeight() * (leading or 1.15)
  local w, h = 0, #lines * lh
  for _, line in ipairs(lines) do
    local lw = 0
    for _, run in ipairs(line) do lw = lw + (run.w or font:getWidth(run.text)) end
    if lw > w then w = lw end
  end
  return w, h
end

return R
