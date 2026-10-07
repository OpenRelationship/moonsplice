-- Lint's audio rules.
-- Part of moonsplice.lint (core/moonsplice/lint/init.lua): L.run calls it with its context, ctx.
local L = require("moonsplice.lint")
local TH = L._.TH

return function(ctx)
  local comp, dur, add, audio = ctx.comp, ctx.dur, ctx.add, ctx.audio
  local ct = ctx.ct
  -- ============ audio rules ============
  local has_audio = #audio > 0
  if has_audio then
    for i, a in ipairs(audio) do
      local ia = a.initial
      if ia.at + (ia.duration or 0) > dur + 0.05 then
        add("audio_tail", "warn", a, dur, ia.at + ia.duration,
          ia.at + ia.duration - dur, 0, "clip extends past comp end (clamped)")
      end
      if a.kind == "tts" then
        for j, b in ipairs(audio) do
          if j > i and b.kind == "tts" then
            local ib = b.initial
            if ia.at < ib.at + ib.duration and ib.at < ia.at + ia.duration then
              add("vo_collision", "error", a, math.max(ia.at, ib.at),
                math.min(ia.at + ia.duration, ib.at + ib.duration), nil, nil,
                "two speech clips overlap")
            end
          end
        end
        -- ducking: beds (music, or long sfx/audio) too loud under speech
        for _, b in ipairs(audio) do
          local ib = b.initial
          local is_bed = b.kind == "music" or ((ib.duration or 0) >= 5 and b ~= a)
          if is_bed and ia.at < ib.at + ib.duration and ib.at < ia.at + ia.duration
            and (ib.volume or 1) > TH.duck_vol then
            add("duck_missing", "warn", b, ia.at, ia.at + ia.duration,
              ib.volume, TH.duck_vol, "bed volume high under speech")
          end
        end
      end
      if a.kind == "sfx" and (ia.duration or 0) < 2 then
        local near = false
        for _, g in ipairs(comp.timeline.order) do
          for _, seg in ipairs(g.segs) do
            local a, b = ct(g.node, seg.t0) or -1, ct(g.node, seg.t1) or -1
            if math.abs(a - ia.at) < 0.25 or math.abs(b - ia.at) < 0.25 then
              near = true break
            end
          end
          if near then break end
        end
        if not near then
          add("sfx_orphan", "info", a, ia.at, ia.at + (ia.duration or 0), nil, nil,
            "sfx hit without a nearby visual beat")
        end
      end
    end
    -- coverage gaps
    local events = {}
    for _, a in ipairs(audio) do
      events[#events + 1] = { t = a.initial.at, d = 1 }
      events[#events + 1] = { t = a.initial.at + (a.initial.duration or 0), d = -1 }
    end
    table.sort(events, function(x, y) return x.t < y.t end)
    local depth, last_end = 0, 0
    for _, ev in ipairs(events) do
      if depth == 0 and ev.d == 1 and ev.t - last_end > TH.gap_span and last_end > 0 then
        add("audio_gap", "info", nil, last_end, ev.t, ev.t - last_end, TH.gap_span,
          "silence gap in a comp with audio")
      end
      depth = depth + ev.d
      if depth == 0 then last_end = ev.t end
    end
  end
end
