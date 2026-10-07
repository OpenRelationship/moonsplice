-- moonsplice connect: other people's apps through connectory (.robot/docs/connect.robot, "The command line").
--
--   connect SERVICE                 connect it: asks for each missing field, a secret without echo (`security`
--                                   reads it, so it never passes through here); needs the person's own terminal
--   connect --list | --asks         the connections, and what agents are waiting on the person for, as rows
--   connect --find WORDS... | --calls SERVICE [WORDS...] | --needs SERVICE     the directory
--   connect --check SERVICE         the directory's own test call, signed with the person's credential
--   connect --approve SERVICE OP [--once | --always | --deny]    the person's answer to a call that changes something;
--                                   needs the person's own terminal, so an agent cannot approve its own call
--   connect --call OP [ARGS.json]   one call, for an agent driving the command line: the same rules as a run's
--   connect --record SERVICE        the app stored the fields itself: check they are there and record it
--   connect --approve SERVICE OP --from-app --once|--always|--deny   the app's own path for the person's answer (the
--                                   app is their interface); like every file here, an agent with a shell could
--                                   reach it, so the terminal check guards the default path, not a boundary
--   connect --forget SERVICE
-- --json prints rows. With no terminal (an agent is driving), `connect SERVICE` and `--approve` print what the
-- person must do and exit 3: a credential or an approval never comes from an agent.
local json = require("ports.json")

local M = {}

-- the person's own terminal: stdin and stdout both a tty (an agent's shell has neither)
local function tty()
  local r = os.execute("[ -t 0 ] && [ -t 1 ]")
  return r == 0 or r == true
end

local function out(rows, as_json, text)
  if as_json then print(json.encode(rows)) else print(text) end
  return 0
end

local function arg_list(args)
  local o, rest = { json = false }, {}
  for _, a in ipairs(args) do
    local flag = a:match("^%-%-(.+)$")
    if flag then o[flag] = true else rest[#rest + 1] = a end
  end
  return o, rest
end

local function refuse(what)
  io.stderr:write(("moonsplice connect: %s needs the person at their own terminal; an agent cannot give it. Ask "
    .. "them to run this themselves, or to use Connections in the Moonsplice app:\n  ./moonsplice connect %s\n")
    :format(what.why, what.command))
  return 3
end

local function connect_one(C, service)
  local need = C.port:needs(service)
  if not need then io.stderr:write("moonsplice connect: no service called " .. service .. "\n") return 2 end
  if not tty() then return refuse({ why = "connecting " .. need.name, command = service }) end
  print(("Connecting %s. Its documentation says where to get each value: %s"):format(need.name, tostring(need.docs)))
  local missing = {}
  for _, m in ipairs(need.missing) do missing[m] = true end
  for _, f in ipairs(need.fields) do
    if missing[f.name] then
      if f.secret then
        io.write(("%s %s (not shown as you type): "):format(need.name, f.label))
        io.flush()
        if not C.store:ask_tty(f.name, need.name .. " " .. f.label) then
          io.stderr:write("moonsplice connect: the keychain did not store " .. f.name .. "\n")
          return 1
        end
      else
        io.write(("%s %s: "):format(need.name, f.label))
        io.flush()
        local v = io.read("*l")
        if not v or v == "" then io.stderr:write("moonsplice connect: nothing given for " .. f.name .. "\n") return 1 end
        C.store:set(f.name, v)
      end
    end
  end
  return M.record(C, service, false)
end

function M.record(C, service, as_json)
  local need = C.port:needs(service)
  if not need then io.stderr:write("moonsplice connect: no service called " .. service .. "\n") return 2 end
  if #need.missing > 0 then
    io.stderr:write(("moonsplice connect: %s still lacks %s\n"):format(need.name, table.concat(need.missing, ", ")))
    return 1
  end
  local names = {}
  for _, f in ipairs(need.fields) do names[#names + 1] = f.name end
  C.state:connected(service, names)
  local ok, err = C.port:check(service)
  local checked = ok and "the test call passed" or (err and err.code == "not_found" and "no test call is known"
    or ("the test call failed: " .. tostring(err and err.message)))
  return out({ service = service, fields = names, checked = ok and true or false }, as_json,
    ("%s is connected (%s)."):format(need.name, checked))
end

local function approve(C, o, service, op)
  if not (service and op) then io.stderr:write("usage: moonsplice connect --approve SERVICE OP\n") return 2 end
  local answer = o.always and "always" or o.deny and "deny" or o.once and "once"
  if o["from-app"] then
    if not answer then io.stderr:write("moonsplice connect: --from-app needs --once, --always or --deny\n") return 2 end
  elseif not tty() then
    return refuse({ why = "approving " .. op, command = ("--approve %s %s"):format(service, op) })
  end
  if not answer then
    local method = C.port:method(op) or "?"
    io.write(("Let agents run %s %s? [o]nce, [a]lways, [d]eny: "):format(method, op))
    io.flush()
    local r = (io.read("*l") or ""):lower():sub(1, 1)
    answer = r == "o" and "once" or r == "a" and "always" or "deny"
  end
  C.state:approve(service, op, answer)
  return out({ service = service, op = op, answer = answer }, o.json, ("%s: %s"):format(op, answer))
end

-- one call for an agent at the command line: what a run's connect tool does, with the same asks
local function call(C, o, op, file)
  local args = {}
  if file then
    local f = assert(io.open(file), "cannot read " .. file)
    args = json.decode(f:read("*a"))
    f:close()
  end
  local service = op:match("^([^.]+)%.")
  local method = C.port:method(op)
  if not method then io.stderr:write("moonsplice connect: no call is named " .. op .. "\n") return 2 end
  local function waiting(a, code)
    C.state:ask(a)
    return out({ waiting = a.kind, service = service, op = op, how = C.how(a) }, o.json,
      ("Waiting on the person: %s."):format(C.how(a))) and code
  end
  if not C.port:reads(op) then
    local answer = C.state:approval(service, op)
    if answer == "deny" then
      return out({ denied = op }, o.json, "The person declined " .. op .. ".") and 4
    elseif answer ~= "once" and answer ~= "always" then
      return waiting({ kind = "approve", service = service, op = op, method = method }, 4)
    end
  end
  local value, err = C.port:call(op, args)
  if value == nil then
    if err.needs then
      return waiting({ kind = "connect", service = service, name = err.needs.name, fields = err.needs.fields,
        docs = err.needs.docs }, 4)
    end
    io.stderr:write(("moonsplice connect: %s: %s\n"):format(err.code or "error", err.message or "the call failed"))
    return 1
  end
  return out({ value = value, record = err }, o.json, json.encode(value))
end

function M.run(cli, args)
  local C = require("connect").new(cli.root)
  local o, rest = arg_list(args)
  if o.list then
    local rows = C.state:connections()
    local lines = {}
    for _, r in ipairs(rows) do lines[#lines + 1] = ("%s (%s), connected %s"):format(r.service,
      table.concat(r.fields or {}, ", "), r.at) end
    return out(rows, o.json, #lines > 0 and table.concat(lines, "\n") or "Nothing is connected.")
  elseif o.asks then
    local rows = C.state:asks(true)
    local lines = {}
    for _, r in ipairs(rows) do lines[#lines + 1] = ("%s: %s"):format(r.id, C.how(r)) end
    return out(rows, o.json, #lines > 0 and table.concat(lines, "\n") or "No agent is waiting on you.")
  elseif o.find then
    local rows = C.port:find(table.concat(rest, " "), 10)
    local lines = {}
    for _, r in ipairs(rows) do lines[#lines + 1] = ("%s  %s, %d calls"):format(r.service, r.name, r.operations or 0) end
    return out(rows, o.json, table.concat(lines, "\n"))
  elseif o.calls then
    local rows, why = C.port:operations(rest[1], table.concat(rest, " ", 2), 15)
    if not rows then io.stderr:write(why .. "\n") return 1 end
    local lines = {}
    for _, r in ipairs(rows) do lines[#lines + 1] = ("%s  %s (%s)"):format(r.op, r.name, table.concat(r.args, ", ")) end
    return out(rows, o.json, table.concat(lines, "\n"))
  elseif o.needs then
    local need = C.port:needs(rest[1] or "")
    if not need then io.stderr:write("no service called " .. tostring(rest[1]) .. "\n") return 2 end
    return out(need, o.json, json.encode(need))
  elseif o.check then
    local ok, err = C.port:check(rest[1] or "")
    return out({ service = rest[1], ok = ok and true or false, error = err }, o.json,
      ok and "The test call passed." or ("The test call failed: " .. tostring(err and err.message))) and (ok and 0 or 1)
  elseif o.approve then
    return approve(C, o, rest[1], rest[2])
  elseif o.call then
    return call(C, o, rest[1] or "", rest[2])
  elseif o.record then
    return M.record(C, rest[1] or "", o.json)
  elseif o.forget then
    local need = C.port:needs(rest[1] or "")
    for _, f in ipairs(need and need.fields or {}) do C.store:forget(f.name) end
    C.state:forget(rest[1] or "")
    print((rest[1] or "") .. " is forgotten.")
    return 0
  elseif rest[1] then
    return connect_one(C, rest[1])
  end
  io.stderr:write("usage: moonsplice connect SERVICE | --list | --asks | --find WORDS | --calls SERVICE | --check "
    .. "SERVICE | --approve SERVICE OP | --call OP [ARGS.json] | --forget SERVICE\n")
  return 2
end

return M
