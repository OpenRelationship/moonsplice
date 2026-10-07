-- Why a thing could not be made ready, in a word, and taking it off the air. Part of resolve.
local R = require("resolve")

-- Why one thing could not be made ready, in a word.
--
-- A word and not the renderer's sentence, because the sentence names a file and a file name is
-- the one thing this app never shows. The word becomes English in `editor/vocabulary.json`,
-- next to every other word the UI is allowed to say.
local WHY_OFFLINE = {
  { "ELEVENLABS_API_KEY", "needs a key" },
  { "OPENROUTER_API_KEY", "needs a key" },
  { "API_KEY", "needs a key" },
  { "not found", "missing" },
  { "No such file", "missing" },
  { "cannot read", "missing" },
  { "cannot open", "missing" },
  { "unreadable", "missing" },
  { "download failed", "missing" },
  { "fetch failed", "missing" },
  { "cannot probe", "unreadable" },
  { "no frames extracted", "unreadable" },
  { "load failed", "unreadable" },
  { "failed", "unreadable" },
}

function R.why_offline(err)
  local s = tostring(err)
  for _, rule in ipairs(WHY_OFFLINE) do
    if s:find(rule[1], 1, true) then return rule[2] end
  end
  return "would not load"
end

-- One thing that cannot be made ready takes itself off the air; the composition still opens.
--
-- Every editor does this and calls the clip offline, because the alternative is what this used
-- to do: one file moved, and a ten minute edit would not open at all -- no picture, no timeline,
-- and nothing on screen to say which of two hundred things was the problem or that the other
-- hundred and ninety-nine were fine.
--
-- It is off by default and the app turns it on (`MOONSPLICE_OFFLINE_OK`, set by
-- `editor/src-tauri/src/engine.rs`). A render must still refuse: a slate that quietly ships
-- inside an export is a far worse failure than one that stops the export.
local function went_offline(n, err)
  n.offline = R.why_offline(err)
  io.stderr:write(("moonsplice resolve: %s is offline (%s): %s\n"):format(
    tostring(n.id), n.offline, tostring(err):gsub("%s+", " ")))
  -- Whatever it was going to hold, it does not. Everything downstream already checks for nil,
  -- because a node that never named a file has had these nil all along.
  n.dec, n.file, n.afile, n.frames_dir, n.frame_count = nil, nil, nil, nil, nil
  local i = n.initial
  -- A sound with no length is a sound the timeline cannot draw and the mix cannot place, and
  -- the length usually came off the file that is not there. It keeps what it was written with,
  -- and falls back to a plain few seconds when it was never written with one.
  if n.kind == "audio" or n.kind == "tts" or n.kind == "sfx" or n.kind == "music" then
    n.media_duration = n.media_duration or i.duration or 3
    i.duration = i.duration or n.media_duration
    i.at = i.at or 0
  end
end


return {
  went_offline = went_offline,
}
