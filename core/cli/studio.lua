-- moonsplice studio: one Tablua run on a comp, the way pi runs (Tablua's studio.session). MiniMax M3 drives with the
-- studio's tools behind this launcher; Jev (OpenRouter) judges each look; TabICL in the engine ranks the moves
-- before each patch; connect reaches other people's apps through connectory (cli/connect.lua, core/connect). The
-- comp is edited in place, so point it at a copy. Rows go to the sheet; the log, asks among it, to stderr.
--
--   moonsplice studio --comp COMP --ask TEXT [--kind video|game] [--sheet RUN.sqlite] [--todo run1]
--     [--past a.sqlite,b.sqlite] [--tabicl off] [--connect off] [--work DIR]
-- --work is where the run keeps its scratch (the sheet's picture, the engine's temp files); the comp's folder when
-- not given. The editor's agent panel runs this with a folder of its own, so a run leaves nothing in the project.
-- The model key is OPENROUTER_API_KEY, from the environment or the keychain (connect's store). The last line on
-- stdout is the run as JSON, with asks: what still waits on the person (connect it, approve a call) and how.
local json = require("ports.json")

local M = {}

function M.run(cli, args)
  local o = { kind = "video", todo = "run1" }
  local i = 1
  while args[i] do
    local k = args[i]:match("^%-%-(.+)$")
    if not (k and args[i + 1]) then
      io.stderr:write("usage: moonsplice studio --comp COMP --ask TEXT [--kind] [--sheet] [--todo] [--past] [--connect off]\n")
      return 2
    end
    o[k] = args[i + 1]
    i = i + 2
  end
  if not (o.comp and o.ask) then io.stderr:write("moonsplice studio: --comp and --ask are needed\n") return 2 end
  o.sheet = o.sheet or (o.comp:gsub("%.lua$", "") .. ".sqlite")
  local dir = o.work or o.comp:match("^(.*)/[^/]*$") or "."
  os.execute("mkdir -p '" .. dir:gsub("'", "'\\''") .. "'")
  local bin = cli.root .. "/moonsplice"
  local function log(s) io.stderr:write(s, "\n") io.stderr:flush() end

  local store = require("connect.store").new()
  local host = { fetch = require("ports.curl").fetch, now = os.time }
  function host.exec(cmd)
    local p = assert(io.popen(cmd .. " 2>" .. dir .. "/exec.err"))
    local out = p:read("*a")
    local ok, _, code = p:close()
    local ef = io.open(dir .. "/exec.err")
    local err = ef and ef:read("*a") or ""
    if ef then ef:close() end
    return { code = ok and 0 or (code or 1), stdout = out, stderr = err }
  end
  function host.write(path, text)
    local f = assert(io.open(path, "w"))
    f:write(text)
    f:close()
  end

  local key = store:get("OPENROUTER_API_KEY")
  if not key then
    io.stderr:write("moonsplice studio: no OPENROUTER_API_KEY; run `./moonsplice connect openrouter` or export it\n")
    return 2
  end
  local m3 = require("ports.chat").new(host, { key = key, model = "minimax/minimax-m3", sort = "throughput",
    timeout = 240 })
  local jev = require("ports.jev").new(host, { key = key, model = "openai/gpt-6-luna-decisions" })

  local rf = io.open(cli.root .. "/.robot/docs/reference.robot")
  local reference = rf and rf:read("*a")
  if rf then rf:close() end

  local tick = 0
  local t = require("tablua").open(require("ports.sqlite").open(o.sheet),
    { clock = function() tick = tick + 1 return tick end })
  local k = 0
  for path in tostring(o.past or ""):gmatch("[^,]+") do k = k + 1 t:attach("past" .. k, path) end

  -- TabICL in the engine: one JSON body in and one reply out per call, local
  function host.tabicl(body)
    local path = dir .. "/tabicl.json"
    host.write(path, json.encode(body) .. "\n")
    local r = host.exec(("'%s' tabicl < '%s'"):format(bin, path))
    local ok, reply = pcall(json.decode, r.stdout or "")
    if not ok or type(reply) ~= "table" or reply.error then
      error("tabicl: " .. tostring(ok and type(reply) == "table" and reply.error or r.stderr), 0)
    end
    return reply
  end
  local learn = o.tabicl ~= "off" and require("agent.learn").new{ tabpfn = require("ports.tabicl").new(host),
    tablua = t, memory = { tokens_today = function() return 0 end, called = function() end }, per_run = 1e9,
    step = require("studio.features").learner(t), log = log } or nil

  local connect = o.connect ~= "off" and require("connect").new(cli.root, { store = store }).hooks or nil

  local s = require("studio.session").new{ engine = require("ports.moonsplice").new(host, { bin = bin, tmp = dir }),
    model = m3, judge = jev, learn = learn, tablua = t, comp = o.comp, sheet = dir .. "/sheet.png", ask = o.ask,
    kind = o.kind, exec = host.exec, reference = reference, todo = o.todo, log = log, connect = connect }
  local t0 = os.time()
  local out = s:run()
  log(("[done] %s, %s, after %d steps and %ds: %s"):format(out.stop, out.status, out.steps, os.time() - t0,
    tostring(out.error or out.said or ""):sub(1, 300)))
  local asks = {}
  for _, a in ipairs(out.asks or {}) do
    asks[#asks + 1] = { kind = a.kind, service = a.service, op = a.op, how = a.how }
  end
  print(json.encode({ todo = o.todo, stop = out.stop, status = out.status, steps = out.steps, pass = out.pass,
    sheet = o.sheet, seconds = os.time() - t0, asks = asks, said = out.said,
    error = out.error and tostring(out.error) or nil }))
  return out.status == "complete" and 0 or 1
end

return M
