-- What the resolve phase shares: a shell call, a hash, the cache's root and whether a file exists, and
-- localize, which turns a source into a file on disk. Part of resolve (core/runtime/resolve/init.lua).

local function sh(cmd)
  local p = assert(_MOONSPLICE_POPEN(cmd .. " 2>&1", "r"))
  local out = p:read("*a")
  local ok = p:close()
  return ok, out
end

local function sha1(s)
  return love.data.encode("string", "hex", love.data.hash("sha1", s))
end

local function cache_root()
  local custom = os.getenv("MOONSPLICE_CACHE")
  if custom then return custom end
  return (os.getenv("HOME") or "/tmp") .. "/.cache/moonsplice"
end

local function exists(path)
  local f = _MOONSPLICE_IOOPEN(path, "r")
  if f then f:close() return true end
  return false
end

local MEDIA_EXT = { mp4=1, mov=1, webm=1, mkv=1, m4v=1, avi=1, ogv=1, mp3=1, wav=1, m4a=1,
                    png=1, jpg=1, jpeg=1, webp=1, gif=1 }

local function localize(src)
  -- A page URL (YouTube, TikTok, Vimeo, ...) is not a file: bin/moonsplice-fetch downloads it with
  -- yt-dlp into the shared media store (vision/moonsplice_vision/fetch.py) and keeps it.
  local ext = src:match("^https?://[^?#]*%.(%w+)[?#]?")
  if src:match("^https?://") and not (ext and MEDIA_EXT[ext:lower()]) then
    local root = os.getenv("MOONSPLICE_ROOT")
      or (love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", ""))
      or "."
    local ok, out = sh(("'%s/bin/moonsplice-fetch' '%s'"):format(root, src:gsub("'", "'\\''")))
    local path = out:match('"path": "([^"]+)"')
    if not ok or not path then error("moonsplice resolve: fetch failed: " .. src .. "\n" .. out) end
    return path
  end
  if src:match("^https?://") then
    local dst = cache_root() .. "/dl/" .. sha1(src) .. ".bin"
    if not exists(dst) then
      assert(sh(("mkdir -p '%s/dl'"):format(cache_root())))
      local ok, out = sh(("curl -fsSL -o '%s' '%s'"):format(dst, src))
      if not ok then error("moonsplice resolve: download failed: " .. src .. "\n" .. out) end
    end
    return dst
  end
  if not src:match("^/") then
    return (os.getenv("MOONSPLICE_CWD") or ".") .. "/" .. src
  end
  return src
end


return {
  sh = sh,
  sha1 = sha1,
  cache_root = cache_root,
  exists = exists,
  MEDIA_EXT = MEDIA_EXT,
  localize = localize,
}
