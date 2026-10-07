-- Lint's motion rules (density, rest, frozen spans) and its segment-metadata rules (overshoot, first motion,
-- ease monoculture, flash cuts, staggers).
-- Part of moonsplice.lint (core/moonsplice/lint/init.lua): L.run calls it with its context, ctx.
local L = require("moonsplice.lint")
local TH, MOVING_CONTENT = L._.TH, L._.MOVING_CONTENT

return function(ctx)
  local comp, fps, dur, n_samples = ctx.comp, ctx.fps, ctx.dur, ctx.n_samples
  local add, visual, audio = ctx.add, ctx.visual, ctx.audio
  local ct, states, amp = ctx.ct, ctx.states, ctx.amp
  -- ============ motion rules ============
  local bucket = math.floor(fps / 2) -- 0.5s buckets
  local worst_density, worst_bt = 0, 0
  local rest_run, max_no_rest_start = 0, nil
  local no_rest_since = 0
  for b = 0, math.floor((n_samples - 2) / bucket) do
    local sum = 0
    local big = {}
    for s = b * bucket + 1, math.min((b + 1) * bucket, n_samples - 1) do
      for n, d in pairs(amp[s] or {}) do
        sum = sum + d
        big[n] = (big[n] or 0) + d
      end
    end
    local t0 = b * 0.5
    if sum > worst_density then worst_density, worst_bt = sum, t0 end
    if sum > TH.motion_density then
      add("motion_density", "warn", nil, t0, t0 + 0.5, sum, TH.motion_density,
        ("motion amplitude %.2f in bucket"):format(sum))
    end
    local nbig = 0
    for _, d in pairs(big) do if d > TH.competing_amp then nbig = nbig + 1 end end
    if nbig >= 3 then
      add("competing_beats", "warn", nil, t0, t0 + 0.5, nbig, 3,
        nbig .. " nodes with large simultaneous motion")
    elseif nbig == 2 then
      add("competing_beats", "info", nil, t0, t0 + 0.5, 2, 3,
        "two large motions share this beat")
    end
    -- wall of motion: track rest buckets (density < 0.5)
    if sum < 0.5 then
      no_rest_since = t0 + 0.5
    elseif t0 + 0.5 - no_rest_since > TH.wall_span then
      add("wall_of_motion", "info", nil, no_rest_since, t0 + 0.5,
        t0 + 0.5 - no_rest_since, TH.wall_span, "no rest beat in span")
      no_rest_since = t0 + 0.5 -- report once per span
    end
  end

  -- frozen spans: visible nodes but ~zero total motion
  local frozen_start = nil
  -- A clip is playing / someone is talking: a held frame is then a choice, not a fault.
  local function content_moves(s, t)
    for _, n in ipairs(visual) do
      if MOVING_CONTENT[n.kind] then
        local st = states[s][n]
        local i = n.initial
        local from, len = i.from or 0, i.duration or (dur - (i.from or 0))
        local lt = st and st.lt or t
        if st and st.vis and lt >= from and lt < from + len then return true end
      end
    end
    for _, n in ipairs(audio) do
      local i = n.initial
      local at, len = i.at or 0, i.duration
      if t >= at and (len == nil or t < at + len) then return true end
    end
    return false
  end
  for s = 1, n_samples - 1 do
    local total, any_vis = 0, false
    for _, n in ipairs(visual) do
      local st = states[s][n]
      if st and st.vis then any_vis = true end
    end
    for _, d in pairs(amp[s] or {}) do total = total + d end
    local t = s / fps
    if any_vis and total < 0.002 and content_moves(s, t) then
      -- not frozen: something on screen or in the mix is moving on its own
      if frozen_start and t - frozen_start > TH.frozen_span then
        add("frozen_span", "info", nil, frozen_start, t, t - frozen_start, TH.frozen_span,
          "no tweens here, but a clip or narration is running")
      end
      frozen_start = nil
    elseif any_vis and total < 0.002 then
      frozen_start = frozen_start or t
    else
      if frozen_start and t - frozen_start > TH.frozen_span then
        add("frozen_span", (t - frozen_start > TH.frozen_error) and "error" or "warn",
          nil, frozen_start, t, t - frozen_start, TH.frozen_span, "visible but static")
      end
      frozen_start = nil
    end
  end
  if frozen_start and dur - frozen_start > TH.frozen_span then
    add("frozen_span", (dur - frozen_start > TH.frozen_error) and "error" or "warn",
      nil, frozen_start, dur, dur - frozen_start, TH.frozen_span, "visible but static")
  end

  -- ============ segment-metadata rules ============
  local total_tweens, overshoot_tweens = 0, 0
  local first_motion = math.huge
  local ease_windows = {} -- list of {t0, ease_id}
  local sets = {}
  local overshoot_reported = {} -- dedupe stagger swarms: one finding per beat
  for _, g in ipairs(comp.timeline.order) do
    for _, seg0 in ipairs(g.segs) do
      -- under a clip a segment's times are local: these rules are about when it plays
      local seg = seg0
      if g.node and g.node.clock then
        local a, b = ct(g.node, seg0.t0), ct(g.node, seg0.t1)
        seg = setmetatable({ t0 = a or -1, t1 = b or -1 }, { __index = seg0 })
        if not (a and b) then seg = { kind = "unplaced" } end
      end
      if not seg.kind then -- plain tween/set
        if seg.t1 > seg.t0 then
          total_tweens = total_tweens + 1
          if seg.overshoot then
            overshoot_tweens = overshoot_tweens + 1
            if g.prop == "opacity" then
              local key = ("op|%d"):format(math.floor(seg.t0 * 2))
              if not overshoot_reported[key] then
                overshoot_reported[key] = true
                add("overshoot_on_opacity", "error", g.node, seg.t0, seg.t1, nil, nil,
                  "overshoot ease on opacity (" .. seg.ease_id .. ") — opacity exceeds 1 then clamps; use a smooth ease")
              end
            end
          end
          if seg.t0 < first_motion then first_motion = seg.t0 end
          -- collapse stagger members: one stagger call = one ease "use"
          local in_stagger = false
          for _, st in ipairs(comp.timeline.staggers or {}) do
            if seg.t0 >= st.t0 - 0.001 and seg.t0 <= st.t0 + st.span + 0.001 then
              in_stagger = st
              break
            end
          end
          if in_stagger then
            local key = tostring(in_stagger) .. seg.ease_id
            if not ease_windows[key] then
              ease_windows[key] = true
              ease_windows[#ease_windows + 1] = { t0 = in_stagger.t0, id = seg.ease_id }
            end
          else
            ease_windows[#ease_windows + 1] = { t0 = seg.t0, id = seg.ease_id }
          end
          -- subpixel drift
          -- (a mesh or light lives in a world: its x, y are world units, not pixels)
          if (g.prop == "x" or g.prop == "y") and type(seg.to) == "number"
            and not (g.node and (g.node.kind == "mesh" or g.node.kind == "light"))
            and math.abs(seg.to - seg.from) < TH.subpixel and seg.t1 - seg.t0 > 0.5 then
            add("subpixel_drift", "info", g.node, seg.t0, seg.t1,
              math.abs(seg.to - seg.from), TH.subpixel, "imperceptible move on " .. g.prop)
          end
        else
          sets[#sets + 1] = seg.t0
        end
      end
    end
  end
  if total_tweens > 0 and overshoot_tweens / total_tweens > TH.overshoot_budget then
    add("overshoot_budget", "info", nil, 0, dur,
      overshoot_tweens / total_tweens, TH.overshoot_budget,
      ("%d/%d tweens use overshoot eases"):format(overshoot_tweens, total_tweens))
  end
  if first_motion < 0.05 and first_motion ~= math.huge then
    add("cold_open", "warn", nil, 0, 0.3, first_motion, 0.1,
      "first motion at t=0 reads as a jump cut; offset 0.1-0.3s")
  end
  -- ease monoculture: same ease id > N times within any 2s window
  table.sort(ease_windows, function(a, b) return a.t0 < b.t0 end)
  local reported_ease = {}
  for i = 1, #ease_windows do
    local counts = {}
    for j = i, #ease_windows do
      if ease_windows[j].t0 - ease_windows[i].t0 > 2 then break end
      local id = ease_windows[j].id
      counts[id] = (counts[id] or 0) + 1
      if counts[id] > TH.ease_repeat and id ~= "linear" and not reported_ease[id .. math.floor(ease_windows[i].t0)] then
        reported_ease[id .. math.floor(ease_windows[i].t0)] = true
        add("ease_monoculture", "info", nil, ease_windows[i].t0, ease_windows[i].t0 + 2,
          counts[id], TH.ease_repeat, ("ease %q used %d times in 2s"):format(id, counts[id]))
      end
    end
  end
  -- flash cut rate
  table.sort(sets)
  for i = 1, #sets do
    local c = 1
    for j = i + 1, #sets do
      if sets[j] - sets[i] <= 1.0 then c = c + 1 else break end
    end
    if c > TH.flash_rate then
      add("flash_cut_rate", "warn", nil, sets[i], sets[i] + 1, c, TH.flash_rate,
        c .. " instant sets within 1s")
      break
    end
  end
  -- stagger spans
  for _, st in ipairs(comp.timeline.staggers or {}) do
    if st.span > TH.stagger_span then
      add("stagger_runaway", "warn", nil, st.t0, st.t0 + st.span, st.span,
        TH.stagger_span, ("stagger spreads %.2fs over %d items"):format(st.span, st.n))
    end
  end
end
