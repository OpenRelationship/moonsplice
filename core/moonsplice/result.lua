-- moonsplice.result/v1 — machine-readable envelope for lint, check, verify, and errors.
-- Host code writes this; comps never require it.

local R = {}

R.SCHEMA = "moonsplice.result/v1"

function R.json_escape(s)
  s = tostring(s or "")
  return s:gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"):gsub("\r", "\\r")
end

-- A finding is also a row (.robot/docs/rows.robot §5): tier, id (the node it is about; "" for the comp) and
-- name (the prop, "" when it is about the whole node), beside the older `node`.
local function encode_finding(f, tier)
  local parts = {
    ('"tier":"%s"'):format(R.json_escape(f.tier or tier or "")),
    ('"id":"%s"'):format(R.json_escape(f.node or "")),
    ('"name":"%s"'):format(R.json_escape(f.prop or "")),
  }
  for _, k in ipairs({ "code", "severity", "node", "detail", "suggestion" }) do
    if f[k] then parts[#parts + 1] = ('"%s":"%s"'):format(k, R.json_escape(f[k])) end
  end
  for _, k in ipairs({ "t0", "t1", "measured", "threshold" }) do
    if f[k] then parts[#parts + 1] = ('"%s":%.4f'):format(k, f[k]) end
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function R.count_severity(findings)
  local errs, warns = 0, 0
  for _, f in ipairs(findings or {}) do
    if f.severity == "error" then errs = errs + 1
    elseif f.severity == "warn" then warns = warns + 1 end
  end
  return errs, warns
end

function R.encode_step(step)
  local rows = {}
  for _, f in ipairs(step.findings or {}) do rows[#rows + 1] = encode_finding(f, step.tier) end
  local errs, warns = R.count_severity(step.findings)
  local parts = {
    ('"tier":"%s"'):format(R.json_escape(step.tier or "")),
    ('"status":"%s"'):format(R.json_escape(step.status or "ok")),
    ('"duration_ms":%d'):format(math.floor(tonumber(step.duration_ms) or 0)),
    ('"errors":%d'):format(errs),
    ('"warnings":%d'):format(warns),
    '"findings":[' .. table.concat(rows, ",") .. "]",
  }
  if step.error then parts[#parts + 1] = ('"error":"%s"'):format(R.json_escape(step.error)) end
  return "{" .. table.concat(parts, ",") .. "}"
end

function R.encode(opts)
  opts = opts or {}
  local findings = opts.findings or {}
  local tier = opts.tier or (opts.meta and opts.meta.tier) or "unknown"
  local rows = {}
  for _, f in ipairs(findings) do rows[#rows + 1] = encode_finding(f, tier) end
  local errs, warns = R.count_severity(findings)
  local parts = {
    ('"schema":"%s"'):format(R.SCHEMA),
    ('"command":"%s"'):format(R.json_escape(opts.command or tier)),
    ('"status":"%s"'):format(R.json_escape(opts.status or (errs > 0 and "failed" or "ok"))),
    ('"exit_code":%d'):format(tonumber(opts.exit_code) or (errs > 0 and 1 or 0)),
    ('"comp":"%s"'):format(R.json_escape(opts.comp or "")),
    ('"cwd":"%s"'):format(R.json_escape(opts.cwd or "")),
    ('"_meta":{"tier":"%s","errors":%d,"warnings":%d,"findings":%d}'):format(
      R.json_escape(tier), errs, warns, #findings),
  }
  if opts.meta then
    local meta_parts = {}
    for k, v in pairs(opts.meta) do
      if type(v) == "number" then
        meta_parts[#meta_parts + 1] = ('"%s":%.4g'):format(k, v)
      elseif type(v) == "string" then
        meta_parts[#meta_parts + 1] = ('"%s":"%s"'):format(k, R.json_escape(v))
      end
    end
    if #meta_parts > 0 then
      parts[#parts + 1] = '"meta":{' .. table.concat(meta_parts, ",") .. "}"
    end
  end
  if opts.steps then
    local step_rows = {}
    for _, s in ipairs(opts.steps) do step_rows[#step_rows + 1] = R.encode_step(s) end
    parts[#parts + 1] = '"steps":[' .. table.concat(step_rows, ",") .. "]"
  end
  parts[#parts + 1] = '"findings":[' .. table.concat(rows, ",") .. "]"
  if opts.error then
    parts[#parts + 1] = ('"error":"%s"'):format(R.json_escape(opts.error))
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function R.from_findings(findings, opts, tier)
  opts = opts or {}
  local errs, warns = R.count_severity(findings)
  local exit_code = errs > 0 and 1 or (opts.strict and warns > 0 and 1 or 0)
  return R.encode({
    command = tier,
    tier = tier,
    status = exit_code == 0 and "ok" or "failed",
    exit_code = exit_code,
    comp = opts.comp,
    cwd = opts.cwd,
    meta = { tier = tier, duration_ms = opts.duration_ms, engine = "moonsplice-engine" },
    findings = findings,
  })
end

function R.error_envelope(opts, message)
  opts = opts or {}
  return R.encode({
    command = opts.mode or "compile",
    tier = "compile",
    status = "failed",
    exit_code = 1,
    comp = opts.comp,
    cwd = opts.cwd,
    meta = { tier = "compile", engine = "moonsplice-engine" },
    findings = {
      {
        code = "compile_error",
        severity = "error",
        detail = tostring(message),
      },
    },
    error = tostring(message),
  })
end

return R
