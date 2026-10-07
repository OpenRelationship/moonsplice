-- Moonsplice as the host of connectory's port (.robot/docs/connect.robot): it gives the port its fetch (Tablua's
-- curl, the key only ever in a header), the directory's files (submodules/connectory, or $MOONSPLICE_CONNECTORY) and
-- secret(name) from the store; and it gives a Tablua run (studio.connect) the two hooks that reach the person:
-- ask, which records what the agent needs as a row the app and the command line show, and approval, which reads the
-- person's answer.
--
--   local C = require("connect").new(root, { store?, state?, fetch?, connectory? })
--   C.port                         connectory's connect port
--   C.hooks -> { port, ask, approval }   studio.session's connect option
--   C.how(ask) -> text             what the model and whoever drives the run are told the person must do
local M = {}

function M.new(root, o)
  o = o or {}
  local store = o.store or require("connect.store").new()
  local state = o.state or require("connect.state").open()
  local base = o.connectory or os.getenv("MOONSPLICE_CONNECTORY")
  base = (base and base ~= "") and base or (root .. "/submodules/connectory")
  local function read(path)
    local f = io.open(base .. "/" .. path, "rb")
    if not f then return nil end
    local s = f:read("*a")
    f:close()
    return s
  end
  local fetch = o.fetch or require("ports.curl").fetch
  local port = require("connectory.lua.connect").new({ fetch = fetch, now = os.time },
    { read = read, secret = function(name) return store:get(name) end })

  local C = { port = port, store = store, state = state, root = root }

  function C.how(a)
    if a.kind == "approve" then
      return ("the person approves it in the Moonsplice app, or runs `./moonsplice connect --approve %s %s` in "
        .. "their own terminal"):format(a.service, a.op)
    end
    return ("the person connects %s in the Moonsplice app (Connections), or runs `./moonsplice connect %s` in "
      .. "their own terminal"):format(a.name or a.service, a.service)
  end

  C.hooks = {
    port = port,
    ask = function(a)
      state:ask(a)
      return { how = C.how(a) }
    end,
    approval = function(service, op) return state:approval(service, op) end,
  }
  return C
end

return M
