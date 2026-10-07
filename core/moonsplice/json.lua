-- Minimal JSON decoder. Resolve-time only (canon §1.4 forbids render-time I/O).
-- Exists so alignment/marker sidecars parse without a python3 or jq dependency.
local J = {}

local function skip(s, i)
  while true do
    local c = s:sub(i, i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then i = i + 1 else return i end
  end
end

local ESC = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
              f = "\f", n = "\n", r = "\r", t = "\t" }

local function parse_string(s, i)
  i = i + 1 -- opening quote
  local out = {}
  while true do
    local c = s:sub(i, i)
    if c == "" then error("moonsplice json: unterminated string") end
    if c == '"' then return table.concat(out), i + 1 end
    if c == "\\" then
      local e = s:sub(i + 1, i + 1)
      if e == "u" then
        local hex = tonumber(s:sub(i + 2, i + 5), 16) or 63
        -- BMP → UTF-8; surrogate pairs collapse to '?' (no astral text in our feeds)
        if hex < 0x80 then
          out[#out + 1] = string.char(hex)
        elseif hex < 0x800 then
          out[#out + 1] = string.char(0xC0 + math.floor(hex / 0x40), 0x80 + hex % 0x40)
        else
          out[#out + 1] = string.char(0xE0 + math.floor(hex / 0x1000),
            0x80 + math.floor(hex / 0x40) % 0x40, 0x80 + hex % 0x40)
        end
        i = i + 6
      else
        out[#out + 1] = ESC[e] or e
        i = i + 2
      end
    else
      out[#out + 1] = c
      i = i + 1
    end
  end
end

local parse_value

local function parse_array(s, i)
  local arr, n = {}, 0
  i = skip(s, i + 1)
  if s:sub(i, i) == "]" then return arr, i + 1 end
  while true do
    local v
    v, i = parse_value(s, i)
    n = n + 1
    arr[n] = v
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "," then i = skip(s, i + 1)
    elseif c == "]" then return arr, i + 1
    else error("moonsplice json: expected , or ] at " .. i) end
  end
end

local function parse_object(s, i)
  local obj = {}
  i = skip(s, i + 1)
  if s:sub(i, i) == "}" then return obj, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then error("moonsplice json: expected key at " .. i) end
    local k
    k, i = parse_string(s, i)
    i = skip(s, i)
    if s:sub(i, i) ~= ":" then error("moonsplice json: expected : at " .. i) end
    i = skip(s, i + 1)
    obj[k], i = parse_value(s, i)
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "," then i = skip(s, i + 1)
    elseif c == "}" then return obj, i + 1
    else error("moonsplice json: expected , or } at " .. i) end
  end
end

parse_value = function(s, i)
  i = skip(s, i)
  local c = s:sub(i, i)
  if c == "{" then return parse_object(s, i) end
  if c == "[" then return parse_array(s, i) end
  if c == '"' then return parse_string(s, i) end
  if s:sub(i, i + 3) == "true" then return true, i + 4 end
  if s:sub(i, i + 4) == "false" then return false, i + 5 end
  if s:sub(i, i + 3) == "null" then return nil, i + 4 end
  local num = s:match("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", i)
  if num and num ~= "" then return tonumber(num), i + #num end
  error("moonsplice json: unexpected character " .. string.format("%q", c) .. " at " .. i)
end

function J.decode(s)
  local v = parse_value(s, 1)
  return v
end

return J
