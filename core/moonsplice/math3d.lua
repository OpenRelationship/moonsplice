-- Seek-safe 3D helpers for the plane camera and s:world. No clocks, no heap
-- beyond the returned tables. Quaternions are stored as {x,y,z,w}.
local M = {}

function M.look_yaw_pitch(ex, ey, ez, lx, ly, lz)
  local dx, dy, dz = (lx or 0) - (ex or 0), (ly or 0) - (ey or 0), (lz or 0) - (ez or 0)
  local horiz = math.sqrt(dx * dx + dz * dz)
  local yaw = math.atan2(dx, dz)
  local pitch = math.atan2(-dy, math.max(horiz, 1e-8))
  return yaw, pitch
end

function M.quat_from_euler(yaw, pitch, roll)
  yaw, pitch, roll = yaw or 0, pitch or 0, roll or 0
  local hy, hp, hr = yaw * 0.5, pitch * 0.5, roll * 0.5
  local cy, sy = math.cos(hy), math.sin(hy)
  local cp, sp = math.cos(hp), math.sin(hp)
  local cr, sr = math.cos(hr), math.sin(hr)
  return {
    sr * cp * cy - cr * sp * sy,
    cr * sp * cy + sr * cp * sy,
    cr * cp * sy - sr * sp * cy,
    cr * cp * cy + sr * sp * sy,
  }
end

function M.quat_rotate_vec(q, x, y, z)
  local qx, qy, qz, qw = q[1], q[2], q[3], q[4]
  local tx = 2 * (qy * z - qz * y)
  local ty = 2 * (qz * x - qx * z)
  local tz = 2 * (qx * y - qy * x)
  return x + qw * tx + (qy * tz - qz * ty),
         y + qw * ty + (qz * tx - qx * tz),
         z + qw * tz + (qx * ty - qy * tx)
end

return M
