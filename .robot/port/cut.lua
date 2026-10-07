-- Cuts a Lua file by its plan in splits.lua, moving whole top-level chunks (outline.lua) and never retyping code:
-- the rest stays at the plan's rest path, each module gets its chunks in their original order. The rest registers
-- itself in package.loaded before requiring the parts, and the parts read the shared locals from <TABLE>._.
--
--   luajit .robot/port/cut.lua FILE MODNAME TABLE SHARED...   e.g. core/moonsplice/rows.lua moonsplice.rows R copy num
-- Only plans without ranges; a giant function's branches are cut by hand.
package.path = (arg[0]:match("^(.*)/[^/]+$") or ".") .. "/?.lua;" .. package.path
local outline = require("outline")
local splits = require("splits")

local file, modname, T = arg[1], arg[2], arg[3]
local shared = {}
for i = 4, #arg do shared[#shared + 1] = arg[i] end
local plan = assert(splits[file], "no plan for " .. file)
assert(not plan.ranges, "plan has ranges: cut by hand")
local text = assert(io.open(file)):read("*a")
local lines = {}
for l in (text .. "\n"):gmatch("(.-)\n") do lines[#lines + 1] = l end
while lines[#lines] == "" do lines[#lines] = nil end
-- the module's own `return T` is not part of its last chunk
assert(lines[#lines] == "return " .. T, "the file must end `return " .. T .. "`")
lines[#lines] = nil
while lines[#lines] == "" do lines[#lines] = nil end
text = table.concat(lines, "\n") .. "\n"
local chunks, head = outline.chunks(text, "lua")

local order = {}
for p in pairs(plan.modules) do order[#order + 1] = p end
table.sort(order)
local parts, rest = {}, {}
for i = 1, head do rest[#rest + 1] = lines[i] end
for _, c in ipairs(chunks) do
  local into
  for _, p in ipairs(order) do
    for _, pat in ipairs(plan.modules[p]) do if c.name:find(pat) then into = p break end end
    if into then break end
  end
  local body = {}
  for i = c.first, c.last do body[#body + 1] = lines[i] end
  if into then
    parts[into] = parts[into] or {}
    for _, l in ipairs(body) do table.insert(parts[into], l) end
  else
    for _, l in ipairs(body) do rest[#rest + 1] = l end
  end
end

-- the rest ends by exporting the shared locals, loading the parts, and `return T`
while rest[#rest] == "" do rest[#rest] = nil end
local exp = {}
for _, n in ipairs(shared) do exp[#exp + 1] = n .. " = " .. n end
rest[#rest + 1] = ""
rest[#rest + 1] = "-- what the parts share, and the parts (they load after this table is registered as " .. modname .. ")"
rest[#rest + 1] = T .. "._ = { " .. table.concat(exp, ", ") .. " }"
rest[#rest + 1] = "package.loaded[\"" .. modname .. "\"] = " .. T
for _, p in ipairs(order) do
  rest[#rest + 1] = "require(\"" .. modname .. "." .. p:match("([^/]+)%.lua$") .. "\")"
end
rest[#rest + 1] = ""
rest[#rest + 1] = "return " .. T

local function write(path, ls)
  os.execute("mkdir -p '" .. path:match("^(.*)/[^/]+$") .. "'")
  local f = assert(io.open(path, "w")); f:write(table.concat(ls, "\n") .. "\n"); f:close()
end

for _, p in ipairs(order) do
  local body = table.concat(parts[p] or {}, "\n")
  local used = {}
  for _, n in ipairs(shared) do if body:find("%f[%w_]" .. n .. "%f[^%w_]") then used[#used + 1] = n end end
  local out = { "-- Part of " .. modname .. " (" .. plan.rest .. "): see its head for the module's contract.",
    "local " .. T .. " = require(\"" .. modname .. "\")" }
  if #used > 0 then
    local rhs = {}
    for _, n in ipairs(used) do rhs[#rhs + 1] = T .. "._." .. n end
    out[#out + 1] = "local " .. table.concat(used, ", ") .. " = " .. table.concat(rhs, ", ")
  end
  out[#out + 1] = ""
  for _, l in ipairs(parts[p] or {}) do out[#out + 1] = l end
  write(p, out)
  print(("%-40s %d lines"):format(p, #out))
end
os.remove(file)
write(plan.rest, rest)
print(("%-40s %d lines"):format(plan.rest, #rest))
