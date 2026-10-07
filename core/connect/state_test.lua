-- connect.state: an ask is raised once while open and settled by its answer; a "once" approval lets one call through,
-- "always" every one, the newest answer stands; a connection settles its ask; nothing in the rows is a value.
local spec = require("spec")
local state = require("connect.state")

local function fresh()
  local dir = io.popen("mktemp -d"):read("*l")
  return state.open(dir), dir
end

spec.test("an open ask is raised once, and its answer settles it", function()
  local st = fresh()
  local a, new = st:ask({ kind = "connect", service = "acme", name = "Acme", fields = { { name = "ACME_TOKEN",
    label = "token", secret = true } }, docs = "https://acme.test" })
  spec.ok(new)
  local b, again = st:ask({ kind = "connect", service = "acme" })
  spec.same({ again, b.id }, { false, a.id })
  spec.eq(#st:asks(true), 1)
  st:connected("acme", { "ACME_TOKEN" })
  spec.eq(#st:asks(true), 0)
  spec.same({ #st:connections(), st:connections()[1].fields[1] }, { 1, "ACME_TOKEN" })
end)

spec.test("once lets one call through, always every one, and the newest answer stands", function()
  local st = fresh()
  st:ask({ kind = "approve", service = "acme", op = "acme.create" })
  spec.eq(st:approval("acme", "acme.create"), nil)
  st:approve("acme", "acme.create", "once")
  spec.eq(#st:asks(true), 0)
  spec.eq(st:approval("acme", "acme.create"), "once")
  spec.eq(st:approval("acme", "acme.create"), nil)
  st:approve("acme", "acme.create", "always")
  spec.eq(st:approval("acme", "acme.create"), "always")
  spec.eq(st:approval("acme", "acme.create"), "always")
  st:approve("acme", "acme.create", "deny")
  spec.eq(st:approval("acme", "acme.create"), "deny")
  spec.err(function() st:approve("acme", "acme.create", "maybe") end, "once, always or deny")
end)

spec.test("the rows survive a reopen", function()
  local st, dir = fresh()
  st:approve("acme", "acme.create", "always")
  spec.eq(state.open(dir):approval("acme", "acme.create"), "always")
end)

spec.run()
