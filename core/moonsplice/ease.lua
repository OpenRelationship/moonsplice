-- Easing functions: f(x) with x in [0,1] -> [0,1]-ish (back/elastic overshoot).
local pi, sin, cos, pow = math.pi, math.sin, math.cos, function(a, b) return a ^ b end

local E = {}

E.linear = function(x) return x end

E.quadIn = function(x) return x * x end
E.quadOut = function(x) return 1 - (1 - x) * (1 - x) end
E.quadInOut = function(x)
  if x < 0.5 then return 2 * x * x end
  return 1 - pow(-2 * x + 2, 2) / 2
end

E.cubicIn = function(x) return x * x * x end
E.cubicOut = function(x) return 1 - pow(1 - x, 3) end
E.cubicInOut = function(x)
  if x < 0.5 then return 4 * x * x * x end
  return 1 - pow(-2 * x + 2, 3) / 2
end

E.sineIn = function(x) return 1 - cos(x * pi / 2) end
E.sineOut = function(x) return sin(x * pi / 2) end
E.sineInOut = function(x) return -(cos(pi * x) - 1) / 2 end

E.expoIn = function(x) return x == 0 and 0 or pow(2, 10 * x - 10) end
E.expoOut = function(x) return x == 1 and 1 or 1 - pow(2, -10 * x) end
E.expoInOut = function(x)
  if x == 0 then return 0 end
  if x == 1 then return 1 end
  if x < 0.5 then return pow(2, 20 * x - 10) / 2 end
  return (2 - pow(2, -20 * x + 10)) / 2
end

local c1, c3 = 1.70158, 1.70158 + 1
E.backIn = function(x) return c3 * x * x * x - c1 * x * x end
E.backOut = function(x) return 1 + c3 * pow(x - 1, 3) + c1 * pow(x - 1, 2) end
E.backInOut = function(x)
  local c2 = c1 * 1.525
  if x < 0.5 then return (pow(2 * x, 2) * ((c2 + 1) * 2 * x - c2)) / 2 end
  return (pow(2 * x - 2, 2) * ((c2 + 1) * (x * 2 - 2) + c2) + 2) / 2
end

local c4 = (2 * pi) / 3
E.elasticOut = function(x)
  if x == 0 then return 0 end
  if x == 1 then return 1 end
  return pow(2, -10 * x) * sin((x * 10 - 0.75) * c4) + 1
end
E.elasticIn = function(x)
  if x == 0 then return 0 end
  if x == 1 then return 1 end
  return -pow(2, 10 * x - 10) * sin((x * 10 - 10.75) * c4)
end
E.elasticInOut = function(x)
  if x == 0 then return 0 end
  if x == 1 then return 1 end
  local c5 = (2 * pi) / 4.5
  if x < 0.5 then return -(pow(2, 20 * x - 10) * sin((20 * x - 11.125) * c5)) / 2 end
  return pow(2, -20 * x + 10) * sin((20 * x - 11.125) * c5) / 2 + 1
end

-- Penner bounce (flux / easing.lua). Steal the curve, not the timer.
local function bounce_out(x)
  local n1, d1 = 7.5625, 2.75
  if x < 1 / d1 then return n1 * x * x end
  if x < 2 / d1 then
    x = x - 1.5 / d1
    return n1 * x * x + 0.75
  end
  if x < 2.5 / d1 then
    x = x - 2.25 / d1
    return n1 * x * x + 0.9375
  end
  x = x - 2.625 / d1
  return n1 * x * x + 0.984375
end
E.bounceOut = bounce_out
E.bounceIn = function(x) return 1 - bounce_out(1 - x) end
E.bounceInOut = function(x)
  if x < 0.5 then return (1 - bounce_out(1 - 2 * x)) / 2 end
  return (1 + bounce_out(2 * x - 1)) / 2
end

-- Real physics spring (closed-form damped harmonic oscillator — no simulation,
-- seek-safe). Returns an ease fn; overshoot depends on damping vs stiffness.
-- Inspired by animato / Remotion's spring(). x in [0,1] maps across settle time.
E._names = setmetatable({}, { __mode = "k" }) -- fn -> readable name (for lint)

-- the shortest decimal that reads back as the same number, so a name parses to the same ease
function E.num(v)
  if v == math.floor(v) and math.abs(v) < 1e15 then return ("%d"):format(v) end
  for p = 1, 17 do
    local s = ("%." .. p .. "g"):format(v)
    if tonumber(s) == v then return s end
  end
  return ("%.17g"):format(v)
end

function E.name_of(f)
  if type(f) == "string" then return f end
  return E._names[f] or ("custom:" .. tostring(f))
end

function E.spring(opts)
  opts = opts or {}
  local stiffness = opts.stiffness or 180
  local damping = opts.damping or 12
  local mass = opts.mass or 1
  local w0 = math.sqrt(stiffness / mass)          -- natural frequency
  local zeta = damping / (2 * math.sqrt(stiffness * mass)) -- damping ratio
  local settle = 6 / (zeta * w0)                  -- ~settling time (2% band)
  local label = mass ~= 1 and ("spring(%s,%s,%s)"):format(E.num(stiffness), E.num(damping), E.num(mass))
    or ("spring(%s,%s)"):format(E.num(stiffness), E.num(damping))
  local f
  if zeta < 1 then
    local wd = w0 * math.sqrt(1 - zeta * zeta)
    f = function(x)
      local t = x * settle
      local decay = math.exp(-zeta * w0 * t)
      return 1 - decay * (math.cos(wd * t) + (zeta * w0 / wd) * math.sin(wd * t))
    end
  else
    f = function(x) -- critically/over-damped: no oscillation
      local t = x * settle
      return 1 - math.exp(-w0 * t) * (1 + w0 * t)
    end
  end
  E._names[f] = label
  return f
end

-- CSS-style cubic-bezier(x1,y1,x2,y2) via Newton/bisection solve
function E.cubicBezier(x1, y1, x2, y2)
  local function bez(t, a, b) return 3 * t * (1 - t) ^ 2 * a + 3 * t * t * (1 - t) * b + t ^ 3 end
  local f = function(x)
    if x <= 0 then return 0 end
    if x >= 1 then return 1 end
    local lo, hi, t = 0, 1, x
    for _ = 1, 24 do
      local cx = bez(t, x1, x2)
      if math.abs(cx - x) < 1e-5 then break end
      if cx < x then lo = t else hi = t end
      t = (lo + hi) / 2
    end
    return bez(t, y1, y2)
  end
  E._names[f] = ("cubicBezier(%s,%s,%s,%s)"):format(E.num(x1), E.num(y1), E.num(x2), E.num(y2))
  return f
end

-- an ease written as its name, so rows (.robot/docs/rows.robot) can hold any ease: "spring(180,12)",
-- "spring(180,12,2)", "cubicBezier(0.2,0,0,1)"
local parsed = {}
local function from_name(name)
  if parsed[name] then return parsed[name] end
  local fn, args = name:match("^(%a+)%(([^)]*)%)$")
  if not fn then return nil end
  local n = {}
  for v in args:gmatch("[^,%s]+") do n[#n + 1] = tonumber(v) end
  local f
  if fn == "spring" then f = E.spring({ stiffness = n[1], damping = n[2], mass = n[3] })
  elseif fn == "cubicBezier" and #n == 4 then f = E.cubicBezier(n[1], n[2], n[3], n[4]) end
  parsed[name] = f
  return f
end

function E.get(name)
  if type(name) == "function" then return name end -- spring()/cubicBezier() results
  local f = E[name] or (type(name) == "string" and from_name(name))
  if not f then error(("moonsplice: unknown ease %q"):format(tostring(name)), 3) end
  return f
end

return E
