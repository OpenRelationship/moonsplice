-- Tier-2 check: seek-grid render with measured-pixel audits. See .robot/docs/checks.robot.
local C = {}

local function luma(r, g, b) return 0.2126 * r + 0.7152 * g + 0.0722 * b end

local function contrast_ratio(l1, l2)
  if l1 < l2 then l1, l2 = l2, l1 end
  return (l1 + 0.05) / (l2 + 0.05)
end

function C.run(comp, opts, painter)
  local findings = {}
  local low_contrast = {}
  local function add(f) findings[#findings + 1] = f end
  local overflow = {}
  local PANEL = { rect = true, surface = true, world = true, image = true, video = true }
  local masks = {}
  for _, n in ipairs(comp.nodes) do if n.initial.clip_node then masks[n.initial.clip_node] = true end end

  -- sample times: 9 even + segment boundaries (deduped, capped)
  local times, seen = {}, {}
  local function push(t)
    t = math.max(0, math.min(comp.duration - 0.001, t))
    local k = math.floor(t * 30)
    if not seen[k] then
      seen[k] = true
      times[#times + 1] = t
    end
  end
  for i = 0, 8 do push(i * comp.duration / 8) end
  for _, g in ipairs(comp.timeline.order) do
    for _, seg in ipairs(g.segs) do
      push(seg.t0)
      push(seg.t1)
      if #times >= 30 then break end
    end
    if #times >= 30 then break end
  end
  table.sort(times)

  -- Audit the frames the renderer actually makes: scene/ paints the frame straight into a buffer
  -- (painter.scene_direct), and the audits read that. The buffer is reused for the next frame, so
  -- each sample keeps a copy -- the determinism check below holds two at once.
  local function render_at(t)
    comp:evaluate(t)
    local ok, img = pcall(painter.scene_direct, comp, t)
    if not ok then return nil, img end
    return img:clone()
  end

  local prev_img, prev_t, static_since = nil, nil, nil
  local W, H = comp.width, comp.height

  for _, t in ipairs(times) do
    local img, err = render_at(t)
    if not img then
      add({ code = "render_error", severity = "error", t0 = t, t1 = t,
        detail = tostring(err) })
    else
      -- sampled stats on a 16x16 grid
      local n, sum, sumsq = 0, 0, 0
      local grid = {}
      for gy = 0, 15 do
        for gx = 0, 15 do
          local px = math.floor((gx + 0.5) * W / 16)
          local py = math.floor((gy + 0.5) * H / 16)
          local r, g, b = img:getPixel(px, py)
          local l = luma(r, g, b)
          grid[#grid + 1] = l
          n = n + 1
          sum = sum + l
          sumsq = sumsq + l * l
        end
      end
      local mean = sum / n
      local std = math.sqrt(math.max(0, sumsq / n - mean * mean))

      -- visible nodes claimed by the timeline?
      local any_vis = false
      for _, node in ipairs(comp.nodes) do
        local skip = node.kind == "flex" or node.kind == "kinetic"
          or node.kind == "audio" or node.kind == "tts" or node.kind == "sfx"
          or node.kind == "music"
          -- vector/draw content is time-gated inside the fn — an "on" node may
          -- legitimately paint nothing, so it can't claim visibility
          or node.kind == "vector" or node.kind == "draw"
          or node.kind == "camera" or node.kind == "light" or node.kind == "mesh"
          -- a full-canvas backdrop being visible doesn't make a frame non-blank
          or (node.kind == "rect" and (node.initial.w or 0) >= W * 0.9
            and (node.initial.h or 0) >= H * 0.9)
        if not skip then
          local op = node.state.opacity
          if op == nil then op = node.initial.opacity or 1 end
          if op > 0.05 then any_vis = true break end
        end
      end
      if std < 0.004 and any_vis then
        add({ code = "blank_frame", severity = "warn", t0 = t, t1 = t,
          measured = std, threshold = 0.004,
          detail = "frame nearly uniform while nodes claim visibility" })
      end

      -- frame diff vs previous sample (frozen confirmation on real pixels)
      if prev_img then
        local diff = 0
        for i = 1, #grid do diff = diff + math.abs(grid[i] - prev_img[i]) end
        diff = diff / #grid
        if diff < 0.002 then
          static_since = static_since or prev_t
          if t - static_since > 2.0 then
            add({ code = "frozen_confirmed", severity = "warn",
              t0 = static_since, t1 = t, measured = t - static_since, threshold = 2,
              detail = "pixels static across samples (post-fx included)" })
            static_since = t
          end
        else
          static_since = nil
        end
      end
      prev_img, prev_t = grid, t

      -- measured contrast at text bboxes
      for _, node in ipairs(comp.nodes) do
        if node.kind == "text" then
          local op = node.state.opacity
          if op == nil then op = node.initial.opacity or 1 end
          if op > 0.5 then
            local fg = node.state.color or node.initial.color
            if fg then
              local x = node.state.x or node.initial.x or 0
              local y = node.state.y or node.initial.y or 0
              -- ring sample just outside the text's box, measured with its real font by the
              -- rasterizer (an estimate only without it); a ring on the anchor point, or on a guessed
              -- width, read the background beside the text or the glyphs themselves
              local sc = (node.state.scale or node.initial.scale or 1)
              local size = (node.initial.size or 32) * sc
              local str = tostring(node.state.text or node.initial.text or "")
              local track = node.state.tracking or node.initial.tracking or 0
              local tw, th
              local scene = require("scene")
              if scene.enabled then
                local ok, w, h = pcall(scene.measure, scene.font_id(node.initial.font), node.initial.size or 32, str,
                  track, node.initial.wrap or 0, node.initial.leading or 0)
                if ok and w then tw, th = w * sc, h * sc end
              end
              if not tw then tw, th = math.min(#str * (size * 0.62 + track), W), size * 1.2 end
              local cx, cy = x, y
              if (node.initial.anchor or "topleft") ~= "center" then cx, cy = x + tw / 2, y + th / 2 end
              -- overflow: the text's real box against the smallest panel holding its start (a rect,
              -- surface, world, image or video at top level), or the frame
              -- (a text clipped to a mask is cut on purpose; a mask or an invisible rect is no panel)
              if not node.initial.parent and not node.initial.clip_node then
                local x0, y0 = cx - tw / 2, cy - th / 2
                local bx0, by0, bx1, by1, area = 0, 0, W, H, W * H
                for _, p in ipairs(comp.nodes) do
                  local pc = p.state.color or p.initial.color
                  local seen = not masks[p] and not (type(pc) == "table" and (pc[4] or 1) < 0.05)
                  if p ~= node and not p.initial.parent and PANEL[p.kind] and seen then
                    local pw, ph = p.state.w or p.initial.w, p.state.h or p.initial.h
                    local pop = p.state.opacity; if pop == nil then pop = p.initial.opacity or 1 end
                    if pw and ph and pop > 0.05 and pw * ph < area and pw < W * 0.95 then
                      local px, py = p.state.x or p.initial.x or 0, p.state.y or p.initial.y or 0
                      if (p.initial.anchor or "topleft") == "center" then px, py = px - pw / 2, py - ph / 2 end
                      if x0 >= px and x0 < px + pw and y0 >= py and y0 < py + ph then
                        bx0, by0, bx1, by1, area = px, py, px + pw, py + ph, pw * ph
                      end
                    end
                  end
                end
                local over = math.max(0, bx0 - x0, by0 - y0, x0 + tw - bx1, y0 + th - by1)
                if over > 2 then
                  local f = overflow[node.id]
                  if not f then
                    f = { code = "text_overflow", severity = "error", node = node.id, t0 = t, t1 = t,
                      measured = over, threshold = 0, failing = 0 }
                    overflow[node.id] = f
                    add(f)
                  end
                  f.t1, f.failing = t, f.failing + 1
                  if over > f.measured then f.measured = over end
                  f.detail = ("the text's box runs %.0f px past the edge of the panel it sits in (%s); %d samples"):format(
                    f.measured, area < W * H and "a panel" or "the frame", f.failing)
                  f.suggestion = "shorten it, make it smaller, or widen its panel"
                end
              end
              local rx, ry = tw / 2 + size * 0.5, th / 2 + size * 0.35
              local bl, cnt = 0, 0
              for a = 0, 11 do
                local ang = a * math.pi / 6
                local sx = math.floor(cx + math.cos(ang) * rx)
                local sy = math.floor(cy + math.sin(ang) * ry)
                if sx >= 0 and sx < W and sy >= 0 and sy < H then
                  local r, g, b = img:getPixel(sx, sy)
                  bl = bl + luma(r, g, b)
                  cnt = cnt + 1
                end
              end
              if cnt > 0 then
                local ratio = contrast_ratio(luma(fg[1], fg[2], fg[3]), bl / cnt)
                local need = (node.initial.size or 32) >= 48 and 3.0 or 4.5
                -- one row per text node: its span of failing samples and the worst ratio
                if ratio < need then
                  local f = low_contrast[node.id]
                  if not f then
                    f = { code = "contrast_measured", severity = "error", node = node.id,
                      t0 = t, t1 = t, measured = ratio, threshold = need, worst_t = t, failing = 0 }
                    low_contrast[node.id] = f
                    add(f)
                  end
                  f.t1, f.failing = t, f.failing + 1
                  if ratio < f.measured then f.measured, f.worst_t = ratio, t end
                  f.detail = ("measured %.2f:1 against real pixels at %.2f s (worst); %d samples fail")
                    :format(f.measured, f.worst_t, f.failing)
                end
              end
            end
          end
        end
      end
      img:release()
    end
  end

  -- determinism: re-render 3 spread samples, byte-compare
  for i = 1, 3 do
    local t = times[math.max(1, math.floor(#times * i / 3))]
    local a = render_at(t)
    local b = render_at(t)
    if a and b then
      local ha = love.data.hash("md5", a:getString())
      local hb = love.data.hash("md5", b:getString())
      if ha ~= hb then
        add({ code = "nondeterministic", severity = "error", t0 = t, t1 = t,
          detail = "same t rendered twice differs" })
      end
      a:release()
      b:release()
    end
  end

  for _, f in pairs(low_contrast) do f.worst_t, f.failing = nil, nil end
  table.sort(findings, function(a, b)
    local sev = { error = 1, warn = 2, info = 3 }
    if sev[a.severity] ~= sev[b.severity] then return sev[a.severity] < sev[b.severity] end
    return (a.t0 or 0) < (b.t0 or 0)
  end)
  return _MOONSPLICE_EMIT(findings, opts, "check")
end

return C
