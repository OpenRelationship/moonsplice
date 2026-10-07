-- Part of moonsplice.rows (core/moonsplice/rows/init.lua): see its head for the module's contract.
-- A precomp (.robot/docs/rows.robot, "Composition") is a clip of another rows comp. R.scene builds its nodes
-- again under the instance as <instance>/<id>; this part opens the comp it names, through the host's
-- load_rows hook (core/runtime/resolve.lua), so core/moonsplice stays host-free.
local R = require("moonsplice.rows")

-- The rows a precomp node names, and their file: `p` is the node's props (length, w and h default from
-- the inner comp), `stack` the files being built around it, so a precomp that includes itself is an
-- error rather than a hang.
function R._.open_precomp(s, id, p, stack)
  if type(p.src) ~= "string" then error(("moonsplice rows: precomp %s needs src (a rows comp file)"):format(id), 0) end
  if not s._load_rows then error("moonsplice rows: this host loads no precomps", 0) end
  local inner, path = s._load_rows(p.src, stack[#stack])
  for _, f in ipairs(stack) do
    if f == path then error(("moonsplice rows: precomp %s includes %s, which includes itself"):format(id, path), 0) end
  end
  local game = next(inner.game) or #inner.input > 0
  for _, sys in ipairs(inner.system) do if sys.name:match("^game%.") then game = true end end
  if game then
    error(("moonsplice rows: precomp %s: %s is a game; a game's time is its simulation and cannot be a clip"):format(id, path), 0)
  end
  -- what a precomp is, from its comp: how long it runs (and loops over) and the box it is clipped to
  p.length = p.length or inner.comp.duration
  p.w, p.h = p.w or inner.comp.width, p.h or inner.comp.height
  return inner, path
end
