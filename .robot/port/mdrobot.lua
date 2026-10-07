-- Markdown pages as Robot documentation. A page's title and its opening prose become the suite's Documentation;
-- each `##` section becomes a test case tagged `doc` whose [Documentation] is the section's text, word for word,
-- and whose body is `Skip    prose`: a section nobody has made checkable yet shows as skipped, never as passing.
-- Replacing the Skip with keywords that check what the prose says is how a page becomes a test.
--
--   mdrobot.convert({ { path, text }, ... }, source) -> { { name, text }, ... }   name is "" for the first file,
--     "-2", "-3" ... for the rest: a page longer than mdrobot.limit lines is cut at a section boundary
local M = {}

M.limit = 400

-- one line of prose as a Robot cell: escapes, and runs of spaces kept as escaped spaces (a code block's indent)
local function cell(line)
  line = line:gsub("\\", "\\\\"):gsub("([%$@&%%]){", "\\%1{")
  line = line:gsub("^( +)", function(sp) return ("\\ "):rep(#sp) end)
  line = line:gsub("(%S)(  +)", function(c, sp) return c .. " " .. ("\\ "):rep(#sp - 1) end)
  line = line:gsub("\t", "\\t")
  if line:match("^#") then line = "\\" .. line end
  return line
end

local function doc_lines(lines, first_prefix)
  local out = {}
  -- trim blank lines at both ends
  local a, b = 1, #lines
  while a <= b and lines[a]:match("^%s*$") do a = a + 1 end
  while b >= a and lines[b]:match("^%s*$") do b = b - 1 end
  for i = a, b do
    local text = cell(lines[i])
    if i == a then out[#out + 1] = first_prefix .. text
    else out[#out + 1] = (text == "" and "..." or ("...    " .. text)) end
  end
  return out
end

-- a page cut into { title, intro = {lines}, sections = { { name, lines } } }
local function sections(text)
  local page = { intro = {}, sections = {} }
  local cur = nil
  local fence = false
  for line in (text .. "\n"):gmatch("(.-)\r?\n") do
    if line:match("^```") or line:match("^~~~") then fence = not fence end
    local h1 = not fence and line:match("^#%s+(.+)$")
    local h2 = not fence and line:match("^##%s+(.+)$")
    if h1 and not page.title and not cur then page.title = h1
    elseif h2 then cur = { name = h2, lines = {} }; page.sections[#page.sections + 1] = cur
    else
      local h = not fence and line:match("^###+%s+(.+)$")
      if h then line = "*" .. h .. "*" end
      if line:match("^#%s") and not fence then line = "*" .. line:sub(3) .. "*" end
      table.insert(cur and cur.lines or page.intro, line)
    end
  end
  return page
end

-- a test name Robot accepts, unique within the suite
local function name_of(raw, seen)
  local n = raw:gsub("`", ""):gsub("%*%*", ""):gsub("%s+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  n = n:gsub("([%$@&%%]){", "\\%1{")
  if n == "" then n = "Section" end
  local base, k = n, 1
  while seen[n:lower()] do k = k + 1; n = base .. " " .. k end
  seen[n:lower()] = true
  return n
end

local function test_block(name, lines, source)
  local out = { name }
  for _, l in ipairs(doc_lines(lines, "    [Documentation]    ")) do
    out[#out + 1] = l:sub(1, 3) == "..." and ("    " .. l) or l
  end
  if #out == 1 then out[#out + 1] = "    [Documentation]    " .. name end
  out[#out + 1] = "    [Tags]    doc    source:" .. source
  out[#out + 1] = "    Skip    prose"
  out[#out + 1] = ""
  return out
end

function M.convert(pages, source)
  local first = sections(pages[1].text)
  local head = { "*** Settings ***" }
  local intro = {}
  intro[#intro + 1] = first.title or pages[1].path
  local body = first.intro
  while #body > 0 and body[1]:match("^%s*$") do table.remove(body, 1) end
  if #body > 0 then intro[#intro + 1] = ""; for _, l in ipairs(body) do intro[#intro + 1] = l end end
  for _, l in ipairs(doc_lines(intro, "Documentation    ")) do head[#head + 1] = l end
  head[#head + 1] = "Metadata    Source    " .. source .. ":" .. pages[1].path
  head[#head + 1] = ""
  head[#head + 1] = "*** Test Cases ***"

  local blocks, seen = {}, {}
  for i, p in ipairs(pages) do
    local page = i == 1 and first or sections(p.text)
    local where = source .. ":" .. p.path
    if i > 1 then
      blocks[#blocks + 1] = test_block(name_of(page.title or p.path, seen), page.intro, where)
    end
    for _, s in ipairs(page.sections) do
      blocks[#blocks + 1] = test_block(name_of(s.name, seen), s.lines, where)
    end
  end

  -- cut into files of at most M.limit lines, at block boundaries; an oversized block is cut where it overflows
  local files, cur = {}, nil
  local function open()
    cur = {}
    for _, l in ipairs(#files == 0 and head or {
      "*** Settings ***", "Documentation    " .. (first.title or pages[1].path) .. " (continued)", "",
      "*** Test Cases ***" }) do cur[#cur + 1] = l end
    files[#files + 1] = cur
  end
  open()
  for _, b in ipairs(blocks) do
    if #cur + #b > M.limit and #cur > 6 then open() end
    for k, l in ipairs(b) do
      if #cur >= M.limit then
        open()
        cur[#cur + 1] = b[1] .. " (continued)"
        if k > 1 and l:sub(1, 7) == "    ..." then l = "    [Documentation]" .. l:sub(8) end
      end
      cur[#cur + 1] = l
    end
  end
  local out = {}
  for i, f in ipairs(files) do
    out[#out + 1] = { name = i == 1 and "" or ("-" .. i), text = table.concat(f, "\n") .. "\n" }
  end
  return out
end

return M
