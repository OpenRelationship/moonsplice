-- Runs Moonsplice's unit tests: every core/**/*_test.lua, each in its own process, with core/, core/runtime/ and
-- tablua's test library (submodules/tablua/test/spec.lua: test, eq, ok, same, err, run) on the module path.
--   luajit test/run.lua            all of them
--   luajit test/run.lua rows lint  only files whose path holds one of the words
local root = arg[0]:match("^(.*)/test/run%.lua$") or "."
local tablua = os.getenv("TABLUA") or (root .. "/submodules/tablua")

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local files = {}
local list = io.popen("find " .. quote(root .. "/core") .. " -name '*_test.lua' 2>/dev/null | sort")
for path in list:lines() do
  local keep = #arg == 0
  for _, word in ipairs(arg) do if path:find(word, 1, true) then keep = true end end
  if keep then files[#files + 1] = path end
end
list:close()

local paths = table.concat({ root .. "/core/?.lua", root .. "/core/?/init.lua", root .. "/core/runtime/?.lua",
  root .. "/core/runtime/?/init.lua", tablua .. "/test/?.lua", "" }, ";")
local setup = "package.path=" .. string.format("%q", paths) .. "..package.path"

local failed = {}
for _, path in ipairs(files) do
  local name = path:sub(#root + 2)
  local out = io.popen(("luajit -e %s %s 2>&1; echo \"exit:$?\""):format(quote(setup), quote(path)))
  local text = out:read("*a")
  out:close()
  local code = tonumber(text:match("exit:(%d+)%s*$"))
  local summary = text:match("# (%d+ passed, %d+ failed)") or "no TAP summary"
  if code == 0 then print(("ok   %s  (%s)"):format(name, summary))
  else
    failed[#failed + 1] = name
    print(("FAIL %s  (%s)"):format(name, summary))
    for line in text:gsub("exit:%d+%s*$", ""):gmatch("[^\n]+") do
      if not line:match("^ok ") then print("     " .. line) end
    end
  end
end
print(("%d files, %d failed"):format(#files, #failed))
os.exit(#failed == 0 and 0 or 1)
