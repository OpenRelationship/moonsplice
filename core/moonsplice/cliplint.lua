-- Lint's composition rules (core/moonsplice/clip.lua, .robot/docs/rows.robot "Composition"): a clip that never
-- plays, a key outside the local time its clip shows, an overlap with no transition, a transition longer than a
-- clip. Called by core/moonsplice/lint.lua with its `add` and what its frame sampling saw.
--
--   cliplint.run(comp, add, ever_live, dur)    ever_live[clip] = true when some sampled frame showed it
local Clip = require("moonsplice.clip")

local M = {}

function M.run(comp, add, ever_live, dur)
  if comp._clips then
    -- a clip that never plays inside the comp: nothing in it ever shows. Reported on the outermost
    -- such clip; what is inside it is counted, not repeated.
    for _, c in ipairs(comp._clips) do
      if not ever_live[c] and not (c.clock and not ever_live[c.clock]) then
        local inside = 0
        for _, n in ipairs(comp.nodes) do
          local p = n.initial.parent
          while p and p ~= c do p = p.initial.parent end
          if p == c then inside = inside + 1 end
        end
        local a = Clip.to_comp(comp, c, c._start) or c._start
        add("clip_out_of_range", "error", c, 0, dur, nil, nil,
          ("clip %s never plays inside the comp (0..%g s): it runs from %.2f s%s, so the %d %s in it never show%s")
            :format(c.id, dur, a, c._dur and (" for " .. ("%.2f"):format(c._dur) .. " s") or "", inside, inside == 1 and "node" or "nodes",
              inside == 1 and "s" or ""),
          "move its start (or its track's) inside the comp, or lengthen the comp")
      end
    end
    -- a key outside its clip's local range never shows at its own time
    local reported = {}
    for _, g in ipairs(comp.timeline.order) do
      local c = g.node and g.node.clock
      if c and not reported[g] then
        local lo, hi = Clip.range(comp, c)
        for _, seg in ipairs(g.segs) do
          if seg.kind == nil or seg.kind == "step" then
            for _, kt in ipairs({ seg.t0, seg.t1 }) do
              if not reported[g] and (kt < lo - 1e-6 or kt > hi + 1e-6) then
                reported[g] = true
                add("key_outside_clip", "warn", g.node, kt, kt, nil, nil,
                  ("%s.%s has a key at %.2f s (local), but clip %s shows only %.2f..%s s of its time")
                    :format(g.node.id, g.prop, kt, c.id, lo, hi == math.huge and "end" or ("%.2f"):format(hi)),
                  "keys under a clip are in its local time: move the key inside the range, or change the clip's offset, duration or speed")
              end
            end
          end
        end
      end
    end
    for _, tk in ipairs(comp._tracks or {}) do
      for _, c in ipairs(tk._members or {}) do
        if (c._overlap or 0) > 0 and not c._in then
          add("track_overlap", "warn", c, c._start, c._start + c._overlap, c._overlap, 0,
            ("clip %s overlaps the clip before it by %.2f s with no transition: it simply covers it"):format(c.id, c._overlap),
            "give it a transition (crossfade, dip, wipe, push, slide, zoom), or drop the overlap")
        end
        local tin = c._in
        if tin then
          local prev = tin.prev
          local short = (prev._dur and tin.duration > prev._dur) and prev or ((c._dur and tin.duration > c._dur) and c or nil)
          if short then
            add("transition_too_long", "error", c, c._start, c._start + tin.duration, tin.duration, short._dur,
              ("%s into %s lasts %.2f s, longer than clip %s (%.2f s): it would reach past the clip before or after")
                :format(tin.kind, c.id, tin.duration, short.id, short._dur),
              "shorten the transition, or lengthen the clip")
          end
        end
      end
    end
  end
end

return M
