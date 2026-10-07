-- serve: a long-lived frame + outline server for Moonsplice Studio.
--
-- The app never shells out per frame. It starts one of these per open composition and
-- talks to it over stdin/stdout:
--
--   stdin   one JSON request per line: {"op":"frame","t":1.5} | {"op":"outline"}
--                                     | {"op":"media"} | {"op":"reload"} | {"op":"ping"}
--   stdout  one reply line per request, always prefixed `CS ` so a stray print from
--           resolve or a native helper can be skipped by the reader rather than
--           corrupting the stream:
--
--             CS frame <path> <w> <h> <bytes> <seq> [evaluate_us draw_us write_us]
--             CS json  <path> <bytes> <seq>
--             CS ok    <seq>
--             CS err   <seq> <one-line message>
--
-- Payloads land in files under MOONSPLICE_SERVE_DIR, in a small ring of slots, because an
-- 8 MB RGBA frame on a pipe interleaved with text is a parser waiting to break. The host
-- reads the file and does not care that it was a file.
--
-- This process is the seam .robot/docs/desktop.robot §7 needs: the protocol says nothing about LÖVE,
-- so the love-free renderer replaces the inside of this file and the app does not notice.

local S = {}

local ffi = require("ffi")
local bit = require("bit")
ffi.cdef([[
  // Variadic, and declared that way on purpose: on arm64 a fixed argument goes in a register
  // and a variadic one goes on the stack, so declaring the mode as a plain int hands `open` a
  // mode nobody asked for -- which showed up as frames the host could not read.
  int open(const char *path, int flags, ...);
  int close(int fd);
  int ftruncate(int fd, long length);
  void *mmap(void *addr, size_t len, int prot, int flags, int fd, long offset);
  int munmap(void *addr, size_t len);
  typedef long cs_time_t;
  struct cs_timeval { cs_time_t tv_sec; int tv_usec; };
  int gettimeofday(struct cs_timeval *tv, void *tz);
  typedef struct FILE FILE;
  FILE *fopen(const char *path, const char *mode);
  size_t fwrite(const void *ptr, size_t size, size_t nitems, FILE *stream);
  int fclose(FILE *stream);
]])

local SLOTS = 6

-- the JSON encoder lives in serve/json.lua; bound below once the parts have loaded
local encode

local function clip(s, n)
  s = tostring(s):gsub("%s+", " ")
  if #s <= n then return s end
  return s:sub(1, n - 1) .. "\u{2026}"
end

-- A frame goes into a mapped file, not through a write.
--
-- The ring was `fopen`/`fwrite`/`fclose` per frame, which truncates and rewrites the file every
-- time: measured at 18 ms for one 1280x720 frame against 1.2 ms to render it, so the path that
-- exists to hand a frame over cost fifteen times what making the frame cost. Mapped, the same
-- handover is a memcpy into pages the host already shares -- no syscall, no allocation, and the
-- reader on the other side sees them through the same page cache.
--
-- The fallback is the old write, because a mapping can fail (a filesystem that will not map, a
-- sandbox) and a preview that is slow is better than a preview that is not there.
local MAP = {}                 -- path -> { fd = , ptr = , size = }
local O_RDWR, O_CREAT = 2, (ffi.os == "OSX" and 0x0200 or 0x40)
local PROT_RW, MAP_SHARED = 3, 1

local function unmap(m)
  if m.ptr ~= nil then ffi.C.munmap(m.ptr, m.size) end
  if m.fd and m.fd >= 0 then ffi.C.close(m.fd) end
end

local function mapped(path, size)
  local m = MAP[path]
  if m and m.size == size then return m end
  if m then unmap(m) end
  local fd = ffi.C.open(path, bit.bor(O_RDWR, O_CREAT), ffi.new("int", 420))  -- 0644
  if fd < 0 then return nil end
  if ffi.C.ftruncate(fd, size) ~= 0 then ffi.C.close(fd); return nil end
  local ptr = ffi.C.mmap(nil, size, PROT_RW, MAP_SHARED, fd, 0)
  if ptr == nil or ffi.cast("intptr_t", ptr) == -1 then ffi.C.close(fd); return nil end
  m = { fd = fd, ptr = ptr, size = size }
  MAP[path] = m
  return m
end

-- Inside the host's own process (engine/src/session.rs) there is no file to share: the host
-- copies the bytes straight out of the frame and keeps them under the path the reply names.
local hand = ENGINE_HAND

local function write_bytes(path, ptr, size)
  if hand then
    hand(path, tonumber(ffi.cast("uintptr_t", ptr)), size)
    return true
  end
  local m = mapped(path, size)
  if m then
    ffi.copy(m.ptr, ptr, size)
    return true
  end
  local f = ffi.C.fopen(path, "wb")
  if f == nil then return false, "cannot open " .. path end
  ffi.C.fwrite(ptr, 1, size, f)
  ffi.C.fclose(f)
  return true
end

local function write_text(path, text)
  if hand then
    hand(path, text)
    return true
  end
  local open = _MOONSPLICE_IOOPEN or io.open
  local f = open(path, "wb")
  if not f then return false, "cannot open " .. path end
  f:write(text)
  f:close()
  return true
end

-- `reload` re-reads the file from disk, which is how an agent edit and an outside editor
-- both reach the preview: there is one representation and this re-reads it.
function S.run(comp, opts, painter, load_comp)
  local dir = os.getenv("MOONSPLICE_SERVE_DIR")
  assert(dir and dir ~= "", "moonsplice serve: MOONSPLICE_SERVE_DIR must name a writable directory")
  local read = _MOONSPLICE_IOREAD or io.read
  local json = require("moonsplice.json")
  local gfx = love.graphics
  local readback = gfx.readbackTexture and function(c) return gfx.readbackTexture(c) end
    or function(c) return c:newImageData() end

  local state = { comp = comp, canvas = nil, canvas_w = nil, direct = nil }

  local function prepare(c)
    state.comp = c
    state.direct = (os.getenv("MOONSPLICE_SCENE_DIRECT") or "1") ~= "0"
      and painter.scene_direct_ok and painter.scene_direct_ok(c)
    if state.canvas then state.canvas:release() end
    state.canvas, state.canvas_w = nil, nil
  end
  prepare(comp)

  -- A preview is not the render.
  --
  -- A frame costs what the frame is big: measured on a ten minute 1080p edit, one frame is 87 ms
  -- at 1920x1080 and 38 ms at 960x540, and swapping the clip for a 64x64 source saves 10 -- so
  -- what the preview spends its time on is rasterising pixels nobody is going to see, because the
  -- pane is half the size of the composition. Every editor answers this the same way and calls it
  -- playback resolution: draw the preview at the size of the window.
  --
  -- The scale is the caller's, per request, and 1 unless asked for -- a render, a golden and a
  -- verify all ask for the composition's own size and get exactly what they got before.
  local function canvas_for(w, h)
    if state.canvas_w ~= w then
      if state.canvas then state.canvas:release() end
      state.canvas = gfx.newCanvas(w, h)
      state.canvas_w = w
    end
    return state.canvas
  end

  local slot = 0
  local function next_slot(ext)
    slot = (slot + 1) % SLOTS
    return string.format("%s/s%d.%s", dir, slot, ext)
  end

  local function reply(line)
    io.write("CS " .. line .. "\n")
    io.flush()
  end

  -- Where a frame's time went, in microseconds, sent back with the frame.
  --
  -- On the wall clock, not `love.timer`: this host's timer is the composition's clock, which is
  -- deterministic and does not move between frames -- exactly the property a comp needs, and
  -- exactly the wrong instrument for asking how long a frame took.
  --
  -- The host can time the round trip, but a round trip is one number and a slow frame has four
  -- possible causes: evaluating the composition, drawing it, reading it back off the GPU, and
  -- writing it where the host can pick it up. Measuring here is the only place the four are
  -- separable, and `editor/src-tauri/src/perf.rs` puts them on the same trace as everything
  -- that happens after.
  local tv = ffi.new("struct cs_timeval[1]")
  local function clock()
    ffi.C.gettimeofday(tv, nil)
    return tonumber(tv[0].tv_sec) * 1e6 + tonumber(tv[0].tv_usec)
  end
  local function us(a, b) return math.floor(b - a + 0.5) end

  local function frame(t, want_w)
    local c = state.comp
    t = math.max(0, math.min(t or 0, c.duration))
    local t0 = clock()
    c:evaluate(t)
    local t1 = clock()
    -- Never up: a pane wider than the composition gets the composition, and the window scales it
    -- the way it scales everything else.
    -- The scale is the caller's, and it reaches the rasterizer rather than the canvas: the
    -- picture is drawn at the size of the pane instead of being drawn at the composition's size
    -- and then shrunk. Never up -- a pane wider than the composition gets the composition.
    local scale = 1
    if want_w and want_w > 0 and want_w < c.width then
      scale = want_w / c.width
    end
    local fw = math.max(1, math.floor(c.width * scale + 0.5))
    local fh = math.max(1, math.floor(c.height * scale + 0.5))
    local img
    painter.preview_scale = scale
    if state.direct then
      img = painter.scene_direct(c, t)
    else
      -- On the canvas path the rasterized layers arrive already scaled; the love transform is
      -- what scales everything the scene crate does not own -- the perspective cards, the
      -- shaders -- so both halves of a mixed composition land in the same place.
      local canvas = canvas_for(fw, fh)
      gfx.setCanvas({ canvas, stencil = true })
      gfx.push()
      gfx.scale(scale, scale)
      painter.draw_scene(c, t)
      gfx.pop()
      gfx.setCanvas()
      img = readback(canvas)
    end
    painter.preview_scale = 1
    -- Asked for here, and not only because the release below needs it: on the GPU path the
    -- readback is queued rather than done, and this is the line that waits for it. Timing the
    -- call alone said drawing took no time at all and writing the file took sixty milliseconds,
    -- which is a measurement of where the stall surfaced rather than of what was slow.
    local bytes = img:getSize()
    local t2 = clock()
    local scaled = not state.direct
    local path = next_slot("rgba")
    -- (The size is read before the release, never after: the last line used to call `getSize()`
    -- on an image it had just released, so the first frame of any comp holding a clip came back
    -- as "Cannot use object after it has been released".)
    local ok, err = write_bytes(path, img:getFFIPointer(), bytes)
    local t3 = clock()
    if scaled then img:release() end
    if not ok then return nil, err end
    return path, fw, fh, bytes, us(t0, t1), us(t1, t2), us(t2, t3)
  end

  -- Ready before the first request, so the host knows the process is up and what it holds.
  reply(string.format("ready %d %d %.6f %d", comp.width, comp.height, comp.duration, comp.fps))

  while true do
    local line = read("*l")
    if not line then return 0 end
    if line ~= "" then
      local seq, req = 0, nil
      local ok, err = pcall(function()
        req = json.decode(line)
      end)
      if not ok or type(req) ~= "table" then
        reply(string.format("err %d request is not JSON: %s", seq, tostring(err):gsub("\n", " ")))
      else
        seq = tonumber(req.seq) or 0
        local op = req.op
        if op == "ping" then
          reply(string.format("ok %d", seq))
        elseif op == "frame" then
          local fok, path, w, h, bytes, ev, dr, wr = pcall(frame, tonumber(req.t) or 0, tonumber(req.w))
          if fok and path then
            -- The three costs ride along after the sequence number. A reader that does not know
            -- about them stops at `seq`, which is what makes this additive rather than a version.
            reply(string.format("frame %s %d %d %d %d %d %d %d", path, w, h, bytes, seq, ev, dr, wr))
          else
            reply(string.format("err %d %s", seq, tostring(path or w):gsub("\n", " ")))
          end
        elseif op == "outline" then
          local ook, doc = pcall(function()
            return encode(S.outline(state.comp, {
              direct = state.direct,
              source_hash = req.source_hash,
              path = opts.comp_rel or opts.comp,
            }))
          end)
          if ook then
            local path = next_slot("json")
            local wok, werr = write_text(path, doc)
            if wok then
              reply(string.format("json %s %d %d", path, #doc, seq))
            else
              reply(string.format("err %d %s", seq, tostring(werr)))
            end
          else
            reply(string.format("err %d %s", seq, tostring(doc):gsub("\n", " ")))
          end
        elseif op == "media" then
          -- Where each thing's file actually is. This is the one reply that carries paths, and
          -- it goes to the host and stops there: the host needs them (to read a waveform off a
          -- sound, to hand bytes to a viewer) and the window must never see one. Keeping it a
          -- separate op is what makes that rule structural rather than a habit -- the outline,
          -- which does go to the window, has no `src` in it and cannot grow one by accident.
          local mok, doc = pcall(function()
            local found = {}
            for _, n in ipairs(state.comp.nodes) do
              local file = n.afile or n.file
              if file then found[n.id] = file end
            end
            return encode(found)
          end)
          if mok then
            local path = next_slot("json")
            local wok, werr = write_text(path, doc)
            if wok then
              reply(string.format("json %s %d %d", path, #doc, seq))
            else
              reply(string.format("err %d %s", seq, tostring(werr)))
            end
          else
            reply(string.format("err %d %s", seq, tostring(doc):gsub("\n", " ")))
          end
        elseif op == "at" then
          local aok, doc = pcall(function()
            return encode(S.at(state.comp, tonumber(req.t) or 0))
          end)
          if aok then
            local path = next_slot("json")
            local wok, werr = write_text(path, doc)
            if wok then
              reply(string.format("json %s %d %d", path, #doc, seq))
            else
              reply(string.format("err %d %s", seq, tostring(werr)))
            end
          else
            reply(string.format("err %d %s", seq, tostring(doc):gsub("\n", " ")))
          end
        elseif op == "reload" then
          -- `load_comp` bans io and the clock inside the composition's sandbox by replacing the
          -- globals, so a second load would find its own bans in place and fail on the inputs
          -- sidecar. The host's own references are put back first.
          io.open, io.read, io.popen = _MOONSPLICE_IOOPEN, read, _MOONSPLICE_POPEN
          local rok, c = pcall(load_comp, opts.comp, opts.fps, opts)
          if rok then
            c.render_fps = opts.fps or c.fps
            prepare(c)
            reply(string.format("ok %d", seq))
          else
            reply(string.format("err %d %s", seq, tostring(c):gsub("\n", " ")))
          end
        elseif op == "input" then
          -- live play: events for the game, timed by the caller in seconds of the game
          local g = state.comp.game
          if not g then
            reply(string.format("err %d this composition is not a game", seq))
          else
            for _, e in ipairs(req.events or {}) do g:push(e) end
            reply(string.format("ok %d", seq))
          end
        elseif op == "log" then
          -- the session played so far, to save and render as a recording
          local g = state.comp.game
          local lok, doc = pcall(function()
            if not g then error("this composition is not a game") end
            return encode({ events = g:recorded(), rate = g.rate })
          end)
          if lok then
            local path = next_slot("json")
            local wok, werr = write_text(path, doc)
            if wok then reply(string.format("json %s %d %d", path, #doc, seq))
            else reply(string.format("err %d %s", seq, tostring(werr))) end
          else
            reply(string.format("err %d %s", seq, tostring(doc):gsub("\n", " ")))
          end
        elseif op == "quit" then
          return 0
        else
          reply(string.format("err %d unknown op %s", seq, tostring(op)))
        end
      end
    end
  end
end

-- what the parts share, and the parts (they load after this table is registered as serve)
S._ = {
  clip = clip, hand = hand,
}
package.loaded["serve"] = S
require("serve.json")
require("serve.outline")
encode = S.encode

return S
