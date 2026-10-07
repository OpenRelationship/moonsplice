-- The ask as predicates: each expect row checked against the comp.
-- Part of moonsplice.lint (core/moonsplice/lint/init.lua): L.run calls it with its context, ctx.
local L = require("moonsplice.lint")
local Clip, same, shown = L._.Clip, L._.same, L._.shown

return function(ctx)
  local comp, fps, dur, add = ctx.comp, ctx.fps, ctx.dur, ctx.add
  local at = ctx.at
  -- ============ expect: the ask as predicates (ROWS.md, "Expectations") ============
  -- { id, says, node, prop?, op?, value?, at? | t0?, t1?, holds = "always"|"ever" }. A node alone must
  -- exist. With a prop, its value at `at` (or over t0..t1, sampled at fps) must satisfy op value.
  if comp.expect and #comp.expect > 0 then
    local byid = {}
    for _, n in ipairs(comp.nodes or {}) do if n.id then byid[n.id] = n end end
    local OPS = {
      ["=="] = function(a, b) return same(a, b) end, ["~="] = function(a, b) return not same(a, b) end,
      [">"] = function(a, b) return type(a) == "number" and a > b end,
      [">="] = function(a, b) return type(a) == "number" and a >= b end,
      ["<"] = function(a, b) return type(a) == "number" and a < b end,
      ["<="] = function(a, b) return type(a) == "number" and a <= b end,
      has = function(a, b) return type(a) == "string" and a:find(b, 1, true) ~= nil end,
    }
    local function fail(x, measured, t0, t1, why)
      local num = function(v) return type(v) == "number" and v or nil end
      add("expect_failed", "error", x.node and { id = x.node } or nil, t0 or 0, t1 or dur, num(measured), num(x.value),
        ("%s: %s (expect %s)"):format(x.says or x.id, why, x.id),
        "the ask requires this; do not remove or hide what it names, make it true")
    end
    for _, x0 in ipairs(comp.expect) do
      local x = x0
      -- a precomp's expectations are in its local time: each time read at the comp time it plays
      if x0.clock then
        x = {}
        for k, v in pairs(x0) do x[k] = v end
        for _, k in ipairs({ "at", "t0", "t1" }) do
          if x0[k] ~= nil then x[k] = Clip.comp_time(comp, x0.clock, x0[k]) or -1 end
        end
        if x.t0 and x.t1 and x.t1 < x.t0 then x.t0, x.t1 = x.t1, x.t0 end
        if x0.at and x.at < 0 then x.at = nil; x.unplaced = true end
      end
      local n = x.node and byid[x.node]
      if x.unplaced then
        fail(x, nil, 0, dur, ("precomp %s never shows its local %.2f s"):format(tostring(x0.clock.id), x0.at))
      elseif x.node and not n then
        fail(x, nil, 0, dur, ("node %s does not exist"):format(x.node))
      elseif n and x.prop then
        local op = OPS[x.op or "=="]
        if not op then
          fail(x, nil, 0, dur, ("op %s is not one of == ~= > >= < <= has"):format(tostring(x.op)))
        else
          local ts = {}
          if x.at then ts[1] = x.at
          else
            local a0, a1 = x.t0 or 0, x.t1 or dur
            for k = 0, math.floor((a1 - a0) * fps + 1e-6) do ts[#ts + 1] = a0 + k / fps end
          end
          local ever, bad, badv = false, nil, nil
          for _, t in ipairs(ts) do
            at(math.min(t, dur))
            local v = n.state[x.prop]; if v == nil then v = n.initial[x.prop] end
            if op(v, x.value) then ever = true elseif not bad then bad, badv = t, v end
          end
          if x.holds == "ever" then
            if not ever then fail(x, badv, ts[1], ts[#ts], ("%s never %s %s"):format(x.prop, x.op or "==", shown(x.value))) end
          elseif bad then
            fail(x, type(badv) == "number" and badv or nil, bad, bad,
              ("%s is %s at %.2f s, needs %s %s"):format(x.prop, shown(badv), bad, x.op or "==", shown(x.value)))
          end
        end
      end
    end
  end
end
