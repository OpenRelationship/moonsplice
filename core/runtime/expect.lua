-- Part of rowsmode (core/runtime/rowsmode.lua): see its head for the module's contract.
local M = require("rowsmode")
local R, try, findings = M._.R, M._.try, M._.findings

-- `moonsplice expect COMP FILE.json`: the harness writes the ask's expectations (ROWS.md,
-- "Expectations") once, before the first move. Each row is added unless its id exists already;
-- existing rows (a seed's invariants) are never edited. A malformed row is rejected with why.
local EXPECT_FIELDS = { id = true, says = true, node = true, prop = true, op = true, value = true,
  at = true, t0 = true, t1 = true, holds = true }
local EXPECT_OPS = { ["=="] = true, ["~="] = true, [">"] = true, [">="] = true, ["<"] = true, ["<="] = true, has = true }

local function expect_why(x)
  if type(x) ~= "table" then return "an expect row is an object" end
  for k in pairs(x) do
    if not EXPECT_FIELDS[k] then return ("%s is not an expect field (id, says, node, prop, op, value, at, t0, t1, holds)"):format(tostring(k)) end
  end
  if type(x.id) ~= "string" or x.id == "" then return "id needs a string" end
  if type(x.says) ~= "string" or x.says == "" then return "says needs a string: what the ask requires, in words" end
  if type(x.node) ~= "string" or x.node == "" then return "node needs a string: the node id the row is about" end
  if x.prop ~= nil and type(x.prop) ~= "string" then return "prop needs a string" end
  if (x.op ~= nil or x.value ~= nil or x.at ~= nil or x.t0 ~= nil or x.t1 ~= nil or x.holds ~= nil) and not x.prop then
    return "op, value, at, t0, t1 and holds need a prop"
  end
  if x.prop then
    if x.value == nil then return "a row with a prop needs a value" end
    if x.op ~= nil and not EXPECT_OPS[x.op] then return ("op %s is not one of == ~= > >= < <= has"):format(tostring(x.op)) end
    if x.op == "has" and type(x.value) ~= "string" then return "op has needs a string value" end
    if x.op and x.op:match("[<>]") and type(x.value) ~= "number" then return ("op %s needs a number value"):format(x.op) end
    if x.at ~= nil and (x.t0 ~= nil or x.t1 ~= nil) then return "give at, or t0..t1, not both" end
    if x.holds ~= nil and x.holds ~= "ever" and x.holds ~= "always" then return 'holds is "ever" or "always"' end
    if x.holds ~= nil and x.at ~= nil then return "holds needs a window (t0..t1), not at" end
    -- a value checked with no time at all is checked at every frame of the piece; say so, or say when
    if x.at == nil and x.t0 == nil and x.t1 == nil and x.holds == nil and x.op ~= "has" then
      return 'say when: at (one instant), t0..t1 (a window), or holds = "always" for every frame of the piece'
    end
    for _, k in ipairs({ "at", "t0", "t1" }) do
      local v = x[k]
      if v ~= nil and type(v) ~= "number" and type(v) ~= "string" then return k .. " needs seconds or a fact reference" end
    end
  end
  return nil
end

function M.expect(comp, opts)
  local f = _MOONSPLICE_IOOPEN(opts.expect_file, "r")
  if not f then io.stderr:write("moonsplice expect: cannot read " .. tostring(opts.expect_file) .. "\n") return 1 end
  local ok, list = pcall(require("moonsplice.json").decode, f:read("*a"))
  f:close()
  if not ok or type(list) ~= "table" then io.stderr:write("moonsplice expect: the rows are not JSON\n") return 1 end
  if list.id then list = { list } end
  local added, rejected = {}, {}
  if not comp.rows then
    for _, x in ipairs(list) do
      rejected[#rejected + 1] = { row = x, why = "the comp is not in rows form; `moonsplice rows COMP -o NEW.lua` converts one" }
    end
    io.write(R.json({ added = added, rejected = rejected, findings = findings(opts.comp) }), "\n")
    return 0
  end
  local rows = R.copy(comp.rows)
  comp_path = opts.comp
  rows.expect = rows.expect or {}
  local before = M.digest(rows)
  local have = {}
  for _, x in ipairs(rows.expect) do have[x.id] = true end
  local withdrawn = {}
  for _, x in ipairs(list) do
    -- { withdraw = id, why = reason }: an expectation the run wrote and found wrong comes out, with its
    -- reason on the record. The harness decides whose rows may be withdrawn (never the seed's); the engine
    -- only refuses an unknown id or a missing reason.
    if type(x) == "table" and x.withdraw ~= nil then
      local bad
      for k in pairs(x) do if k ~= "withdraw" and k ~= "why" then bad = k end end
      local reason = bad and ("%s is not a withdraw field (withdraw, why)"):format(tostring(bad))
        or (type(x.why) ~= "string" or x.why == "") and "a withdrawal needs why: the reason, in words"
        or not have[x.withdraw] and ("no expect %s to withdraw"):format(tostring(x.withdraw))
      if reason then
        rejected[#rejected + 1] = { row = x, why = reason }
      else
        for i = #rows.expect, 1, -1 do
          if rows.expect[i].id == x.withdraw then
            withdrawn[#withdrawn + 1] = { id = x.withdraw, says = rows.expect[i].says, why = x.why }
            table.remove(rows.expect, i)
          end
        end
        have[x.withdraw] = nil
      end
      goto next_row
    end
    do
    local why = expect_why(x)
    if not why and have[x.id] then why = ("expect %s exists already; expectations are never edited"):format(x.id) end
    if not why then
      rows.expect[#rows.expect + 1] = R.copy(x)
      -- it must compile: a fact reference no asset makes is refused here, not at render
      local tried, err = pcall(try, rows)
      if tried then
        -- and its times must fall inside the comp: a predicate it can never reach is no predicate
        for _, e in ipairs(err.expect or {}) do
          if e.id == x.id then
            for _, k in ipairs({ "at", "t0", "t1" }) do
              if type(e[k]) == "number" and (e[k] < 0 or e[k] > err.duration) then
                tried, err = false, ("%s %s is %.2f s, outside the comp (0..%g s)"):format(k, tostring(x[k]), e[k], err.duration)
              end
            end
          end
        end
      end
      if tried then
        have[x.id] = true
        added[#added + 1] = x
      else
        -- by id: emitting the comp sorts the table, so the row just added need not be last
        for i = #rows.expect, 1, -1 do if rows.expect[i].id == x.id then table.remove(rows.expect, i) end end
        why = tostring(err)
      end
    end
    if why then rejected[#rejected + 1] = { row = x, why = why } end
    end
    ::next_row::
  end
  R.sort(rows)
  local after = M.digest(rows)
  if after ~= before then
    local out = assert(_MOONSPLICE_IOOPEN(opts.comp, "w"))
    out:write(R.lua(rows)); out:close()
  end
  local fs = findings(opts.comp)
  io.write(R.json({ added = added, withdrawn = withdrawn, rejected = rejected, digest_before = before, digest_after = after,
    findings = fs, state = M.state(rows, fs) }), "\n")
  io.flush()
  return 0
end

-- `moonsplice gate COMP --json`: the state line alone, for a harness's hand-in: { state, findings };
-- passed when no error is open and every expectation holds
function M.gate(comp, opts)
  if not comp.rows then io.stderr:write("moonsplice gate: the comp is not in rows form\n") return 1 end
  local rows = R.copy(comp.rows)
  local fs = findings(opts.comp)
  local st = M.state(rows, fs)
  st.passed = st.errors == 0 and #st.failing == 0
  io.write(R.json({ state = st, findings = fs }), "\n")
  io.flush()
  return 0
end
