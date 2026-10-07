-- Lint's frame-grid sampling: the comp at every frame of the sampling rate, each node's state and box, and the
-- motion amplitude between samples by motion group. Sets ctx.at, ct, live, ever_live, states and amp.
-- Part of moonsplice.lint (core/moonsplice/lint/init.lua): L.run calls it with its context, ctx.
local L = require("moonsplice.lint")
local Clip, BOXED = L._.Clip, L._.BOXED

return function(ctx)
  local comp, fps, dur, n_samples = ctx.comp, ctx.fps, ctx.dur, ctx.n_samples
  local visual, tdims = ctx.visual, ctx.tdims
  -- Recording builder: same verbs as core/runtime/scene.lua and core/runtime/vector.lua,
  -- but it only accumulates the numbers. Calling draw(v, t) with it at each
  -- sample makes the callback's motion measurable (diff of command streams).
  local Rec = {}
  Rec.__index = Rec
  local function rec_col(c)
    if type(c) == "string" then c = require("moonsplice.color").parse(c) end
    c = c or { 1, 1, 1, 1 }
    return c[1], c[2], c[3], c[4] or 1
  end
  -- one entry per verb: { verb, n1, n2, ... } so streams align by command,
  -- not by raw index (a draw-on that appends a point must not shift the rest)
  local function cmd(self, verb, ...)
    local e = { verb }
    for i = 1, select("#", ...) do
      local v = select(i, ...)
      if type(v) == "number" then e[#e + 1] = v end
    end
    self.n[#self.n + 1] = e
  end
  function Rec:reset() self.n = {} end
  function Rec:rect(x, y, w, h, c, rad) cmd(self, "rect", x, y, w, h, rad or 0, rec_col(c)) end
  function Rec:circle(cx, cy, r, c) cmd(self, "circle", cx, cy, r, rec_col(c)) end
  function Rec:move(x, y) cmd(self, "move", x, y) end
  function Rec:line(x, y) cmd(self, "line", x, y) end
  function Rec:curve(x1, y1, x2, y2, x, y) cmd(self, "curve", x1, y1, x2, y2, x, y) end
  function Rec:fill(c) cmd(self, "fill", rec_col(c)) end
  function Rec:stroke(w, c) cmd(self, "stroke", w, rec_col(c)) end
  function Rec:polyline(pts, w, c)
    for i = 1, #pts - 1, 2 do cmd(self, i == 1 and "move" or "line", pts[i], pts[i + 1]) end
    cmd(self, "stroke", w or 2, rec_col(c))
  end
  function Rec:gradient(x, y, w, h, x0, y0, x1, y1, c0, c1)
    local r0, g0, b0, a0 = rec_col(c0); cmd(self, "gradient", x, y, w, h, x0, y0, x1, y1, r0, g0, b0, a0, rec_col(c1))
  end
  function Rec:radial(cx, cy, r, c0, c1)
    local r0, g0, b0, a0 = rec_col(c0); cmd(self, "radial", cx, cy, r, r0, g0, b0, a0, rec_col(c1))
  end
  function Rec:grain(amount, seed) cmd(self, "grain", amount, seed or 1) end
  function Rec:image(id, x, y, w, h, rx, a) cmd(self, "image", id, x, y, w, h, rx or 0, a or 1) end
  function Rec:clip_push(x, y, w, h, rx) cmd(self, "clip", x, y, w, h, rx or 0) end
  function Rec:clip_pop() end
  function Rec:pop() end
  function Rec:transform(m) cmd(self, "transform", unpack(m)) end
  function Rec:clear(c) cmd(self, "clear", rec_col(c)) end
  local function record_draw(n, t)
    local fn = n.initial.draw
    if type(fn) ~= "function" then return nil end
    local b = setmetatable({ n = {} }, Rec)
    local ok = pcall(fn, b, t, n)
    if not ok then return nil end
    return b.n
  end
  -- amplitude between two recorded streams: mean per-command displacement over
  -- the node box (a box moving 7px reads like a rect node moving 7px), plus a
  -- structural term when the command sequence itself changes shape.
  local function stream_delta(p, q, box)
    if not p or not q then return 0 end
    local m = math.min(#p, #q)
    local peak, mismatch = 0, 0
    for i = 1, m do
      local a, b = p[i], q[i]
      if a[1] ~= b[1] then
        mismatch = mismatch + 1
      else
        local k = math.min(#a, #b)
        local acc = 0
        for j = 2, k do acc = acc + math.abs(b[j] - a[j]) end
        if k > 1 and acc / (k - 1) > peak then peak = acc / (k - 1) end
      end
    end
    -- the most-moved command sets the amplitude: "is anything moving, how fast"
    local d = peak / box
    local ln = math.max(#p, #q)
    if ln > 0 then d = d + ((math.abs(#p - #q) + mismatch) / ln) * 0.25 end
    if d > 1 then d = 1 end
    return d
  end

  -- the whole comp at t: clips' local times, the timeline, then the game and its views (what they
  -- set is motion too)
  local function at(t)
    if comp.evaluate and ((comp._views and #comp._views > 0) or comp.game or comp._clips) then comp:evaluate(t)
    else comp.timeline:evaluate(t) end
  end
  -- a key time on a node, in comp time: under a clip it is local, and the clip says when it plays
  -- (nil when the clip never shows it)
  local function ct(node, t) return Clip.to_comp(comp, node, t) end
  -- a node shows only while every clip around it plays
  local function live(n)
    if n.clock and not n.clock._live then return false end
    return n._live ~= false
  end
  local ever_live = {}

  -- ============ frame-grid sampling ============
  -- states[s][node] = {x,y,op,scale,size,w,h,r, visible, bx0,by0,bx1,by1}
  local states = {}
  for s = 0, n_samples - 1 do
    local t = s / fps
    at(t)
    for _, c in ipairs(comp._clips or {}) do if c._live then ever_live[c] = true end end
    local row = {}
    for _, n in ipairs(visual) do
      local i = n.initial
      local g = function(p) local v = n.state[p]; if v == nil then v = i[p] end; return v end
      local op = g("opacity") or 1
      local vis = op > 0.01 and live(n)
      -- media under a clip plays in the clip's local time
      local lt = n.clock and n.clock._lt or t
      if (n.kind == "video" or n.kind == "lottie") and vis then
        vis = lt >= (i.from or 0) and lt < (i.from or 0) + (i.duration or dur)
      end
      local sc = g("scale") or 1
      local x, y = g("x") or 0, g("y") or 0
      local rot = g("rotation") or 0
      local w, h
      if n.kind == "circle" then
        local r = (g("r") or 0) * sc
        w, h = r * 2, r * 2
        row[n] = { x = x, y = y, op = op, vis = vis, sc = sc, rot = rot,
          bx0 = x - r, by0 = y - r, bx1 = x + r, by1 = y + r }
      elseif n.kind == "text" then
        local size = g("size") or 32
        local td = tdims[n]
        local tw = td and (td.w * size / td.size0) or (#(i.text or "") * size * 0.55)
        local th = td and (td.h * size / td.size0) or size * 1.2
        tw, th = tw * sc, th * sc
        local ox = i.anchor == "center" and -tw / 2 or 0
        local oy = i.anchor == "center" and -th / 2 or 0
        row[n] = { x = x, y = y, op = op, vis = vis, sc = sc, size = size, rot = rot,
          bx0 = x + ox, by0 = y + oy, bx1 = x + ox + tw, by1 = y + oy + th }
      elseif BOXED[n.kind] then
        w, h = (g("w") or 0) * sc, (g("h") or 0) * sc
        local ox = i.anchor == "center" and -w / 2 or 0
        local oy = i.anchor == "center" and -h / 2 or 0
        row[n] = { x = x, y = y, op = op, vis = vis, sc = sc, w = w, h = h, rot = rot,
          bx0 = x + ox, by0 = y + oy, bx1 = x + ox + w, by1 = y + oy + h }
      else
        row[n] = { x = x, y = y, op = op, vis = vis, sc = sc, rot = rot }
      end
      local st = row[n]
      st.lt = lt
      st.reveal = g("reveal")
      st.progress = g("progress")
      st.outline, st.weight, st.tracking = g("outline"), g("weight"), g("tracking")
      if n.kind == "vector" and vis then st.stream = record_draw(n, t) end
    end
    states[s] = row
  end

  -- normalized motion amplitude per sample step, aggregated by motion GROUP
  -- (kinetic chars = one unit; energy-style sqrt scaling within a group)
  local amp = {}     -- amp[s][group] normalized
  local raw_amp = {} -- raw per-node (frozen detection)
  for s = 1, n_samples - 1 do
    local by_group = {} -- group -> {sum, n}
    local raw = {}
    for _, n in ipairs(visual) do
      local p, q = states[s - 1][n], states[s][n]
      if p and q and (p.vis or q.vis) then
        local d = math.abs(q.x - p.x) / comp.width + math.abs(q.y - p.y) / comp.height
          + math.abs((q.sc or 1) - (p.sc or 1)) + math.abs(q.op - p.op)
          + math.abs((q.rot or 0) - (p.rot or 0)) / math.pi
          + (q.size and p.size and math.abs(q.size - p.size) / 100 or 0)
        -- reveal (type-on) is motion: glyphs typed this step × glyph width, over frame width
        if q.reveal and p.reveal and q.reveal ~= p.reveal then
          local nchars = #((n.initial.text or ""):gsub("{[^}]*}", ""))
          local gw = (q.size or n.initial.size or 32) * 0.55
          d = d + math.abs(q.reveal - p.reveal) * nchars * gw / comp.width
        end
        -- stroked type breathing (outline/weight) and tracking are motion too
        if q.outline and p.outline then d = d + math.abs(q.outline - p.outline) end
        if q.weight and p.weight then d = d + math.abs(q.weight - p.weight) end
        if q.tracking and p.tracking and q.tracking ~= p.tracking then
          local nchars = #((n.initial.text or ""):gsub("{[^}]*}", ""))
          d = d + math.abs(q.tracking - p.tracking) * nchars / comp.width
        end
        if q.progress and p.progress and q.progress ~= p.progress then
          d = d + math.abs(q.progress - p.progress) / 100
        end
        -- vector draw callbacks: diff of the recorded command streams
        if n.kind == "vector" and (q.stream or p.stream) then
          local box = math.max(n.initial.w or comp.width, n.initial.h or comp.height, 1)
          d = d + stream_delta(p.stream, q.stream, box)
        end
        raw[n] = d
        local key = n._group or n
        local e = by_group[key] or { sum = 0, n = 0 }
        e.sum = e.sum + d
        e.n = e.n + 1
        by_group[key] = e
      end
    end
    local a = {}
    for key, e in pairs(by_group) do
      a[key] = e.sum / math.sqrt(e.n)
    end
    amp[s] = a
    raw_amp[s] = raw
  end

  ctx.at, ctx.ct, ctx.live, ctx.ever_live = at, ct, live, ever_live
  ctx.states, ctx.amp = states, amp
end
