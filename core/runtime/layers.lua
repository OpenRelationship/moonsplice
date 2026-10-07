-- Layers (core/moonsplice/clip.lua, .robot/docs/rows.robot "Composition"): which nodes the painter draws as
-- one picture, worked out once per comp, and the questions the painter asks of that plan as it walks.
-- No drawing here: core/runtime/painter.lua paints a layer (paint_layer) from this plan.
--
--   layers.plan(comp) -> plan or nil      { layer, matte_src, owner, members }; nil when the comp has none
--   layers.live(node)                     whether every clip around it plays this frame
--   layers.within(a, b)                   whether a is somewhere under b
--   layers.opacity_from(comp, chain)      where the opacity product over a parent chain starts
--   layers.fx_paints(comp, child, fx)     whether an fx node paints this child itself
local M = {}

-- A layer paints its subtree as one picture and composites it once, with its opacity, blend,
-- effects and matte: a clip, precomp or track (unless isolate = false), a group with isolate = true,
-- anything with a matte, a matte's source, and every clip a transition touches. Worked out once per
-- comp; a comp with none gets nil, and then every frame paints exactly as it did before.
function M.plan(comp)
  if comp._plan ~= nil then return comp._plan or nil end
  local Clip = require("moonsplice.clip")
  local layer, matte_src, any = {}, {}, false
  for _, n in ipairs(comp.nodes) do
    if n.initial.matte then matte_src[n.initial.matte] = true end
  end
  for _, n in ipairs(comp.nodes) do
    if Clip.isolated(n) or n.initial.matte or matte_src[n] or n._in or n._out then layer[n] = true; any = true end
  end
  if not any then comp._plan = false; return nil end
  -- each node's nearest layer above it paints it, in comp order
  local owner, members = {}, {}
  for _, n in ipairs(comp.nodes) do
    local p = n.initial.parent
    while p and not layer[p] do p = p.initial.parent end
    if p then
      owner[n] = p
      members[p] = members[p] or {}
      table.insert(members[p], n)
    end
  end
  comp._plan = { layer = layer, matte_src = matte_src, owner = owner, members = members }
  return comp._plan
end

-- whether a is somewhere under b
function M.within(a, b)
  local p = a.initial and a.initial.parent
  while p do
    if p == b then return true end
    p = p.initial and p.initial.parent
  end
  return false
end

-- a node shows only while every clip around it (and the node itself, when it is one) plays
function M.live(node)
  local c = node.clock
  if c and not c._live then return false end
  return node._live ~= false
end

-- the chain index the opacity product starts at: a layer above already applied what is above it
function M.opacity_from(comp, chain)
  local plan = comp._plan
  if plan then
    for k = #chain, 1, -1 do if plan.layer[chain[k]] then return k + 1 end end
  end
  return 1
end

-- a child an fx node paints itself: not one a layer inside the fx paints, nor a matte's source
function M.fx_paints(comp, child, fx)
  local plan = comp._plan
  if not plan then return true end
  if plan.matte_src[child] then return false end
  local o = plan.owner[child]
  return not (o and o ~= fx and M.within(o, fx))
end

return M
