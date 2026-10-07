-- A source file as its top-level chunks: each definition with the comment above it, its first and last line, and
-- its size. A split plan (splits.lua) assigns chunks to modules by name, so a plan's module sizes are measured from
-- the file, not guessed. Lua: a chunk starts at a column-0 `local function`, `function`, `local name =` or
-- `M.name =`. Rust: at a column-0 item (`fn`, `pub fn`, `impl`, `struct`, `enum`, `mod`, `const`, `static`, `type`,
-- `trait`, `#[`, `use`). TypeScript: a column-0 function, const, let, type, interface, class or enum, exported
-- or not, and a top-level describe or test. Everything before the first chunk is the head (requires, uses, the file's opening comment).
--
--   outline.chunks(text, ext) -> { { name, first, last, lines }, ... }, head_lines
local M = {}

local LUA = {
  "^local%s+function%s+([%w_%.:]+)", "^function%s+([%w_%.:]+)", "^local%s+([%w_]+)%s*=", "^([%w_]+%.[%w_%.]+)%s*=",
  "^([%w_]+)%s*=%s*function",
}
local RUST = {
  "^pub%s*%b()%s*fn%s+([%w_]+)", "^pub%s+fn%s+([%w_]+)", "^fn%s+([%w_]+)", "^pub%s+async%s+fn%s+([%w_]+)",
  "^impl%s*%b<>%s*([%w_:<>, ]+)", "^impl%s+([%w_:<>, ]+)", "^pub%s+struct%s+([%w_]+)", "^struct%s+([%w_]+)",
  "^pub%s+enum%s+([%w_]+)", "^enum%s+([%w_]+)", "^pub%s+mod%s+([%w_]+)", "^mod%s+([%w_]+)",
  "^pub%s+const%s+([%w_]+)", "^const%s+([%w_]+)", "^pub%s+static%s+([%w_]+)", "^static%s+([%w_]+)",
  "^pub%s+type%s+([%w_]+)", "^type%s+([%w_]+)", "^pub%s+trait%s+([%w_]+)", "^trait%s+([%w_]+)",
  "^pub%s*%b()%s*struct%s+([%w_]+)", "^pub%s*%b()%s*const%s+([%w_]+)",
}

local TS = {
  "^export%s+default%s+function%s+([%w_$]+)", "^export%s+async%s+function%s+([%w_$]+)", "^export%s+function%s+([%w_$]+)",
  "^async%s+function%s+([%w_$]+)", "^function%s+([%w_$]+)", "^export%s+const%s+([%w_$]+)", "^const%s+([%w_$]+)",
  "^let%s+([%w_$]+)", "^export%s+let%s+([%w_$]+)", "^export%s+type%s+([%w_$]+)", "^type%s+([%w_$]+)",
  "^export%s+interface%s+([%w_$]+)", "^interface%s+([%w_$]+)", "^export%s+class%s+([%w_$]+)", "^class%s+([%w_$]+)",
  "^export%s+enum%s+([%w_$]+)", "^describe%(\"([^\"]+)", "^describe%('([^']+)", "^test%(\"([^\"]+)", "^it%(\"([^\"]+)",
}

local function starts(line, pats)
  for _, p in ipairs(pats) do
    local name = line:match(p)
    if name then return (name:gsub("%s+$", "")) end
  end
end

local function is_comment(line, ext)
  if ext == "rs" then return line:match("^%s*//") or line:match("^#%[") end
  if ext == "ts" or ext == "tsx" then return line:match("^%s*//") or line:match("^%s*/?%*") end
  return line:match("^%-%-")
end

function M.chunks(text, ext)
  local lines = {}
  for l in (text .. "\n"):gmatch("(.-)\r?\n") do lines[#lines + 1] = l end
  if lines[#lines] == "" then lines[#lines] = nil end
  local pats = ext == "rs" and RUST or (ext == "ts" or ext == "tsx") and TS or LUA
  local out = {}
  local test_mod = false
  for i, line in ipairs(lines) do
    local name = not test_mod and starts(line, pats)
    if ext == "rs" and line:match("^mod%s+tests") then name = "tests"; test_mod = true end
    if name then
      -- the comment block (and attributes) right above belongs to the chunk
      local first = i
      while first > 1 and is_comment(lines[first - 1], ext) do first = first - 1 end
      if #out > 0 and first <= out[#out].first then first = i end
      out[#out + 1] = { name = name, first = first }
    end
  end
  for k, c in ipairs(out) do
    c.last = k < #out and out[k + 1].first - 1 or #lines
    c.lines = c.last - c.first + 1
  end
  local head = #out > 0 and out[1].first - 1 or #lines
  return out, head, #lines
end

-- a plain-text outline for a person or an agent planning a split
function M.show(path, text)
  local ext = path:match("%.(%w+)$") or ""
  local chunks, head, total = M.chunks(text, ext)
  local out = { ("%s: %d lines, head %d, %d chunks"):format(path, total, head, #chunks) }
  for _, c in ipairs(chunks) do out[#out + 1] = ("  %5d-%-5d %4d  %s"):format(c.first, c.last, c.lines, c.name) end
  return table.concat(out, "\n")
end

-- the sizes a plan gives. plan = { rest = path, modules = { [path] = { pattern, ... } }, ranges = { [path] = { {a, b},
-- ... } }?, overhead? }: a chunk goes to the first module (by path order) with a pattern its name matches, else to
-- rest; then each range's lines go to its module whatever chunk holds them (a giant function's branches, a comp's
-- chapters). A new module costs `overhead` lines (its requires and return), 6 unless said.
-- -> { [path] = lines }, { [pattern] = matched? }
function M.measure(text, ext, plan)
  local chunks, head, total = M.chunks(text, ext)
  local owner = {}
  for i = 1, head do owner[i] = plan.rest end
  local order = {}
  for path in pairs(plan.modules or {}) do order[#order + 1] = path end
  table.sort(order)
  local used = {}
  for _, path in ipairs(order) do for _, p in ipairs(plan.modules[path]) do used[p] = false end end
  for _, c in ipairs(chunks) do
    local into = plan.rest
    for _, path in ipairs(order) do
      for _, p in ipairs(plan.modules[path]) do
        if c.name:find(p) then into = path; used[p] = true; break end
      end
      if into ~= plan.rest then break end
    end
    for i = c.first, c.last do owner[i] = into end
  end
  for path, list in pairs(plan.ranges or {}) do
    for _, r in ipairs(list) do for i = r[1], math.min(r[2], total) do owner[i] = path end end
  end
  local sizes = {}
  for i = 1, total do local o = owner[i] or plan.rest; sizes[o] = (sizes[o] or 0) + 1 end
  for path, n in pairs(sizes) do if path ~= plan.rest then sizes[path] = n + (plan.overhead or 6) end end
  return sizes, used
end

return M
