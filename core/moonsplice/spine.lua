-- Seek-safe Spine-like skeleton. Drive from t, never update(dt).
-- Supports a subset of Spine JSON: bones (parent, x, y, rotation, length)
-- and animation bone rotate/translate/scale keyframes. Draw as capsules.
local S = {}

local function lerp(a, b, k) return a + (b - a) * k end

local function sample_keys(keys, t, field)
  if not keys or #keys == 0 then return nil end
  if t <= (keys[1].time or 0) then return keys[1][field] or keys[1].angle or keys[1].x end
  for i = 1, #keys - 1 do
    local a, b = keys[i], keys[i + 1]
    local t0, t1 = a.time or 0, b.time or 0
    if t <= t1 then
      local k = t1 > t0 and (t - t0) / (t1 - t0) or 1
      local av = a[field] or a.angle or a.x or 0
      local bv = b[field] or b.angle or b.x or av
      return lerp(av, bv, k)
    end
  end
  local last = keys[#keys]
  return last[field] or last.angle or last.x
end

function S.pose(skel, name, t)
  local bones = {}
  for i, b in ipairs(skel.bones or {}) do
    bones[i] = {
      name = b.name,
      parent = b.parent,
      x = b.x or 0, y = b.y or 0,
      rotation = b.rotation or 0,
      scale = b.scaleX or b.scale or 1,
      length = b.length or 0,
    }
    bones[b.name] = bones[i]
  end
  local anim = (skel.animations or {})[name or skel.animation or "default"]
  local tracks = anim and anim.bones or {}
  local dur = 0
  for _, keys in pairs(tracks) do
    for _, channel in pairs(keys) do
      if type(channel) == "table" then
        local last = channel[#channel]
        if last and (last.time or 0) > dur then dur = last.time end
      end
    end
  end
  if dur > 0 and skel.loop ~= false then t = t % dur end
  for bname, ch in pairs(tracks) do
    local bone = bones[bname]
    if bone then
      if ch.rotate then
        bone.rotation = sample_keys(ch.rotate, t, "angle") or bone.rotation
      end
      if ch.translate then
        bone.x = sample_keys(ch.translate, t, "x") or bone.x
        bone.y = sample_keys(ch.translate, t, "y") or bone.y
      end
      if ch.scale then
        bone.scale = sample_keys(ch.scale, t, "x") or bone.scale
      end
    end
  end
  local world = {}
  for i, bone in ipairs(bones) do
    local px, py, pr = 0, 0, 0
    if bone.parent and bones[bone.parent] and bones[bone.parent]._wx then
      local p = bones[bone.parent]
      px, py, pr = p._wx, p._wy, p._wr
    end
    local rad = math.rad(pr)
    local c, s = math.cos(rad), math.sin(rad)
    local wx = px + bone.x * c - bone.y * s
    local wy = py + bone.x * s + bone.y * c
    local wr = pr + bone.rotation
    bone._wx, bone._wy, bone._wr = wx, wy, wr
    local a = math.rad(wr)
    world[i] = {
      x = wx, y = wy, rotation = wr, length = bone.length * bone.scale,
      x2 = wx + math.cos(a) * bone.length * bone.scale,
      y2 = wy + math.sin(a) * bone.length * bone.scale,
      name = bone.name,
    }
  end
  return world
end

return S
