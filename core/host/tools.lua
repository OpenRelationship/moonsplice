-- What the agent can do to a composition, through moonsplice: gate it (lint + check), render it
-- and make a contact sheet a vision model reads, and hash it twice (is it still a pure f(t)?).
local H = require("host")
local json = require("ports.json")

local T = {}

local function bin() return H.root .. "/moonsplice" end

local function decode(out)
  local body = out:match("(%{\"schema\".*%})")
  if not body then return nil end
  local ok, doc = pcall(json.decode, body)
  return ok and doc or nil
end

local function short(f)
  local s = ("%s %s"):format(f.severity or "?", f.code or "?")
  if f.node then s = s .. " node=" .. tostring(f.node) end
  if f.t0 then s = s .. (" t=%.2f"):format(f.t0) end
  if f.detail then s = s .. ": " .. tostring(f.detail) end
  if f.suggestion then s = s .. " (" .. tostring(f.suggestion) .. ")" end
  return s
end

-- lint then check. { pass, errors, warnings, findings = { "error code: detail", ... }, crash? }
function T.gate(path)
  local res = { pass = true, errors = 0, warnings = 0, findings = {} }
  for _, cmd in ipairs({ "lint", "check" }) do
    local out = H.sh(("%s %s %s --json"):format(H.q(bin()), cmd, H.q(path)))
    local doc = decode(out)
    if not doc then
      res.pass, res.errors = false, res.errors + 1
      res.crash = (out:match("moonsplice error: ([^\n]+)") or out:sub(1, 600))
      res.findings[#res.findings + 1] = "error " .. cmd .. " could not load the comp: " .. res.crash
      return res
    end
    for _, f in ipairs(doc.findings or {}) do
      if f.severity == "error" then res.errors = res.errors + 1 elseif f.severity == "warn" then res.warnings = res.warnings + 1 end
      if f.severity ~= "info" and #res.findings < 14 then res.findings[#res.findings + 1] = cmd .. ": " .. short(f) end
    end
    if doc.status ~= "ok" and (doc._meta or {}).errors ~= 0 then res.pass = false end
  end
  if res.errors > 0 then res.pass = false end
  return res
end

-- render to dir/out.mp4 and a contact sheet of n frames (3 across) at dir/sheet.png
function T.render(path, dir, n)
  n = n or 6
  H.mkdir(dir)
  local mp4, sheet = dir .. "/out.mp4", dir .. "/sheet.png"
  local out, code = H.sh(("%s render %s -o %s"):format(H.q(bin()), H.q(path), H.q(mp4)))
  if code ~= 0 then
    return nil, (out:match("moonsplice error: ([^\n]+)") or out:sub(-600))
  end
  local dur = tonumber((H.sh(("ffprobe -v error -show_entries format=duration -of csv=p=0 %s"):format(H.q(mp4))))) or 1
  local picks = {}
  for i = 0, n - 1 do picks[#picks + 1] = ("%.3f"):format(dur * (i + 0.5) / n) end
  -- one frame per pick, labelled with its time, tiled 3 across
  local inputs, labels = {}, {}
  for i, t in ipairs(picks) do
    inputs[#inputs + 1] = ("-ss %s -i %s"):format(t, H.q(mp4))
    labels[#labels + 1] = ("[%d:v]scale=480:-2,drawtext=text='t=%ss':x=8:y=8:fontsize=18:fontcolor=white:box=1:boxcolor=black@0.6[f%d]")
      :format(i - 1, t, i)
  end
  local tiles = {}
  for i = 1, #picks do tiles[i] = ("[f%d]"):format(i) end
  local rows = math.ceil(#picks / 3)
  local fc = table.concat(labels, ";") .. ";" .. table.concat(tiles) .. ("xstack=inputs=%d:layout="):format(#picks)
  local lay = {}
  for i = 0, #picks - 1 do
    local c, r = i % 3, math.floor(i / 3)
    local x = c == 0 and "0" or (c == 1 and "w0" or "w0+w0")
    local y = r == 0 and "0" or (r == 1 and "h0" or "h0+h0")
    lay[#lay + 1] = x .. "_" .. y
  end
  fc = fc .. table.concat(lay, "|") .. "[s]"
  local o2, c2 = H.sh(("ffmpeg -v error -y %s -filter_complex %s -map '[s]' -frames:v 1 %s")
    :format(table.concat(inputs, " "), H.q(fc), H.q(sheet)))
  if c2 ~= 0 then return nil, "contact sheet failed: " .. o2:sub(1, 300) end
  return { mp4 = mp4, sheet = sheet, duration = dur, picks = picks, rows = rows }
end

-- per-frame hashes, twice: the same both times means the comp is still a pure function of t
function T.stable(path)
  local a = H.sh(("%s hash %s"):format(H.q(bin()), H.q(path)))
  local b = H.sh(("%s hash %s"):format(H.q(bin()), H.q(path)))
  local fa = {}
  for h in a:gmatch("FRAME %d+ (%x+)") do fa[#fa + 1] = h end
  local same, n = #fa > 0, 0
  for h in b:gmatch("FRAME %d+ (%x+)") do n = n + 1; if fa[n] ~= h then same = false end end
  return same and n == #fa, #fa
end

function T.b64(path)
  local p = io.popen("base64 -i " .. H.q(path))
  local s = p:read("*a"):gsub("%s", "")
  p:close()
  return s
end

return T
