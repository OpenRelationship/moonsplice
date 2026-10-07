-- Credentials for other people's apps (.robot/docs/connect.robot, "The store"): the macOS keychain, through the
-- `security` command, under the service "moonsplice" with the credential's name as the account
-- (STRIPE_SECRET_KEY), so the editor (Tauri's keyring) and the command line read the same item. The environment is
-- read when the keychain has none. Nothing here writes a credential anywhere else, logs one or returns one to a
-- caller other than the port that signs a call.
--
--   local store = require("connect.store").new{ keychain? }   keychain: a keychain file ($MOONSPLICE_KEYCHAIN in
--                                                               tests), else the login keychain
--   store:get(name) -> value | nil            store:has(name) -> bool
--   store:ask_tty(name, label) -> ok          reads the value from the person's terminal with echo off and hands it
--                                             to `security` on its stdin: never an argument, a file or a log
--   store:set(name, value) -> ok              the same, for a value the caller already holds (a non-secret field)
--   store:forget(name)
local M = {}
local S = {}
S.__index = S

M.service = "moonsplice"

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function ok(r, _, code)
  if type(r) == "number" then return r == 0 end
  return r == true and (code == nil or code == 0)
end

function M.new(o)
  o = o or {}
  local kc = o.keychain or os.getenv("MOONSPLICE_KEYCHAIN")
  return setmetatable({ keychain = kc ~= "" and kc or nil }, S)
end

function S:kc() return self.keychain and (" " .. q(self.keychain)) or "" end

function S:get(name)
  local p = io.popen(("security find-generic-password -s %s -a %s -w%s 2>/dev/null"):format(q(M.service), q(name),
    self:kc()))
  local v = p and p:read("*a") or ""
  if p then p:close() end
  v = v:gsub("\n$", "")
  if v ~= "" then return v end
  local env = os.getenv(name)
  if env and env ~= "" then return env end
  return nil
end

function S:has(name) return self:get(name) ~= nil end

-- `security -i` reads its commands from stdin, so a value never appears in a process's arguments (ps)
local function quoted(v) return '"' .. tostring(v):gsub('[\\"]', "\\%0") .. '"' end

function S:set(name, value, label)
  local p = io.popen("security -i >/dev/null 2>&1", "w")
  if not p then return false end
  p:write(("add-generic-password -U -s %s -a %s -l %s -w %s%s\n"):format(quoted(M.service), quoted(name),
    quoted("Moonsplice: " .. (label or name)), quoted(value), self.keychain and (" " .. quoted(self.keychain)) or ""))
  p:close()
  return self:get(name) == value
end

-- the person types the value at their own terminal with echo off; it goes from here to the keychain and nowhere else
function S:ask_tty(name, label)
  local tty = io.open("/dev/tty", "r")
  if not tty then return false end
  os.execute("stty -echo </dev/tty")
  local v = tty:read("*l")
  os.execute("stty echo </dev/tty")
  tty:close()
  io.write("\n")
  if not v or v == "" then return false end
  return self:set(name, v, label)
end

function S:forget(name)
  return ok(os.execute(("security delete-generic-password -s %s -a %s%s >/dev/null 2>&1"):format(q(M.service),
    q(name), self:kc())))
end

return M
