-- The offline render, main.lua's render and hash modes: fixed-dt frames, in order or shuffled, to ffmpeg's stdin
-- (an mp4) or to an md5 per frame. Returns offline(comp, opts).
local painter -- required on the first render, after the engine's modules boot

local function frame_order(n, shuffle)
  local order = {}
  for i = 0, n - 1 do order[#order + 1] = i end
  if shuffle then
    -- deterministic rotation-based scramble (no RNG): thirds swapped
    local a, b, c = {}, {}, {}
    for _, i in ipairs(order) do
      if i % 3 == 0 then a[#a + 1] = i elseif i % 3 == 1 then b[#b + 1] = i else c[#c + 1] = i end
    end
    order = {}
    for _, t in ipairs({ c, a, b }) do
      for _, i in ipairs(t) do order[#order + 1] = i end
    end
  end
  return order
end

local function offline(comp, opts)
  painter = painter or require("painter")
  local fps = opts.fps or comp.fps
  local n = math.floor(comp.duration * fps + 0.5)
  local canvas = love.graphics.newCanvas(comp.width, comp.height)
  -- zero-copy pipe: C popen + fwrite straight from the ImageData pointer
  -- (io.popen + getString = an 8.3MB Lua string per frame; measured 22ms/frame)
  local ffi = require("ffi")
  ffi.cdef([[
    typedef struct FILE FILE;
    FILE *popen(const char *command, const char *mode);
    size_t fwrite(const void *ptr, size_t size, size_t nitems, FILE *stream);
    int pclose(FILE *stream);
  ]])
  -- audio clips mix at encode via ffmpeg filter_complex; engine never touches them
  local audio_nodes = {}
  for _, n in ipairs(comp.nodes) do
    if n.kind == "audio" or n.kind == "tts" or n.kind == "sfx" or n.kind == "music" then
      audio_nodes[#audio_nodes + 1] = n
    end
  end

  local pipe, outfile, video_target
  if opts.mode == "render" then
    local out = opts.out or "out.mp4"
    if not out:match("^/") then out = (os.getenv("MOONSPLICE_CWD") or ".") .. "/" .. out end
    outfile = out
    video_target = #audio_nodes > 0 and (out .. ".video.tmp.mp4") or out
    out = video_target
    -- quality tiers: draft = hw encode (VideoToolbox, near-zero CPU),
    -- standard = x264 veryfast crf18, high = x264 slow crf17
    local q = os.getenv("MOONSPLICE_QUALITY") or "standard"
    local venc
    if q == "draft" then
      venc = "-c:v h264_videotoolbox -b:v 12M"
    elseif q == "high" then
      venc = "-c:v libx264 -preset slow -threads 0 -crf 17"
    else
      venc = "-c:v libx264 -preset veryfast -threads 0 -crf 18"
    end
    local cmd = string.format(
      "ffmpeg -hide_banner -loglevel error -y -f rawvideo -pixel_format rgba" ..
      " -video_size %dx%d -framerate %d -i - %s" ..
      " -pix_fmt yuv420p -colorspace bt709 -movflags +faststart '%s'",
      comp.width, comp.height, fps, venc, out)
    pipe = ffi.C.popen(cmd, "w")
    assert(pipe ~= nil, "moonsplice: ffmpeg pipe failed")
  end

  local prof = (os.getenv("MOONSPLICE_PROFILE")) and { draw = 0, read = 0, out = 0 }
  local clock = love.timer.getTime
  local gfx = love.graphics
  -- LÖVE 12 renamed canvas readback; async variant enables pipelining
  local readback_sync = gfx.readbackTexture and function(c) return gfx.readbackTexture(c) end
    or function(c) return c:newImageData() end
  local use_async = opts.mode == "render" and gfx.readbackTextureAsync ~= nil

  local function emit(img, i, keep)
    if opts.mode == "hash" then
      local md5 = love.data.encode("string", "hex", love.data.hash("md5", img:getString()))
      io.write(("FRAME %d %s\n"):format(i, md5))
    else
      ffi.C.fwrite(img:getFFIPointer(), 1, img:getSize(), pipe)
    end
    if not keep then img:release() end
  end
  local direct = (os.getenv("MOONSPLICE_SCENE_DIRECT") or "1") ~= "0"
    and painter.scene_direct_ok and painter.scene_direct_ok(comp)
  if direct and prof then io.write("PROF direct=1 (no canvas, no readback)\n") end
  -- Off the direct path is LÖVE's canvas path, and LÖVE is gone: name what put the comp there.
  if not direct and MOONSPLICE_NOT_PORTED then
    MOONSPLICE_NOT_PORTED(painter.scene_blocker and painter.scene_blocker(comp) or "the canvas path")
  end

  local pending = {} -- async readbacks in flight, ordered
  local function flush_pending(max_left)
    while #pending > 0 do
      local head = pending[1]
      if #pending <= max_left and not head.rb:isComplete() then break end
      head.rb:wait()
      emit(head.rb:getImageData(), head.i)
      table.remove(pending, 1)
    end
  end

  local t0 = clock()
  for _, i in ipairs(frame_order(n, opts.shuffle)) do
    local t = i / fps
    comp:evaluate(t)
    local p1 = prof and clock()
    if direct then
      local img = painter.scene_direct(comp, t)
      local p2 = prof and clock()
      emit(img, i, true)
      if prof then prof.draw = prof.draw + (p2 - p1); prof.out = prof.out + (clock() - p2) end
      goto continue
    end
    gfx.setCanvas({ canvas, stencil = true })
    painter.draw_scene(comp, t)
    gfx.setCanvas()
    painter.prefetch(comp, (i + 1) / fps) -- decode-ahead overlaps readback+encode
    local p2 = prof and clock()
    if use_async then
      pending[#pending + 1] = { i = i, rb = gfx.readbackTextureAsync(canvas) }
      flush_pending(2) -- keep ≤2 in flight; pop whatever is already complete
      if prof then prof.read = prof.read + (clock() - p2) end
    else
      local img = readback_sync(canvas)
      local p3 = prof and clock()
      if prof then prof.read = prof.read + (p3 - p2) end
      emit(img, i)
      if prof then prof.out = prof.out + (clock() - p3) end
    end
    if prof then prof.draw = prof.draw + (p2 - p1) end
    ::continue::
  end
  flush_pending(0)
  local wall = love.timer.getTime() - t0
  if pipe then ffi.C.pclose(pipe) end

  -- audio mix + mux pass
  if opts.mode == "render" and #audio_nodes > 0 then
    local function shell(cmd)
      local p = assert(_MOONSPLICE_POPEN(cmd .. " 2>&1", "r"))
      local o = p:read("*a")
      local ok = p:close()
      return ok, o
    end
    -- Three buses: the voice, anything that must duck under it (system/source
    -- audio), and everything else. Ducking is a real sidechain compressor keyed
    -- off the voice bus, not a static volume — the dub drops only while someone
    -- is actually speaking and comes straight back up.
    local inputs, chains = {}, {}
    local vo_labels, duck_labels, plain_labels, duck_cfg = {}, {}, {}, {}
    for k, node in ipairs(audio_nodes) do
      local i = node.initial
      inputs[#inputs + 1] = ("-i '%s'"):format(node.afile)
      local dur = math.min(i.duration, comp.duration - i.at)
      local fades = ""
      if i.fade_in > 0 then fades = fades .. (",afade=t=in:st=0:d=%f"):format(i.fade_in) end
      if i.fade_out > 0 then
        fades = fades .. (",afade=t=out:st=%f:d=%f"):format(dur - i.fade_out, i.fade_out)
      end
      -- normalize rate/layout: sidechaincompress needs both inputs to agree
      chains[#chains + 1] = string.format(
        "[%d:a]atrim=start=%f:duration=%f,asetpts=PTS-STARTPTS,volume=%f%s,adelay=%d:all=1," ..
        "aformat=sample_fmts=fltp:sample_rates=44100:channel_layouts=stereo[a%d]",
        k - 1, i.media_start, dur, i.volume, fades, math.floor(i.at * 1000 + 0.5), k)
      local lab = ("[a%d]"):format(k)
      if i.bus == "vo" then
        vo_labels[#vo_labels + 1] = lab
      elseif i.duck then
        duck_labels[#duck_labels + 1] = lab
        duck_cfg[#duck_cfg + 1] = (type(i.duck) == "table") and i.duck or {}
      else
        plain_labels[#plain_labels + 1] = lab
      end
    end

    local final = {}
    if #duck_labels > 0 and #vo_labels > 0 then
      -- sidechaincompress ends with its SHORTER input, so a key that runs out
      -- would truncate the source it is ducking. Pad the key to full length.
      chains[#chains + 1] = table.concat(vo_labels) ..
        string.format("amix=inputs=%d:duration=longest:normalize=0," ..
          "apad=whole_dur=%f[vobus]", #vo_labels, comp.duration)
      -- one copy for the mix, one sidechain key per ducked source
      local splits = { "[vomix]" }
      for j = 1, #duck_labels do splits[#splits + 1] = ("[vosc%d]"):format(j) end
      chains[#chains + 1] = ("[vobus]asplit=%d%s"):format(#splits, table.concat(splits))
      for j, lab in ipairs(duck_labels) do
        local c = duck_cfg[j]
        chains[#chains + 1] = string.format(
          "%s[vosc%d]sidechaincompress=threshold=%f:ratio=%f:attack=%f:release=%f:makeup=1[d%d]",
          lab, j, c.threshold or 0.02, c.ratio or 9, c.attack or 12, c.release or 320, j)
        final[#final + 1] = ("[d%d]"):format(j)
      end
      final[#final + 1] = "[vomix]"
    else
      for _, l in ipairs(vo_labels) do final[#final + 1] = l end
      for _, l in ipairs(duck_labels) do final[#final + 1] = l end
    end
    for _, l in ipairs(plain_labels) do final[#final + 1] = l end

    -- asetpts after amix is load-bearing: amix hands on the timestamps of its
    -- delayed inputs, and the encoder then writes a file a few ms long. Any clip
    -- with a non-zero `at` (i.e. adelay > 0) is lost without this. Regenerating
    -- the pts from the sample count is what makes a delayed mix survive. The
    -- voice bus above needs no such fix: apad follows it and it feeds this amix.
    local filter = table.concat(chains, ";") .. ";" ..
      table.concat(final) ..
      string.format("amix=inputs=%d:duration=longest:normalize=0,asetpts=N/SR/TB," ..
        "atrim=duration=%f,apad=whole_dur=%f[mix]", #final, comp.duration, comp.duration)
    local mixfile = outfile .. ".mix.tmp.m4a"
    local ok, o = shell(string.format(
      "ffmpeg -hide_banner -loglevel error -y %s -filter_complex \"%s\" -map '[mix]'" ..
      " -c:a aac -b:a 192k '%s'", table.concat(inputs, " "), filter, mixfile))
    if not ok then error("moonsplice: audio mix failed:\n" .. o) end
    -- apad pads to comp.duration, so a short mix means the chain dropped audio
    -- on the floor. Fail loudly rather than mux a silent track.
    local _, dur = shell(string.format(
      "ffprobe -v error -show_entries format=duration -of csv=p=0 '%s'", mixfile))
    local got = tonumber((dur or ""):match("[%d.]+") or "")
    if not got or got < comp.duration * 0.9 then
      error(string.format("moonsplice: audio mix produced %ss of a %.3fs comp -- the filter chain dropped audio:\n%s",
        tostring(got), comp.duration, filter))
    end
    ok, o = shell(string.format(
      "ffmpeg -hide_banner -loglevel error -y -i '%s' -i '%s' -map 0:v -map 1:a" ..
      " -c copy -movflags +faststart '%s'", video_target, mixfile, outfile))
    if not ok then error("moonsplice: mux failed:\n" .. o) end
    os.remove(video_target)
    os.remove(mixfile)
    io.write(("AUDIO mixed %d clip(s) -> %s\n"):format(#audio_nodes, outfile))
  end
  io.write(("DONE frames=%d wall=%.2fs fps=%.1f mode=%s\n"):format(n, wall, n / wall, opts.mode))
  if prof then
    io.write(("PROF draw=%.2fs read=%.2fs out=%.2fs other=%.2fs (per-frame ms: draw=%.1f read=%.1f out=%.1f)\n")
      :format(prof.draw, prof.read, prof.out, wall - prof.draw - prof.read - prof.out,
        prof.draw / n * 1000, prof.read / n * 1000, prof.out / n * 1000))
    if painter.scene_time then
      io.write(("PROF scene=%.2fs flushes=%d (per-frame ms: scene=%.2f)\n")
        :format(painter.scene_time, painter.scene_flushes or 0, painter.scene_time / n * 1000))
    end
  end
  io.flush()
end

return offline
