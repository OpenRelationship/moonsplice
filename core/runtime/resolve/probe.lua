-- Probing media once: durations, sizes and audio energy, cached by content. Part of resolve.
local F = require("resolve.files")
local sh, sha1, cache_root, exists = F.sh, F.sha1, F.cache_root, F.exists

-- How long a file is, asked once.
--
-- This used to shell out to ffprobe every time it was called, which meant once per sound every
-- time the composition was loaded -- and the desktop app re-loads on every single edit, because
-- there is one representation and it re-reads it. A ten minute edit with seventy sounds in it
-- paid seventy subprocesses, four seconds, for every nudge of a clip. The duration of a file
-- does not change while nobody is writing to it, so it is remembered: in this process for the
-- reloads, and on disk for the next time the project is opened.
--
-- The key is the path and the size. A file replaced between runs by a different file of exactly
-- the same size would be read from the cache and be wrong; that is the trade, it is stated here,
-- and the alternative was four seconds a keystroke.
local probed = {}

local function file_size(path)
  local f = _MOONSPLICE_IOOPEN(path, "rb")
  if not f then return nil end
  local n = f:seek("end")
  f:close()
  return n
end

--- Where the remembered length of a file is kept.
local function probe_slot(file)
  local size = file_size(file)
  if not size then return nil end
  return cache_root() .. "/probe/" .. sha1(file .. "|" .. tostring(size)) .. ".txt"
end

--- What was remembered last time, if anything.
local function probe_recall(file)
  if probed[file] then return probed[file] end
  local slot = probe_slot(file)
  if not slot then return nil end
  local f = _MOONSPLICE_IOOPEN(slot, "r")
  if not f then return nil end
  local d = tonumber(f:read("*a"))
  f:close()
  if d then probed[file] = d end
  return d
end

--- Keep it, here and for next time. Best effort on disk: a cache that cannot be written is a
--- cache that is not used, not a failure, and the composition has its answer either way.
local function probe_keep(file, d)
  probed[file] = d
  local slot = probe_slot(file)
  if not slot then return end
  local f = _MOONSPLICE_IOOPEN(slot, "w")
  if f then
    f:write(tostring(d))
    f:close()
  end
end

--- Ask how long many files are at once.
---
--- ffprobe costs about sixty milliseconds of process start whatever it is asked about, and the
--- answers do not depend on each other. Seventy sounds asked one after another is four seconds of
--- a person looking at a blank window; asked eight at a time it is half a second. Anything that
--- does not answer is left out and falls back to being asked on its own, where it can fail with a
--- sentence about which file it was.
local function probe_many(files)
  if #files == 0 then return end
  local dir = cache_root() .. "/probe"
  sh(("mkdir -p '%s'"):format(dir))
  local list = dir .. "/.asking-" .. sha1(table.concat(files, "\n"))
  local f = _MOONSPLICE_IOOPEN(list, "w")
  if not f then return end
  for _, path in ipairs(files) do f:write(path, "\0") end
  f:close()
  -- Each answer is one short line written by one printf, which is atomic at this length, so the
  -- eight of them interleave safely.
  local runner = dir .. "/ask.sh"
  local rf = _MOONSPLICE_IOOPEN(runner, "w")
  if rf then
    rf:write([==[
#!/bin/sh
# Written by core/runtime/resolve.lua. How long is each of these, eight at a time.
exec xargs -0 -P 8 -n 1 sh -c 'printf "%s\t%s\n" "$0" "$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$0")"'
]==])
    rf:close()
  end
  local _, out = sh(("sh '%s' < '%s'"):format(runner, list))
  for line in tostring(out):gmatch("[^\n]+") do
    local path, secs = line:match("^(.*)\t([%d%.]+)$")
    local d = secs and tonumber(secs)
    if path and d then probe_keep(path, d) end
  end
  sh(("rm -f '%s'"):format(list))
end

local function ffprobe_duration(file)
  local known = probe_recall(file)
  if known then return known end
  local ok, out = sh(("ffprobe -v error -show_entries format=duration -of csv=p=0 '%s'"):format(file))
  local d = ok and tonumber(out:match("[%d%.]+"))
  if not d then error("moonsplice resolve: cannot probe duration of " .. file) end
  probe_keep(file, d)
  return d
end

local function bake_energy(file, start, dur)
  local rate = 50
  local key = sha1(table.concat({ tostring(file), tostring(start), tostring(dur), tostring(rate) }, "|"))
  local dst = cache_root() .. "/energy/" .. key .. ".f32"
  if not exists(dst) then
    assert(sh(("mkdir -p '%s/energy'"):format(cache_root())))
    local ok, out = sh(("ffmpeg -y -hide_banner -loglevel error -ss %s -t %s -i '%s' -ac 1 -ar %d -f f32le '%s'")
      :format(start or 0, dur, file, rate, dst))
    if not ok then error("moonsplice resolve: energy bake failed\n" .. out) end
  end
  local f = assert(_MOONSPLICE_IOOPEN(dst, "rb"), "moonsplice resolve: energy file missing")
  local raw = f:read("*a")
  f:close()
  local ffi = require("ffi")
  local n = math.floor(#raw / 4)
  local buf = ffi.new("uint8_t[?]", #raw)
  ffi.copy(buf, raw)
  local fl = ffi.cast("float*", buf)
  local samples, peak = {}, 0
  for i = 0, n - 1 do
    local v = math.abs(fl[i])
    samples[i + 1] = v
    if v > peak then peak = v end
  end
  if peak < 1e-6 then peak = 1 end
  for i = 1, #samples do samples[i] = samples[i] / peak end
  return samples
end


return {
  probe_recall = probe_recall,
  probe_many = probe_many,
  ffprobe_duration = ffprobe_duration,
  bake_energy = bake_energy,
}
