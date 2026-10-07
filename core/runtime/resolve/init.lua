-- Resolve phase (host code, runs AFTER comp load, BEFORE render).
-- Network/disk allowed here — render itself stays I/O-free per canon.
-- v0 video path: extract frames at comp fps, cover-cropped to node w×h, into a
-- content-addressed cache. Long-term this is replaced by the moonsplice-decode sidecar.
local R = {}

package.loaded["resolve"] = R
local F = require("resolve.files")
local sh, sha1, cache_root, exists = F.sh, F.sha1, F.cache_root, F.exists
local localize = F.localize
local probe, voice = require("resolve.probe"), require("resolve.voice")
local probe_recall, probe_many = probe.probe_recall, probe.probe_many
local ffprobe_duration, bake_energy = probe.ffprobe_duration, probe.bake_energy
local tts_generate, music_generate, sfx_generate = voice.tts_generate, voice.music_generate, voice.sfx_generate
local normword, align_generate = voice.normword, voice.align_generate
local went_offline = require("resolve.offline").went_offline
require("resolve.layout")

function R.media(nodes, fps)
  local decode = require("decode")

  -- Learn how long every sound is before anything else needs to know. Only `audio` nodes, whose
  -- file is simply the file they name: a generated one (tts, sfx, music) is found by a content
  -- hash that is not settled until the loop below has run, and asking early would be asking
  -- about the wrong file.
  do
    local ask, seen = {}, {}
    for _, n in ipairs(nodes) do
      if n.kind == "audio" and type(n.initial.src) == "string" then
        local ok, file = pcall(localize, n.initial.src)
        if ok and file and not seen[file] and not probe_recall(file) then
          seen[file] = true
          ask[#ask + 1] = file
        end
      end
    end
    probe_many(ask)
  end

  -- Everything one node needs, made ready. Separated from the walk below only so that one of
  -- these can fail on its own; see `went_offline`.
  local function resolve_one(n)
    if n.kind == "video" and decode.available then
      -- fast path: in-process FFI decoder, no extraction, frame-exact by PTS.
      -- yuv420 sources come back as raw planes (GPU converts); others as RGBA.
      local i = n.initial
      local file = localize(i.src)
      if i.derive then file, n.derived = require("derive").video(file, i.derive) end
      n.dec = decode.open(file, i.w, i.h)
      if i.cursor_src then n.cursor_file = localize(i.cursor_src) end
    elseif n.kind == "video" then
      local i = n.initial
      local file = localize(i.src)
      if i.derive then file, n.derived = require("derive").video(file, i.derive) end
      local key = sha1(table.concat({ file, i.media_start, i.duration, fps, i.w, i.h }, "|"))
      local dir = cache_root() .. "/frames/" .. key
      if not exists(dir .. "/DONE") then
        assert(sh(("mkdir -p '%s'"):format(dir)))
        local cmd = string.format(
          "ffmpeg -hide_banner -loglevel error -y -i '%s' -ss %f -t %f" ..
          " -vf 'fps=%d,scale=%d:%d:force_original_aspect_ratio=increase,crop=%d:%d'" ..
          " -q:v 2 '%s/%%05d.jpg'",
          file, i.media_start, i.duration, fps, i.w, i.h, i.w, i.h, dir)
        local ok, out = sh(cmd)
        if not ok then error("moonsplice resolve: frame extraction failed:\n" .. out) end
        assert(sh(("touch '%s/DONE'"):format(dir)))
      end
      local _, count = sh(("ls '%s' | grep -c jpg"):format(dir))
      n.frames_dir = dir
      n.frame_count = tonumber(count:match("%d+")) or 0
      if n.frame_count == 0 then error("moonsplice resolve: no frames extracted for " .. i.src) end
    elseif n.kind == "image" and not n.initial.src and n.initial.prompt then
      local i = n.initial
      local aspect = i.aspect or (i.w and i.h and (i.w >= i.h * 1.5 and "16:9" or i.h >= i.w * 1.5 and "9:16" or "1:1")) or "16:9"
      local dst = cache_root() .. "/generated/" .. sha1(table.concat({ "minimax", i.model or "image-01", i.prompt, aspect,
        tostring(i.seed or "") }, "|")) .. ".png"
      if not exists(dst) then
        local root = os.getenv("MOONSPLICE_ROOT")
          or (love.filesystem and love.filesystem.getSource and love.filesystem.getSource():gsub("/core/runtime/?$", "")) or "."
        local cmd = ("'%s/bin/moonsplice-minimax' image --prompt %q --out %q --aspect %s"):format(root, i.prompt, dst, aspect)
        if i.seed then cmd = cmd .. " --seed " .. tonumber(i.seed) end
        if i.model then cmd = cmd .. (" --model %q"):format(i.model) end
        local ok, out = sh(cmd)
        if not ok or not exists(dst) then error("moonsplice resolve: image generation failed:\n" .. out, 0) end
      end
      n.file = dst
    elseif n.kind == "image" then
      n.file = localize(n.initial.src)
      if n.initial.cursor_src then n.cursor_file = localize(n.initial.cursor_src) end
      if not exists(n.file) then error("moonsplice resolve: image not found: " .. n.initial.src) end
    elseif n.kind == "lottie" then
      n.file = localize(n.initial.src)
      if not exists(n.file) then error("moonsplice resolve: lottie not found: " .. n.initial.src) end
    elseif n.kind == "mesh" and n.initial.src then
      n.file = localize(n.initial.src)
      if not exists(n.file) then error("moonsplice resolve: mesh not found: " .. n.initial.src) end
      local scene3d = require("scene3d")
      -- a built solid (.robot/docs/solids.robot) is drawn by Bevy from its .msh; scene3d reads glTF only
      if scene3d.available and not n.file:match("%.msh$") then
        n.mesh_id = scene3d.load(n.file)
        if not n.mesh_id or n.mesh_id == 0 then
          error("moonsplice resolve: glTF load failed: " .. n.file)
        end
      end
    elseif n.kind == "audio" or n.kind == "tts" or n.kind == "sfx" or n.kind == "music" then
      local i = n.initial
      if n.kind == "audio" then
        n.afile = localize(i.src)
        if i.derive then n.afile, n.derived = require("derive").audio(n.afile, i.derive) end
        if not exists(n.afile) then error("moonsplice resolve: audio not found: " .. i.src) end
      elseif n.kind == "tts" then
        -- auto request-stitching: a line chained to an earlier TTS clip inherits
        -- it as previous_text, so consecutive lines read as one narration
        local ref = (i.after and (i.after[1] or i.after.node)) or (i.at_word and i.at_word[1])
        if ref and ref.kind == "tts" and i.previous_text == nil and ref.initial.text then
          i.previous_text = ref.initial.text
        end
        n.afile = tts_generate(i, (i.align or i.align_at or i.at_word) and true or false)
      elseif n.kind == "music" then
        n.afile = music_generate(i)
      else
        n.afile = sfx_generate(i)
      end
      n.media_duration = ffprobe_duration(n.afile)
      -- default clip window = whole file; scripts can read i.duration after resolve
      i.duration = i.duration or (n.media_duration - i.media_start)
      -- sequential chaining: after = {ref_node, gap} places this clip when the
      -- referenced (earlier-created) clip ends. Resolution is in creation order,
      -- so the ref's at/duration are already final.
      if i.after then
        local ref = i.after[1] or i.after.node
        local gap = i.after[2] or i.after.gap or 0
        assert(ref and ref.initial and ref.initial.duration,
          "moonsplice: audio after={ref} must reference an earlier audio node")
        i.at = ref.initial.at + ref.initial.duration + gap
      end
      -- Forced alignment. Runs before the align_* scheduling props below, which
      -- need word offsets to place the clip at all.
      if (i.align or i.align_at or i.at_word) and (n.kind == "tts" or n.kind == "audio") then
        local words, phonemes = align_generate(n.afile, i.align_text or i.text or "")
        n.words = words
        n.phonemes = phonemes
      end
      -- align_at = { word = "Drop", at = 1.57 } OR { event = "beat", at = ... }
      if i.align_at then
        local target = i.align_at.at or i.align_at[2]
        if type(target) == "table" and target.initial then
          target = target.initial.at or 0
        end
        if i.align_at.word or i.align_at[1] then
          local want = normword(i.align_at.word or i.align_at[1])
          local hit
          for _, w in ipairs(n.words or {}) do
            if normword(w.text) == want then hit = w break end
          end
          if not hit then
            error(("moonsplice resolve: align_at word %q not spoken in %q"):format(
              i.align_at.word or i.align_at[1], i.text or ""), 0)
          end
          i.at = target - hit.t0
        elseif i.align_at.event then
          local want = (i.align_at.event):lower()
          local hit
          for _, ev in ipairs(n.events or {}) do
            if (ev.name and ev.name:lower() == want) or (ev.type and ev.type:lower() == want) then
              hit = ev break
            end
          end
          if hit then
            i.at = target - hit.t0
          end
        end
        if i.at and i.at < 0 then
          io.stderr:write(("moonsplice: align_at pulled %q to %.2fs (before zero) — clamped\n"):format(i.text or "?", i.at))
          i.at = 0
        end
      end
      -- at_word = { ref_node, "languages", gap } — start when another aligned
      -- clip finishes saying a given word.
      if i.at_word then
        local ref = i.at_word[1]
        assert(ref and ref.words, "moonsplice: at_word needs an earlier aligned node")
        local want, hit = normword(i.at_word[2]), nil
        for _, w in ipairs(ref.words) do
          if normword(w.text) == want then hit = w break end
        end
        assert(hit, "moonsplice: at_word word not found: " .. tostring(i.at_word[2]))
        i.at = ref.initial.at + hit.t1 + (i.at_word[3] or 0)
      end
      if i.follow then
        i.energy = bake_energy(n.afile, i.media_start or 0, i.duration)
      end
    elseif n.kind == "html" then
      if n.initial.src and not n.initial.html then
        local f = assert(_MOONSPLICE_IOOPEN(localize(n.initial.src), "r"),
          "moonsplice resolve: html src not found: " .. n.initial.src)
        n.initial.html = f:read("*a")
        f:close()
      end
    elseif n.kind == "page" then
      -- Fetch HTML + subresources here, then cache a viewport PNG. Painter is
      -- a static image draw — no network and no JS in evaluate(t).
      local html = require("html")
      if not html.available then
        error("moonsplice resolve: html dylib missing (build html/)")
      end
      local i = n.initial
      local src = i.src
      local base = i.base
      if src and src:match("^https?://") then
        base = base or src
        if not i.html then
          local f = assert(_MOONSPLICE_IOOPEN(localize(src), "r"),
            "moonsplice resolve: page src not found: " .. src)
          i.html = f:read("*a")
          f:close()
        end
      elseif src then
        local path = localize(src)
        if not i.html then
          local f = assert(_MOONSPLICE_IOOPEN(path, "r"),
            "moonsplice resolve: page src not found: " .. src)
          i.html = f:read("*a")
          f:close()
        end
        base = base or path
      end
      assert(i.html, "moonsplice resolve: page{html=} or page{src=} required")
      local w, h = i.w, i.h
      local png = cache_root() .. "/page/" .. sha1(table.concat({
        i.html, tostring(base or ""), tostring(w), tostring(h),
        i.bake == false and "0" or "1",
      }, "|")) .. ".png"
      if not exists(png) then
        assert(sh(("mkdir -p '%s/page'"):format(cache_root())))
        html.render_page_png(i.html, base or "", w, h, 1.0, png, i.bake ~= false)
      end
      n.file = png
    elseif n.kind == "svg" then
      local i = n.initial
      local src = localize(i.src)
      local png = cache_root() .. "/svg/" .. sha1(table.concat({ i.src, i.w, i.h }, "|")) .. ".png"
      if not exists(png) then
        assert(sh(("mkdir -p '%s/svg'"):format(cache_root())))
        local ok, out = sh(("resvg '%s' '%s' --width %d --height %d"):format(src, png, i.w, i.h))
        if not ok then error("moonsplice resolve: resvg failed:\n" .. out) end
      end
      n.file = png
    elseif n.kind == "spritesheet" then
      local i = n.initial
      local src = localize(i.src)
      local json_path = i.json and localize(i.json) or (src:match("%.json$") and src)
      if json_path then
        local f = assert(_MOONSPLICE_IOOPEN(json_path, "r"),
          "moonsplice resolve: spritesheet json not found: " .. json_path)
        local raw = f:read("*a")
        f:close()
        local data = require("moonsplice.json").decode(raw)
        local frames = {}
        if data.frames[1] then
          for _, fr in ipairs(data.frames) do
            frames[#frames + 1] = {
              x = fr.frame.x, y = fr.frame.y, w = fr.frame.w, h = fr.frame.h,
              duration = (fr.duration or 100) / 1000,
            }
          end
        else
          local list = {}
          for name, fr in pairs(data.frames) do
            list[#list + 1] = { name = name, fr = fr }
          end
          table.sort(list, function(a, b) return a.name < b.name end)
          for _, item in ipairs(list) do
            local fr = item.fr
            frames[#frames + 1] = {
              x = fr.frame.x, y = fr.frame.y, w = fr.frame.w, h = fr.frame.h,
              duration = (fr.duration or 100) / 1000,
            }
          end
        end
        assert(#frames > 0, "moonsplice resolve: spritesheet json has no frames")
        n.sheet = { frames = frames }
        if src:match("%.json$") then
          local img = i.image or (data.meta and data.meta.image)
          assert(img, "moonsplice resolve: spritesheet json missing meta.image")
          local dir = json_path:match("^(.*)/") or "."
          n.file = img:match("^/") and img or (dir .. "/" .. img)
        else
          n.file = src
        end
      else
        n.file = src
        n.sheet = { grid = true, cols = i.cols, rows = i.rows }
      end
      if not exists(n.file) then
        error("moonsplice resolve: spritesheet image not found: " .. n.file)
      end
    elseif n.kind == "displace" then
      if n.initial.src then
        n.file = localize(n.initial.src)
        if not exists(n.file) then
          error("moonsplice resolve: displace image not found: " .. n.initial.src)
        end
      end
    elseif n.kind == "text" and n.initial.src and not n.initial.cues then
      local path = localize(n.initial.src)
      local f = assert(_MOONSPLICE_IOOPEN(path, "r"), "moonsplice resolve: captions src not found: " .. n.initial.src)
      local raw = f:read("*a")
      f:close()
      local cap = require("moonsplice.captions")
      if path:match("%.csv$") then
        n.initial.cues = cap.normalize(cap.parse_csv(raw))
      else
        n.initial.cues = cap.normalize(cap.parse_srt(raw))
      end
    elseif n.kind == "spine" and n.initial.src and not n.initial.skeleton then
      local path = localize(n.initial.src)
      local f = assert(_MOONSPLICE_IOOPEN(path, "r"), "moonsplice resolve: spine src not found: " .. n.initial.src)
      local raw = f:read("*a")
      f:close()
      n.initial.skeleton = require("moonsplice.json").decode(raw)
    end
  end

  local tolerant = (os.getenv("MOONSPLICE_OFFLINE_OK") or "0") ~= "0"
  for _, n in ipairs(nodes) do
    if tolerant then
      local ok, err = pcall(resolve_one, n)
      if not ok then went_offline(n, err) end
    else
      resolve_one(n)
    end
  end
end

return R
