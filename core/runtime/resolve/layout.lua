-- Sources made local, precomps' rows and the comp's layout. Part of resolve.
local R = require("resolve")
local F = require("resolve.files")
local localize = F.localize

-- Layout pass: runs as compile's post_scene hook (before scripts record), so
-- tweens resolve from solved positions.
R.localize = localize

-- A precomp's comp (.robot/docs/rows.robot, "Composition"): its rows, read at compile like any other source.
-- A relative `src` is relative to the comp that names it (`from`), so a comp and its parts move
-- together wherever the command runs; an absolute path is itself.
function R.precomp_rows(src, from)
  local path = src
  if not src:match("^/") then
    local dir = (from or ""):match("^(.*)/[^/]*$") or (os.getenv("MOONSPLICE_CWD") or ".")
    path = (dir .. "/" .. src):gsub("/%./", "/")
  end
  local chunk, err = loadfile(path)
  if not chunk then error(("moonsplice: precomp %s: %s"):format(src, tostring(err)), 0) end
  local ok, comp = pcall(chunk)
  if not ok then error(("moonsplice: precomp %s: %s"):format(src, tostring(comp)), 0) end
  if type(comp) ~= "table" or not comp.rows then
    error(("moonsplice: precomp %s is not a comp in rows form (e.comp { nodes = {...} })"):format(path), 0)
  end
  return comp.rows, path
end

function R.layout(nodes)
  local layout = require("layout")
  for _, n in ipairs(nodes) do
    if n.kind == "kinetic" then
      -- measure per-char widths with the real font, center the run on i.x
      local i = n.initial
      local scene = require("scene")
      local font = (not scene.enabled) and require("painter").font(i.size, i.font) or nil
      local fid = scene.enabled and scene.font_id(i.font) or nil
      local widths, total = {}, 0
      for ch in i.text:gmatch(".") do
        local w = font and font:getWidth(ch) or scene.measure(fid, i.size, ch)
        widths[#widths + 1] = { ch = ch, w = w }
        total = total + w + i.spacing
      end
      total = total - i.spacing
      local cursor = i.x - total / 2
      local ci = 0
      for _, e in ipairs(widths) do
        if e.ch ~= " " then
          ci = ci + 1
          local node = n.chars[ci]
          node.initial.x = cursor + e.w / 2
          node.initial.y = i.y
        end
        cursor = cursor + e.w + i.spacing
      end
    elseif n.kind == "flex" then
      if not layout.available then error("moonsplice resolve: layout dylib missing (build layout/)") end
      local i = n.initial
      local items = {}
      for k, child in ipairs(i.items) do
        items[k] = { w = child.initial.w or (child.initial.r and child.initial.r * 2),
                     h = child.initial.h or (child.initial.r and child.initial.r * 2),
                     grow = child.initial.grow, margin = child.initial.margin }
      end
      local solved = layout.solve(i, items)
      for k, child in ipairs(i.items) do
        local sl = solved[k]
        local ci = child.initial
        ci.w = ci.w and sl.w or ci.w
        ci.h = ci.h and sl.h or ci.h
        local centered = ci.anchor == "center" or child.kind == "circle"
        local ax = centered and sl.w / 2 or 0
        local ay = centered and sl.h / 2 or 0
        ci.x = i.x + sl.x + ax
        ci.y = i.y + sl.y + ay
      end
    end
  end
end
