-- 3D camera for flat surfaces (screen captures, stills).
--
-- The surface is a PLANE, so the whole 3D transform collapses to a 3x3
-- homography — no mesh, no subdivision, no texture swim. The fragment shader
-- runs it BACKWARDS (screen pixel -> page pixel), which is exact perspective at
-- any angle and hands us the camera-space depth of every pixel for free.
--
-- That depth is what makes this more than a tilt: with a real depth per pixel we
-- get an actual thin-lens defocus across the surface. Tilt the page away and the
-- far edge genuinely falls out of focus, which is the shot ScreenStudio cannot
-- do because it only ever moves a 2D rectangle.
--
-- Everything is post: no re-recording, no 3D scene, no extra capture pass.
local P = {}

local shader
local flat_cache, stage_cache = {}, {}

local SRC = [[
  extern vec3 Hi0, Hi1, Hi2;   // inverse homography rows: screen -> page
  extern vec2 half_page;       // (w/2, h/2) in page px
  extern vec2 depth_ab;        // R20, R21 — plane depth gradient
  extern float Dz;             // camera distance to the page centre
  extern float focusW;         // camera-space depth the lens is focused on
  extern float aperture;       // px of blur per unit relative depth error
  extern float maxcoc;
  extern vec2 csize;

  // canvas pixel -> page uv in [0,1] plus camera-space depth
  bool project(vec2 px, out vec2 uv01, out float W) {
    vec3 s = vec3(px.x - csize.x * 0.5, px.y - csize.y * 0.5, 1.0);
    vec3 p = vec3(dot(Hi0, s), dot(Hi1, s), dot(Hi2, s));
    uv01 = vec2(0.0); W = 1.0;
    if (abs(p.z) < 1e-7) return false;
    vec2 uv = p.xy / p.z;
    W = uv.x * depth_ab.x + uv.y * depth_ab.y + Dz;
    if (W <= 0.0001) return false;              // behind the camera
    uv01 = uv / (2.0 * half_page) + 0.5;
    return uv01.x >= 0.0 && uv01.x <= 1.0 && uv01.y >= 0.0 && uv01.y <= 1.0;
  }

  vec4 effect(vec4 col, Image tex, vec2 tc, vec2 pc) {
    vec2 uv0; float W0;
    if (!project(pc, uv0, W0)) return vec4(0.0);
    float coc = clamp(aperture * abs(W0 - focusW) / max(focusW, 1e-4), 0.0, maxcoc);
    if (coc < 0.75) return Texel(tex, uv0) * col;
    // golden-angle spiral: even coverage, no visible tap pattern
    vec4 acc = vec4(0.0);
    float wsum = 0.0;
    for (int i = 0; i < 20; i++) {
      float t = (float(i) + 0.5) / 20.0;
      float ang = float(i) * 2.399963;
      vec2 off = vec2(cos(ang), sin(ang)) * sqrt(t) * coc;
      vec2 uvT; float WT;
      if (project(pc + off, uvT, WT)) { acc += Texel(tex, uvT); wsum += 1.0; }
    }
    if (wsum < 0.5) return Texel(tex, uv0) * col;
    return (acc / wsum) * col;
  }
]]

local function get_shader()
  if not shader then shader = love.graphics.newShader(SRC) end
  return shader
end

local function canvas_for(cache, w, h)
  local key = w .. "x" .. h
  if not cache[key] then cache[key] = love.graphics.newCanvas(w, h) end
  return cache[key]
end

function P.flat_canvas(w, h) return canvas_for(flat_cache, w, h) end

-- 3x3 row-major helpers
local function mul(A, B)
  local C = {}
  for r = 0, 2 do
    for c = 0, 2 do
      C[r * 3 + c + 1] = A[r * 3 + 1] * B[c + 1] + A[r * 3 + 2] * B[3 + c + 1]
        + A[r * 3 + 3] * B[6 + c + 1]
    end
  end
  return C
end

local function rot(yaw, pitch, roll)
  local cy, sy = math.cos(yaw), math.sin(yaw)
  local cp, sp = math.cos(pitch), math.sin(pitch)
  local cr, sr = math.cos(roll), math.sin(roll)
  local Rx = { 1, 0, 0, 0, cp, -sp, 0, sp, cp }
  local Ry = { cy, 0, sy, 0, 1, 0, -sy, 0, cy }
  local Rz = { cr, -sr, 0, sr, cr, 0, 0, 0, 1 }
  return mul(Rz, mul(Ry, Rx))
end

local function inv3(m)
  local a, b, c, d, e, f, g, h, i = m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9]
  local A, B, C = e * i - f * h, -(d * i - f * g), d * h - e * g
  local det = a * A + b * B + c * C
  if math.abs(det) < 1e-12 then return nil end
  local id = 1 / det
  return {
    A * id, -(b * i - c * h) * id, (b * f - c * e) * id,
    B * id, (a * i - c * g) * id, -(a * f - c * d) * id,
    C * id, -(a * h - b * g) * id, (a * e - b * d) * id,
  }
end

-- Camera source: a shared s:camera node, else the plane itself.
local function cam_of(node)
  local cam = node.initial.camera
  if type(cam) == "table" and cam.get then return cam end
  return node
end

-- Plane owns dolly (its Z). Shared camera owns orbit/lens/focus unless this
-- plane's timeline wrote a local overlay (state[k]).
local function get(node, cam, k, dflt)
  if k == "dolly" then
    local v = node:get(k)
    if v ~= nil then return v end
    return dflt
  end
  if cam ~= node and node.state[k] ~= nil then
    return node.state[k]
  end
  if cam ~= node then
    local v = cam:get(k)
    if v ~= nil then return v end
  end
  local v = node:get(k)
  if v ~= nil then return v end
  return dflt
end

-- The camera for a plane of w x h page px, as numbers: what scene/'s perspective pass needs
-- (opcode 114). Pure -- the same maths the shader below was fed.
function P.params(node, w, h)
  local cam = cam_of(node)
  local yaw, pitch, roll = get(node, cam, "yaw", 0), get(node, cam, "pitch", 0), get(node, cam, "roll", 0)
  local look_src = (cam.initial.look_x ~= nil or cam.initial.look_at) and cam or node
  if look_src.initial.look_x ~= nil or look_src.initial.look_at then
    local math3d = require("moonsplice.math3d")
    yaw, pitch = math3d.look_yaw_pitch(
      get(node, cam, "cam_x", 0), get(node, cam, "cam_y", 0), get(node, cam, "cam_z", 1),
      get(node, cam, "look_x", 0), get(node, cam, "look_y", 0), get(node, cam, "look_z", 0))
    roll = get(node, cam, "roll", 0)
  end
  local dolly = get(node, cam, "dolly", 1)
  local fov = get(node, cam, "fov", 0.62)
  local nscale = node:get("scale") or 1
  if nscale <= 0 then nscale = 1 end
  local tu, tv = get(node, cam, "truck_u", 0.5), get(node, cam, "truck_v", 0.5)
  local margin = node.initial.persp_margin or 1.45
  -- One lens for every plane: the focal length is the frame's, not the plane's. Apparent size at
  -- rest is f / D = dolly whatever f is, so a plane at dolly 1 is still its flat size; what f
  -- sets is how strongly it foreshortens, and planes sharing a camera must agree on that. (Taken
  -- from the plane's own height, a 52 px button sat 55 px from the lens.)
  local f = ((P.frame_h or h) / 2) / math.tan(fov / 2)
  local D = f / math.max(dolly, 0.05)
  local R = rot(yaw, pitch, roll)
  local pu, pv = (tu - 0.5) * w, (tv - 0.5) * h
  local Dz = D - (R[7] * pu + R[8] * pv)
  local Hi = inv3({ f * R[1], f * R[2], -f * (R[1] * pu + R[2] * pv),
                    f * R[4], f * R[5], -f * (R[4] * pu + R[5] * pv),
                    R[7], R[8], Dz })
  if not Hi then return nil end
  local fu, fv = get(node, cam, "focus_u", 0.5), get(node, cam, "focus_v", 0.5)
  return {
    Hi = Hi, sw = math.ceil(w * margin), sh = math.ceil(h * margin),
    R20 = R[7], R21 = R[8], Dz = Dz,
    focusW = (fu - 0.5) * w * R[7] + (fv - 0.5) * h * R[8] + Dz,
    -- authored in screen px; the stage is drawn at the node's scale, so undo it here
    aperture = get(node, cam, "aperture", 0) / nscale,
    maxcoc = get(node, cam, "maxcoc", 42) / nscale,
  }
end

-- Draw `tex` (already-composed flat content, w x h) as a plane in 3D.
-- Returns the stage canvas and the offset at which to draw it in node space.
function P.render(node, tex, w, h)
  local cam = cam_of(node)
  local yaw, pitch, roll = get(node, cam, "yaw", 0), get(node, cam, "pitch", 0), get(node, cam, "roll", 0)
  local look_src = (cam.initial.look_x ~= nil or cam.initial.look_at) and cam or node
  if look_src.initial.look_x ~= nil or look_src.initial.look_at then
    local math3d = require("moonsplice.math3d")
    yaw, pitch = math3d.look_yaw_pitch(
      get(node, cam, "cam_x", 0), get(node, cam, "cam_y", 0), get(node, cam, "cam_z", 1),
      get(node, cam, "look_x", 0), get(node, cam, "look_y", 0), get(node, cam, "look_z", 0))
    roll = get(node, cam, "roll", 0)
  end
  local dolly = get(node, cam, "dolly", 1)
  local fov = get(node, cam, "fov", 0.62)
  -- aperture/maxcoc are authored in SCREEN px. The stage is rendered in page px
  -- and then drawn at the node's scale, so undo that here — otherwise a capture
  -- shown at 0.46 scale silently gets less than half the blur it asked for.
  local nscale = node:get("scale") or 1
  if nscale <= 0 then nscale = 1 end
  local aperture = get(node, cam, "aperture", 0) / nscale
  local maxcoc = get(node, cam, "maxcoc", 42) / nscale
  -- truck: the page point the camera is centred on (normalized). Orbit+zoom
  -- alone always pivots the middle of the page; trucking is what lets the shot
  -- travel to the dropdown, then to the send button, like a camera on rails.
  local tu, tv = get(node, cam, "truck_u", 0.5), get(node, cam, "truck_v", 0.5)
  local margin = node.initial.persp_margin or 1.45

  local sw = math.ceil(w * margin)
  local sh = math.ceil(h * margin)
  local stage = canvas_for(stage_cache, sw, sh)

  local a, b = w / 2, h / 2
  local f = (h / 2) / math.tan(fov / 2)
  local D = f / math.max(dolly, 0.05)
  local R = rot(yaw, pitch, roll)
  local R00, R01 = R[1], R[2]
  local R10, R11 = R[4], R[5]
  local R20, R21 = R[7], R[8]
  -- shift the plane so the truck target sits on the optical axis
  local pu, pv = (tu - 0.5) * w, (tv - 0.5) * h
  local Dz = D - (R20 * pu + R21 * pv)
  local H = { f * R00, f * R01, -f * (R00 * pu + R01 * pv),
              f * R10, f * R11, -f * (R10 * pu + R11 * pv),
              R20, R21, Dz }
  local Hi = inv3(H)
  if not Hi then return nil end

  -- focus point in normalized page coords -> its camera-space depth
  local fu, fv = get(node, cam, "focus_u", 0.5), get(node, cam, "focus_v", 0.5)
  local focusW = (fu - 0.5) * w * R20 + (fv - 0.5) * h * R21 + Dz

  local sdr = get_shader()
  local prev = love.graphics.getCanvas()
  local pc, pv = love.graphics.getStencilTest()
  love.graphics.push("all")
  love.graphics.origin()
  love.graphics.setStencilTest()
  love.graphics.setCanvas(stage)
  love.graphics.clear(0, 0, 0, 0)
  love.graphics.setShader(sdr)
  sdr:send("Hi0", { Hi[1], Hi[2], Hi[3] })
  sdr:send("Hi1", { Hi[4], Hi[5], Hi[6] })
  sdr:send("Hi2", { Hi[7], Hi[8], Hi[9] })
  sdr:send("half_page", { a, b })
  sdr:send("depth_ab", { R20, R21 })
  sdr:send("Dz", Dz)
  sdr:send("focusW", focusW)
  sdr:send("aperture", aperture)
  sdr:send("maxcoc", maxcoc)
  sdr:send("csize", { sw, sh })
  love.graphics.setColor(1, 1, 1, 1)
  love.graphics.setBlendMode("alpha", "premultiplied")
  -- The quad must cover the WHOLE stage: the projected plane can land anywhere
  -- in it, and the shader only runs on rasterized pixels. Its own UVs are
  -- irrelevant — the shader derives uv from the inverse homography.
  love.graphics.draw(tex, 0, 0, 0, sw / tex:getWidth(), sh / tex:getHeight())
  love.graphics.setShader()
  love.graphics.setCanvas(prev and { prev, stencil = true } or nil)
  love.graphics.pop()
  if pc then love.graphics.setStencilTest(pc, pv) end

  return stage, -(sw - w) / 2, -(sh - h) / 2
end

return P
