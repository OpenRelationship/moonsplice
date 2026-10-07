-- moonsplice sheet COMP OUT.png [--json] [--n 6] [--at T,T,...]: render the comp, take n frames at the middles
-- of n equal spans plus a frame at each --at time (seconds, or a fact reference such as beat:9, so a judge sees
-- the instants the expect rows name), sorted and deduplicated, and tile them three across with ffmpeg's xstack
-- (labelled with their times when ffmpeg has drawtext). Prints {"picks":[...],"seconds":s,"sheet":path,
-- "labelled":bool}, the line tablua's ports.moonsplice reads; picks lists every frame's time in sheet order.
local ffi = require("ffi")

ffi.cdef [[
  typedef struct { long tv_sec; int tv_usec; } ms_timeval;
  int gettimeofday(ms_timeval *tv, void *tz);
]]

local M = {}

local function now()
  local tv = ffi.new("ms_timeval")
  ffi.C.gettimeofday(tv, nil)
  return tonumber(tv.tv_sec) + tonumber(tv.tv_usec) / 1e6
end

local function read(cmd)
  local p = assert(io.popen(cmd))
  local s = p:read("*a")
  p:close()
  return s
end

-- "beat:9" (or "bed.beat:9") -> seconds, from the facts the comp derives; nil, why when none matches
local function facts_of(cli, comp, tmp)
  local f = tmp .. "/rows.json"
  if cli.run_engine({ "--rows", comp, "--json" }, "> " .. cli.q(f) .. " 2>/dev/null") ~= 0 then return {} end
  local h = io.open(f); if not h then return {} end
  local ok, d = pcall(require("moonsplice.json").decode, h:read("*a")); h:close()
  local map = {}
  for _, x in ipairs(ok and type(d) == "table" and d.derived or {}) do
    if x.pred and x.args and x.t0 then
      map[x.pred .. ":" .. x.args] = map[x.pred .. ":" .. x.args] or x.t0
      if x.asset then map[x.asset .. "." .. x.pred .. ":" .. x.args] = x.t0 end
    end
  end
  return map
end

function M.run(cli, args)
  local q = cli.q
  local comp, out = args[1], args[2]
  local n, at = 6, nil
  for i = 3, #args do
    if args[i] == "--n" then n = tonumber(args[i + 1]) or n end
    if args[i] == "--at" then at = args[i + 1] end
  end
  local tmp = read("mktemp -d"):gsub("%s+$", "")
  local t0 = now()
  local log = tmp .. "/log"
  -- the engine's output goes to a log: stdout carries only the sheet's JSON line
  local rc = cli.run_engine({ "--render", comp, "-o", tmp .. "/out.mp4" }, "> " .. q(log) .. " 2>&1")
  if rc ~= 0 then
    local l = read("cat " .. q(log))
    io.stderr:write((l:match("[^\n]*moonsplice error[^\n]*") or l:sub(-600)) .. "\n")
    os.execute("rm -rf " .. q(tmp))
    return rc
  end
  local dur = tonumber((read(("ffprobe -v error -show_entries format=duration -of csv=p=0 %s"):format(q(tmp .. "/out.mp4")))))
  if not dur then os.execute("rm -rf " .. q(tmp)); io.stderr:write("moonsplice sheet: no duration\n"); return 1 end
  local text = read("ffmpeg -hide_banner -filters 2>/dev/null"):find(" drawtext ") ~= nil
  -- the frame times: n regular picks, then every --at, sorted, one frame per distinct time
  local times, seen = {}, {}
  -- the last frame starts one frame before the end: a seek past it yields no frame, and ffmpeg still exits 0
  local num, den = read(("ffprobe -v error -select_streams v:0 -show_entries stream=r_frame_rate -of csv=p=0 %s")
    :format(q(tmp .. "/out.mp4"))):match("(%d+)/(%d+)")
  local fps = num and tonumber(den) > 0 and tonumber(num) / tonumber(den) or 30
  local last = math.max(0, dur - 1 / fps - 0.001)
  local function take(t)
    t = math.max(0, math.min(t, last))
    local k = ("%.3f"):format(t)
    if not seen[k] then seen[k] = true; times[#times + 1] = tonumber(k) end
  end
  for i = 0, n - 1 do take(dur * (i + 0.5) / n) end
  if at and at ~= "" then
    local facts
    for item in at:gmatch("[^,]+") do
      item = item:gsub("^%s+", ""):gsub("%s+$", "")
      local t = tonumber((item:gsub("s$", "")))
      if not t then
        facts = facts or facts_of(cli, comp, tmp)
        t = facts[item]
        if not t then
          os.execute("rm -rf " .. q(tmp))
          io.stderr:write(("moonsplice sheet: --at %s is neither seconds nor a fact the comp derives\n"):format(item))
          return 1
        end
      end
      take(t)
    end
  end
  table.sort(times)
  n = #times
  local inputs, labels, tiles, layout, picks = {}, {}, {}, {}, {}
  for i = 0, n - 1 do
    local t = ("%.3f"):format(times[i + 1])
    inputs[#inputs + 1] = ("-ss %s -i %s"):format(t, q(tmp .. "/out.mp4"))
    if text then
      labels[#labels + 1] = ("[%d:v]scale=480:-2,drawtext=text='t=%ss':x=8:y=8:fontsize=18:fontcolor=white:box=1:"
        .. "boxcolor=black@0.6[f%d];"):format(i, t, i)
    else
      labels[#labels + 1] = ("[%d:v]scale=480:-2[f%d];"):format(i, i)
    end
    tiles[#tiles + 1] = ("[f%d]"):format(i)
    local c, r = i % 3, math.floor(i / 3)
    local x = c == 0 and "0" or (c == 1 and "w0" or "w0+w0")
    local y = r == 0 and "0" or ("h0" .. ("+h0"):rep(r - 1))
    layout[#layout + 1] = x .. "_" .. y
    picks[#picks + 1] = t
  end
  local filter = table.concat(labels) .. table.concat(tiles) .. ("xstack=inputs=%d:layout=%s[s]"):format(n,
    table.concat(layout, "|"))
  rc = os.execute(("ffmpeg -v error -y %s -filter_complex %s -map '[s]' -frames:v 1 %s"):format(
    table.concat(inputs, " "), q(filter), q(out)))
  os.execute("rm -rf " .. q(tmp))
  if rc ~= 0 and rc ~= true then return 1 end
  local made = io.open(out, "rb")
  if not made or made:seek("end") == 0 then
    if made then made:close() end
    io.stderr:write(("moonsplice sheet: ffmpeg wrote no image at %s\n"):format(out))
    return 1
  end
  made:close()
  print(('{"picks":[%s],"seconds":%.3f,"sheet":"%s","labelled":%s}'):format(table.concat(picks, ","), now() - t0, out,
    text and "true" or "false"))
  return 0
end

return M
