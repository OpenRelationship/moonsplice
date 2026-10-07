-- What Moonsplice knows about the person's connections, as rows (.robot/docs/connect.robot, "Connections and calls
-- are rows"): the asks an agent raised, the person's approvals and the services connected, kept in one JSON file
-- outside every project ($MOONSPLICE_STATE/connect.json, else ~/.moonsplice/connect.json). Names only: no row
-- holds a credential.
--
--   local st = require("connect.state").open(dir?)
--   st:ask(a) -> row, new          a = { kind = "connect" | "approve", service, name?, op?, method?, fields?, docs?,
--                                  why? }; an open ask of the same kind, service and op is returned, not repeated
--   st:asks(open_only?) -> rows    st:settle(kind, service, op?, status)   status "done" | "denied"
--   st:approve(service, op, answer)  answer "once" | "always" | "deny"
--   st:approval(service, op) -> "once" | "always" | "deny" | nil    a "once" is used up by the call it allows
--   st:connected(service, fields, name?)  st:forget(service)  st:connections() -> rows
local json = require("ports.json")

local M = {}
local S = {}
S.__index = S

function M.dir()
  local d = os.getenv("MOONSPLICE_STATE")
  if d and d ~= "" then return d end
  return (os.getenv("HOME") or ".") .. "/.moonsplice"
end

function M.open(dir)
  local s = setmetatable({ path = (dir or M.dir()) .. "/connect.json", dir = dir or M.dir() }, S)
  s:load()
  return s
end

function S:load()
  local f = io.open(self.path)
  local ok, d = false, nil
  if f then ok, d = pcall(json.decode, f:read("*a")); f:close() end
  d = ok and type(d) == "table" and d or {}
  self.rows = { ask = d.ask or {}, approval = d.approval or {}, connection = d.connection or {} }
end

function S:save()
  os.execute("mkdir -p '" .. self.dir:gsub("'", "'\\''") .. "'")
  local tmp = self.path .. ".tmp"
  local f = assert(io.open(tmp, "w"))
  f:write(json.encode(self.rows))
  f:close()
  os.rename(tmp, self.path)
end

local function now() return os.date("!%Y-%m-%dT%H:%M:%SZ") end

function S:ask(a)
  self:load()
  for _, r in ipairs(self.rows.ask) do
    if r.status == "open" and r.kind == a.kind and r.service == a.service and (r.op or "") == (a.op or "") then
      return r, false
    end
  end
  local fields = {}
  for _, f in ipairs(a.fields or {}) do fields[#fields + 1] = { name = f.name, label = f.label, secret = f.secret } end
  local r = { id = ("%s-%s-%d"):format(a.kind, a.service, #self.rows.ask + 1), kind = a.kind, service = a.service,
    name = a.name, op = a.op, method = a.method, fields = fields, docs = a.docs, why = a.why, at = now(),
    status = "open" }
  self.rows.ask[#self.rows.ask + 1] = r
  self:save()
  return r, true
end

function S:asks(open_only)
  self:load()
  local out = {}
  for _, r in ipairs(self.rows.ask) do if not open_only or r.status == "open" then out[#out + 1] = r end end
  return out
end

function S:settle(kind, service, op, status)
  self:load()
  for _, r in ipairs(self.rows.ask) do
    if r.status == "open" and r.kind == kind and r.service == service and (op == nil or (r.op or "") == op) then
      r.status, r.settled = status or "done", now()
    end
  end
  self:save()
end

function S:approve(service, op, answer)
  assert(answer == "once" or answer == "always" or answer == "deny", "answer is once, always or deny")
  self:load()
  self.rows.approval[#self.rows.approval + 1] = { service = service, op = op, answer = answer, at = now() }
  self:save()
  self:settle("approve", service, op, answer == "deny" and "denied" or "done")
end

-- the newest answer for this call stands; a once is used by the call it lets through
function S:approval(service, op)
  self:load()
  for i = #self.rows.approval, 1, -1 do
    local r = self.rows.approval[i]
    if r.service == service and (r.op == op or r.op == "*") and not r.used then
      if r.answer == "once" then r.used = now(); self:save() end
      return r.answer
    end
  end
  return nil
end

function S:connected(service, fields, name)
  self:load()
  local kept = {}
  for _, r in ipairs(self.rows.connection) do if r.service ~= service then kept[#kept + 1] = r end end
  kept[#kept + 1] = { service = service, name = name, fields = fields, at = now() }
  self.rows.connection = kept
  self:save()
  self:settle("connect", service, nil, "done")
end

function S:forget(service)
  self:load()
  local kept = {}
  for _, r in ipairs(self.rows.connection) do if r.service ~= service then kept[#kept + 1] = r end end
  self.rows.connection = kept
  self:save()
end

function S:connections()
  self:load()
  return self.rows.connection
end

return M
