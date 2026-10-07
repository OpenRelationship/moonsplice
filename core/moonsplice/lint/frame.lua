-- Lint's rules on the frame: geometry (bounds, safe area, overlap, size) and colour (contrast against the
-- background, palette size, the brand's palette).
-- Part of moonsplice.lint (core/moonsplice/lint/init.lua): L.run calls it with its context, ctx.
local L = require("moonsplice.lint")
local color, TH, contrast_ratio, oklab_dist = L._.color, L._.TH, L._.contrast_ratio, L._.oklab_dist

return function(ctx)
  local comp, opts, fps, dur = ctx.comp, ctx.opts, ctx.fps, ctx.dur
  local n_samples, add, visual, at = ctx.n_samples, ctx.add, ctx.visual, ctx.at
  local states = ctx.states
  -- ============ geometry rules ============
  for _, n in ipairs(visual) do
    local min_size_worst, unsafe_worst = nil, nil
    -- onscreen/offscreen life analysis (HF discipline: hard-kill exits, park at
    -- opacity 0 — being visible while fully off-canvas is either waste or a bug)
    local first_on, last_on, visible_ever, last_vis = nil, nil, false, nil
    for s = 0, n_samples - 1 do
      local st = states[s][n]
      if st and st.vis then
        visible_ever = true
        last_vis = s / fps
        if st.bx0 and not (st.bx1 < 0 or st.bx0 > comp.width or st.by1 < 0 or st.by0 > comp.height) then
          first_on = first_on or s / fps
          last_on = s / fps
        end
      end
    end
    if visible_ever then
      if not first_on and states[0][n] and states[0][n].bx0 then
        add("never_onscreen", "info", n, 0, dur, nil, nil,
          "visible somewhere in the comp but never inside the canvas")
      else
        if first_on and first_on > 0.5 then
          -- parked visible off-canvas before entrance
          local st0 = states[0][n]
          if st0 and st0.vis and st0.bx0
            and (st0.bx1 < 0 or st0.bx0 > comp.width or st0.by1 < 0 or st0.by0 > comp.height) then
            add("parked_visible", "info", n, 0, first_on, first_on, 0.5,
              "parked off-canvas with opacity>0 before entering; set opacity=0 until entrance")
          end
        end
        if last_on and last_vis and last_vis - last_on > 1.5 and last_on < dur - 0.5 then
          add("off_frame_linger", "warn", n, last_on, last_vis, last_vis - last_on, 1.5,
            "exits canvas but stays visible; hard-kill after exit (opacity=0)")
        end
      end
    end
    for s = 0, n_samples - 1 do
      local st = states[s][n]
      if st and st.vis and st.bx0 then
        if n.kind == "text" then
          local sz = (st.size or 32) * st.sc
          local floor = TH.text_min * ((comp.height or 1080) / 1080)
          if sz < floor and (not min_size_worst or sz < min_size_worst.v) then
            min_size_worst = { t = s / fps, v = sz }
          end
          local cx, cy = (st.bx0 + st.bx1) / 2, (st.by0 + st.by1) / 2
          if cx < TH.safe_x or cx > comp.width - TH.safe_x
            or cy < TH.safe_y or cy > comp.height - TH.safe_y then
            unsafe_worst = unsafe_worst or s / fps
          end
        end
        if (st.w and st.w <= 0) or (st.h and st.h <= 0) or st.sc <= 0 then
          add("zero_area", "error", n, s / fps, s / fps, st.sc, 0, "zero/negative area while visible")
          break
        end
      end
    end
    if min_size_worst then
      add("text_min_size", "warn", n, min_size_worst.t, min_size_worst.t,
        min_size_worst.v, TH.text_min * ((comp.height or 1080) / 1080),
        "text below legibility floor (scaled to comp height)")
    end
    if unsafe_worst then
      add("safe_area", "info", n, unsafe_worst, unsafe_worst, nil, nil,
        "text center outside safe margins")
    end
  end

  -- ============ color / brand ============
  -- background stack: full-canvas rects (static or animated color)
  local bgs = {}
  for _, n in ipairs(visual) do
    if n.kind == "rect" and (n.initial.w or 0) >= comp.width * 0.9
      and (n.initial.h or 0) >= comp.height * 0.9 then
      bgs[#bgs + 1] = n
    end
  end
  local function bg_color_at(s)
    local area = comp.width * comp.height
    for i = #bgs, 1, -1 do
      local st = states[s][bgs[i]]
      if st and st.vis and st.bx0 then
        -- must actually COVER the canvas at this moment (a full-size slab
        -- parked off-canvas is not the background)
        local ix = math.max(0, math.min(st.bx1, comp.width) - math.max(st.bx0, 0))
        local iy = math.max(0, math.min(st.by1, comp.height) - math.max(st.by0, 0))
        if ix * iy >= area * 0.7 then
          local c = bgs[i].state.color or bgs[i].initial.color
          if c and (c[4] or 1) > 0.9 then return c end
        end
      end
    end
    return comp.background
  end
  local palette = {}
  for _, n in ipairs(visual) do
    if n.kind == "text" then
      -- contrast at each visible second
      local reported = false
      for s = 0, n_samples - 1, fps do
        local st = states[s][n]
        if st and st.vis and st.op > 0.5 and not reported then
          at(s / fps)
          local fg = n.state.color or n.initial.color
          local outline = n.state.outline
          if outline == nil then outline = n.initial.outline end
          if outline and outline > 0 then
            fg = n.initial.outline_color or fg
            if type(fg) == "string" then fg = require("moonsplice.color").parse(fg) end
          end
          local bg = bg_color_at(s)
          if fg and bg then
            local ratio = contrast_ratio(fg, bg)
            local large = ((st.size or 32) * st.sc) >= TH.large_size
            local need = large and TH.contrast_large or TH.contrast_normal
            if ratio < need then
              reported = true
              add("contrast_static", "error", n, s / fps, s / fps, ratio, need,
                ("%.2f:1 vs required %.1f:1"):format(ratio, need),
                "adjust lightness toward passing in OKLab direction")
            end
          end
        end
      end
    end
    local c = n.initial.color
    if c then
      local key = ("%d,%d,%d"):format(c[1] * 255, c[2] * 255, c[3] * 255)
      palette[key] = c
    end
  end
  local pcount = 0
  for _ in pairs(palette) do pcount = pcount + 1 end
  if pcount > TH.palette_max then
    add("palette_sprawl", "info", nil, 0, dur, pcount, TH.palette_max,
      pcount .. " distinct colors in comp")
  end
  if opts.brand and opts.brand.palette then
    local bp = {}
    for _, hex in ipairs(opts.brand.palette) do bp[#bp + 1] = color.parse(hex) end
    for key, c in pairs(palette) do
      local best = math.huge
      for _, b in ipairs(bp) do best = math.min(best, oklab_dist(c, b)) end
      if best > TH.brand_de then
        add("brand_token", "warn", nil, 0, dur, best, TH.brand_de,
          "color rgb(" .. key .. ") not in brand palette")
      end
    end
    for _, n in ipairs(visual) do
      if n.kind == "text" and not n.initial.font then
        add("brand_font", "warn", n, 0, dur, nil, nil, "text without brand font")
      end
    end
  end
end
