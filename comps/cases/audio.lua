-- Encode-path audio mix: public-domain piano roll muxed under a public-domain plate.
local e = require("moonsplice")

return e.comp {
  width = 1280, height = 720, duration = 3, fps = 30,
  background = "#000000",

  scene = function(s)
    s:video {
      src = "comps/assets/earth_night.webm",
      from = 0, duration = 3, media_start = 14,
    }
    s:audio {
      src = "comps/assets/piano.ogg",
      at = 0, duration = 3, media_start = 4,
      volume = 0.7, fade_in = 0.25, fade_out = 0.4,
    }
    -- A second clip at a NON-ZERO `at`. Delayed audio goes through adelay, which
    -- amix used to turn into a few ms of nothing while the render still reported
    -- success; the case only ever covered at = 0, so nothing caught it. Keep this.
    s:audio {
      src = "comps/assets/piano.ogg",
      at = 1.0, duration = 1.5, media_start = 20,
      volume = 0.35, fade_in = 0.1, fade_out = 0.2,
    }
    s:rect { x = 0, y = 540, w = 1280, h = 180, color = "#000000aa" }
    s:text { x = 48, y = 36, text = "20  AUDIO MIX", size = 22, color = "#ffffffcc" }
    s:text {
      x = 48, y = 572, text = "VIDEO + AUDIO", size = 48, color = "#e8edf7",
    }
    s:text {
      x = 48, y = 636, text = "Scott Joplin piano roll · public domain · ffmpeg filter_complex", size = 22,
      color = "#8b97b0",
    }
  end,
}
