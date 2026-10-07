package.path = "core/?.lua;core/?/init.lua;" .. package.path
local e = require("moonsplice")
local function mk(dur, fps, build)
  local c = e.comp { width = 100, height = 100, duration = dur, fps = fps, scene = build }
  c:compile({})
  return c
end
local function first_frame(c, node, prop, fps, pred, lo, hi)
  for i = lo, hi do c:evaluate(i / fps); if pred(node:get(prop)) then return i end end
end
-- (a) a rect turned on at 1/3 s, three ways
local R = {}
for _, how in ipairs({ "at(1/3)", "wait(1/30) x10", "wait(0.1)+wait(0.1)+wait(0.1)+wait(1/30)", "at(0.1+0.2)" }) do
  local box
  local c = mk(2, 30, function(s)
    box = s:rect { id = "b", x = 0, y = 0, w = 10, h = 10, color = "#fff", opacity = 0 }
    s:script(function(r)
      if how == "at(1/3)" then r:at(1/3)
      elseif how == "wait(1/30) x10" then for _ = 1, 10 do r:wait(1/30) end
      elseif how:match("^wait%(0.1%)") then r:wait(0.1); r:wait(0.1); r:wait(0.1); r:wait(1/30)
      else r:at(0.1 + 0.2) end
      r:set(box, { opacity = 1 })
    end)
  end)
  local want = how == "at(0.1+0.2)" and 9 or 10
  local seg = c.timeline.order[1].segs[1]
  print(("(a) %-42s t0=%.17g  first visible frame=%d (intended %d)"):format(how, seg.t0,
    first_frame(c, box, "opacity", 30, function(v) return v == 1 end, 0, 59), want))
end
-- (b) a key at t=0.1 vs frame 3
do
  local box
  local c = mk(1, 30, function(s)
    box = s:rect { id = "b", x = 0, y = 0, w = 10, h = 10, color = "#fff" }
    s:script(function(r) r:tween(box, 0.1, { x = 100 }) ; r:tween(box, 0.1, { x = 200 }) end)
  end)
  for i = 2, 7 do c:evaluate(i / 30); io.write(("frame %d x=%.17g  "):format(i, box:get("x"))) end
  print()
end
-- (c) an hour: how many frames land on the wrong side of a boundary authored as k/30, (k-1)/30 + 1/30, or by summed waits
do
  local fps, N = 30, 108000
  local bad_lit, bad_sum, bad_mul, first_sum = 0, 0, 0, nil
  local cur = 0
  for i = 0, N - 1 do
    local t = i / fps
    if t < i * (1 / fps) then bad_mul = bad_mul + 1 end  -- boundary written as i*(1/fps)
    if t < cur then bad_sum = bad_sum + 1; first_sum = first_sum or i end -- boundary = accumulated wait(1/fps)
    cur = cur + 1 / fps
  end
  print(("(c) 0..%d at 30fps: frames before a boundary written i*(1/30): %d; before an accumulated wait(1/30) cursor: %d (first at frame %s); drift at end = %.3g s"):format(N-1, bad_mul, bad_sum, tostring(first_sum), cur - N / fps))
  local i = 107999
  print(("(c) frame 107999: t=%.17g; 3599+29/30=%.17g equal=%s"):format(i / 30, 3599 + 29 / 30, tostring(i / 30 == 3599 + 29 / 30)))
  -- 29.97
  local f = 30000 / 1001
  local mis = 0
  for k = 0, N - 1 do local t = k / f; if math.floor(t * f) ~= k then mis = mis + 1 end end
  print(("(c) fps=30000/1001: frames where floor((i/fps)*fps) ~= i: %d of %d"):format(mis, N))
end
-- game: steps per frame and seek replay
do
  local G = require("moonsplice.game")
  for _, cfg in ipairs({ { 60, 30 }, { 60, 24 }, { 50, 30 }, { 60, 29.97 } }) do
    local rate, fps = cfg[1], cfg[2]
    local seq = {}
    local mism = 0
    for i = 0, 107999 do
      local t = i / fps
      local want = math.floor(t * rate + 1e-9)
      local exact = math.floor(i * rate / fps) -- integer-rational truth when fps integral
      if fps == math.floor(fps) and want ~= exact then mism = mism + 1 end
      if i <= 6 then seq[#seq + 1] = want end
    end
    print(("game rate=%g fps=%g: steps at frames 0..6 = %s; mismatches vs integer floor(i*rate/fps) over 108000 frames: %d"):format(rate, fps, table.concat(seq, ","), mism))
  end
end
