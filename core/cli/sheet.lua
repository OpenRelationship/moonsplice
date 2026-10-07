-- moonsplice sheet COMP OUT.png [--json] [--n 6]: render the comp, take n frames at the middles of n equal spans,
-- and tile them three across with ffmpeg's xstack (labelled with their times when ffmpeg has drawtext). Prints
-- {"picks":[...],"seconds":s,"sheet":path,"labelled":bool}, the line tablua's ports.moonsplice reads.
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

function M.run(cli, args)
  local q = cli.q
  local comp, out = args[1], args[2]
  local n = 6
  for i = 3, #args do if args[i] == "--n" then n = tonumber(args[i + 1]) or n end end
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
  local inputs, labels, tiles, layout, picks = {}, {}, {}, {}, {}
  for i = 0, n - 1 do
    local t = ("%.3f"):format(dur * (i + 0.5) / n)
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
    local y = r == 0 and "0" or (r == 1 and "h0" or "h0+h0")
    layout[#layout + 1] = x .. "_" .. y
    picks[#picks + 1] = t
  end
  local filter = table.concat(labels) .. table.concat(tiles) .. ("xstack=inputs=%d:layout=%s[s]"):format(n,
    table.concat(layout, "|"))
  rc = os.execute(("ffmpeg -v error -y %s -filter_complex %s -map '[s]' -frames:v 1 %s"):format(
    table.concat(inputs, " "), q(filter), q(out)))
  os.execute("rm -rf " .. q(tmp))
  if rc ~= 0 and rc ~= true then return 1 end
  print(('{"picks":[%s],"seconds":%.3f,"sheet":"%s","labelled":%s}'):format(table.concat(picks, ","), now() - t0, out,
    text and "true" or "false"))
  return 0
end

return M
