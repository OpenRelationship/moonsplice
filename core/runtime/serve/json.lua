-- Part of serve (core/runtime/serve/init.lua): see its head for the module's contract.
local S = require("serve")

local esc = {
  ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t",
  ["\b"] = "\\b", ["\f"] = "\\f",
}
local function qstr(s)
  return '"' .. tostring(s):gsub('[%c"\\]', function(c)
    return esc[c] or string.format("\\u%04x", c:byte())
  end) .. '"'
end

local function num(v)
  if v ~= v or v == math.huge or v == -math.huge then return "null" end
  if v == math.floor(v) and math.abs(v) < 1e15 then return string.format("%d", v) end
  return (string.format("%.6f", v):gsub("0+$", ""):gsub("%.$", ""))
end

local encode
local function enc_array(t)
  local out = {}
  for i = 1, #t do out[i] = encode(t[i]) end
  return "[" .. table.concat(out, ",") .. "]"
end

local function enc_object(t)
  -- stable key order: the outline is compared in tests
  local keys = {}
  for k in pairs(t) do if type(k) == "string" then keys[#keys + 1] = k end end
  table.sort(keys)
  local out = {}
  for _, k in ipairs(keys) do
    local v = encode(t[k])
    if v then out[#out + 1] = qstr(k) .. ":" .. v end
  end
  return "{" .. table.concat(out, ",") .. "}"
end

encode = function(v)
  local ty = type(v)
  if v == nil then return nil end
  if ty == "number" then return num(v) end
  if ty == "boolean" then return v and "true" or "false" end
  if ty == "string" then return qstr(v) end
  if ty == "table" then
    if v.__empty_array then return "[]" end
    if #v > 0 then return enc_array(v) end
    if next(v) == nil then return "{}" end
    return enc_object(v)
  end
  return nil -- functions, userdata: not part of the outline
end
S.encode = encode

-- ------------------------------------------------------------------------ human labels

