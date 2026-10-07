-- Runs Moonsplice's Robot suites with tablua's Robot engine (tablua/core/robot, portable Lua).
--
--   luajit .robot/run.lua                       rules.robot, the repository's laws
--   luajit .robot/run.lua port                  the port's checks, a dry run that writes nothing
--   luajit .robot/run.lua port --tasks          the port itself: its *** Tasks *** write into this checkout
--   luajit .robot/run.lua SUITE [--tasks] [--only NAME] [--var NAME=VALUE ...]
--   luajit .robot/run.lua outline PATH          a ported file's chunks, for writing its split plan
-- SUITE is a path or a name under .robot/ (rules, port/port, docs/design ...). Exit status 1 when anything failed.
local here = arg[0]:match("^(.*)/[^/]+$") or "."
local root = here:match("^(.*)/%.robot$") or (here == ".robot" and ".") or ".."
local tablua = os.getenv("TABLUA") or (root .. "/tablua")

package.path = table.concat({
  here .. "/?.lua", here .. "/port/?.lua",
  tablua .. "/core/?.lua", tablua .. "/core/?/init.lua",
  package.path,
}, ";")

local ok, robot = pcall(require, "robot")
if not ok then
  io.stderr:write("tablua is not checked out at " .. tablua .. ": git submodule update --init\n")
  os.exit(2)
end

local args, opts = {}, { variables = {}, rpa = false, only = nil }
local i = 1
while i <= #arg do
  local a = arg[i]
  if a == "--tasks" then opts.rpa = true
  elseif a == "--only" then i = i + 1; opts.only = opts.only or {}; opts.only[arg[i]] = true
  elseif a == "--var" then
    i = i + 1
    local k, v = arg[i]:match("^([^=]+)=(.*)$")
    opts.variables["${" .. k .. "}"] = v
  else args[#args + 1] = a end
  i = i + 1
end

-- the checkout the port writes into and the laws measure: this one, unless MOONSPLICE_ROOT names a trial tree
local target = os.getenv("MOONSPLICE_ROOT") or root
local libs = { require("laws").library(target) }

if args[1] == "outline" then
  local port = require("port").library(target)
  local res = robot.run(robot.parse("*** Test Cases ***\nOutline\n    Use Source\n    Outline    " .. args[2] .. "\n"),
    { libraries = { port } })
  os.exit(res.status == "PASS" and 0 or 1)
end

local name = args[1] or "rules"
local path = name:match("%.robot$") and name or (here .. "/" .. name .. ".robot")
if not io.open(path) and name == "port" then path = here .. "/port/port.robot" end
local f = io.open(path)
if not f then io.stderr:write("no suite " .. path .. "\n"); os.exit(2) end
local text = f:read("*a"); f:close()

libs[#libs + 1] = require("port").library(target)

local function deepest(node)
  for _, c in ipairs(node.children or node.body or {}) do if c.status == "FAIL" then return deepest(c) end end
  return node
end

local res = robot.run(robot.parse(text), { libraries = libs, clock = os.clock, variables = opts.variables,
  rpa = opts.rpa, only = opts.only })

local MARK = { PASS = "pass", FAIL = "FAIL", SKIP = "skip", ["NOT RUN"] = "----" }
print(("%s  %s"):format(path:match("(%.robot/.*)$") or path, opts.rpa and "(tasks)" or ""))
for _, t in ipairs(res.tests) do
  print(("  %s  %s"):format(MARK[t.status] or t.status, t.name))
  if t.status == "FAIL" then
    local d = deepest(t)
    local why = (d.message or t.message or ""):gsub("\n", "\n        ")
    print("        at " .. tostring(d.name) .. ": " .. why)
  end
end
for _, l in ipairs(res.logs or {}) do print("  log: " .. tostring(l)) end
print(("%d passed, %d failed, %d skipped of %d"):format(res.passed, res.failed, res.skipped, res.total))
os.exit(res.failed == 0 and 0 or 1)
