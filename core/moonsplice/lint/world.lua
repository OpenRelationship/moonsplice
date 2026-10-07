-- Lint's rules on built things: solids against what was meant, props a 3D camera crops, and keys a system
-- overrides.
-- Part of moonsplice.lint (core/moonsplice/lint/init.lua): L.run calls it with its context, ctx.

return function(ctx)
  local comp, fps, dur, n_samples = ctx.comp, ctx.fps, ctx.dur, ctx.n_samples
  local add, at = ctx.add, ctx.at
  -- ============ solids (.robot/docs/solids.robot): what Manifold built, against what was meant ============
  for id, m in pairs(comp.solids or {}) do
    if m.empty then
      add("solid_empty", "error", nil, 0, dur, 0, nil, ("solid %s came out empty"):format(id),
        "a difference or intersection removed everything; check the operands overlap where you meant")
    elseif not m.watertight then
      add("solid_not_watertight", "error", nil, 0, dur, nil, nil, ("solid %s is not watertight"):format(id), nil)
    elseif m.declared_parts and m.parts ~= m.declared_parts then
      add("solid_parts", "warn", nil, 0, dur, m.parts, m.declared_parts,
        ("solid %s is %d pieces, declared %d"):format(id, m.parts, m.declared_parts),
        "a piece that should touch another floats free, or two that should be apart are fused")
    elseif not m.declared_parts and (m.parts or 1) > 1 then
      add("solid_parts", "warn", nil, 0, dur, m.parts, 1,
        ("solid %s is %d separate pieces"):format(id, m.parts),
        "something floats free (even a 1 cm gap); overlap it, or declare parts = n on the asset if meant")
    end
  end

  -- ============ 3D framing: a prop the camera crops ============
  -- each small mesh in a world, projected through the world's camera at each sampled frame (Bevy's
  -- fov is vertical; the aspect is the world's box). Scenery (planes, anything over 3 m) is left out.
  do
    local worlds = {}
    for _, n in ipairs(comp.nodes or {}) do if n.kind == "world" then worlds[n] = { meshes = {} } end end
    for _, n in ipairs(comp.nodes or {}) do
      local par = n.initial.parent
      if n.kind == "mesh" and par and worlds[par] and n.initial.primitive ~= "plane" then
        table.insert(worlds[par].meshes, n)
      end
    end
    local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
    local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
    local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
    local function unit(a) local l = math.sqrt(dot(a, a)); return l > 1e-9 and { a[1] / l, a[2] / l, a[3] / l } or nil end
    for wnode, wd in pairs(worlds) do
      -- (an orbiting camera, yaw/pitch about look, is left out; every node carries yaw = 0, so test the value)
      if #wd.meshes > 0 and (wnode:get("yaw") or 0) == 0 and (wnode:get("pitch") or 0) == 0 then
        local cropped, worst, ever_in = {}, {}, {}
        local steps = math.max(1, math.floor(n_samples / 48))
        for s = 0, n_samples - 1, steps do
          local t = s / fps
          at(t)
          local g = function(k, d) local v = wnode:get(k); if v == nil then return d end return v end
          local cam = { g("cam_x", 0), g("cam_y", 0.35), g("cam_z", 3.2) }
          local f = unit(sub({ g("look_x", 0), g("look_y", 0), g("look_z", 0) }, cam))
          local r = f and unit(cross(f, { 0, 1, 0 }))
          if r then
            local u = cross(r, f)
            local th = math.tan(g("fov", 0.7) / 2)
            local aspect = (g("w", 1) or 1) / math.max(1, g("h", 1) or 1)
            for _, m in ipairs(wd.meshes) do
              local sz = m:get("size")
              local sc = m:get("scale") or 1
              local ext = (type(sz) == "table" and math.max(sz[1] or 1, sz[2] or 1, sz[3] or 1) or 1) * sc
              if ext <= 3 then
                local v = sub({ m:get("x") or 0, m:get("y") or 0, m:get("z") or 0 }, cam)
                local z = dot(v, f)
                if z > 0.05 then
                  local nx, ny = dot(v, r) / (z * th * aspect), dot(v, u) / (z * th)
                  local rad = (ext / 2) / (z * th)
                  local out = math.max(math.abs(nx) + rad / aspect - 1, math.abs(ny) + rad - 1)
                  if out <= 0 then ever_in[m] = true end
                  -- more than half its radius past the edge: cut, or gone from a view it was in
                  if out > rad * 0.5 then
                    cropped[m] = (cropped[m] or 0) + 1
                    if out > (worst[m] or 0) then worst[m] = out end
                  end
                end
              end
            end
          end
        end
        local total = math.floor((n_samples - 1) / steps) + 1
        for m, c in pairs(cropped) do
          if c / total > 0.2 and ever_in[m] then
            add("subject_cropped", "warn", m, 0, dur, c / total, 0.2,
              ("%s is cut by or leaves world %s's view in %d%% of the piece"):format(m.id, wnode.id, math.floor(100 * c / total)),
              "pull the camera back or aim it (cam_*, look_*), or keep the object inside the view as it moves")
          end
        end
      end
    end
  end

  -- ============ keys a system overrides (rows comps) ============
  -- systems run after the keys every frame, so a key on a prop a system sets never shows
  if comp.rows and comp.access then
    local by = {}
    for sys, ids in pairs(comp.access) do
      for id, props in pairs(ids) do
        for prop in pairs(props) do by[id .. "\0" .. prop] = sys end
      end
    end
    local seen = {}
    for _, k in ipairs(comp.rows.key or {}) do
      local c = k.id .. "\0" .. k.name
      local sys = by[c]
      if sys and not seen[c] then
        seen[c] = true
        add("key_overridden", "error", { id = k.id }, 0, dur, nil, nil,
          ("%s.%s is keyed, but system %s sets it every frame, so the keys never show"):format(k.id, k.name, sys),
          ("drop the keys and change %s, or have %s stop setting %s"):format(sys, sys, k.name))
      end
    end
  end
end
