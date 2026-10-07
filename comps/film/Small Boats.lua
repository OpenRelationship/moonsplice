-- SMALL BOATS — a short film, cut from real footage.
--
-- Not a template. The other long-form fixture in this repo is generated: a clip per chapter, a
-- dissolve at every seam, a lower third that writes on and off, the same shape ten times. That
-- is a load test wearing a film's clothes, and you can see it in one pass — every cut lands in
-- the same place for the same reason, which is no reason at all.
--
-- This is an edit. Every cut below was chosen after looking at the footage, and the in-points
-- are real moments in real clips: the burst of surf at 0:39 of the wave plate, the coracle
-- coming ashore at 0:22 of the fishing plate, the shipyard that appears at 1:15 of the marina
-- plate. The structure is an argument rather than a list --
--
--   I.   ONE      a single boat, held, long enough to become a fact
--   II.  MANY     five cuts, each wider than the last, each shorter than the last
--   III. THE WORK down to the water, people, no typography at all
--   IV.  THE SEA  one idea, held; the only place the sound is allowed to swell
--   V.   RETURN   the same boat, the same framing. The film closes where it opened.
--
-- -- and the typography only appears in II, because II is the only part making a claim that
-- needs a number under it.
--
-- The footage is four coasts -- Madeira, Croatia, Vietnam, Turkey -- and that is the subject
-- rather than a compromise. There is no Pexels library deep enough to cut one town honestly,
-- and a film that pretends otherwise is a film with a continuity error in every reel. So the
-- cut rhymes hull to hull across seas instead: the same trade, four places, one shape of boat.
--
-- Credits for every plate are in Plates/CREDITS.md, as the Pexels licence asks.
-- The sound is the footage's own: `Sound/` is cut from the recorded audio on the boat and
-- harbour plates, not generated.

local e = require("moonsplice")

-- ------------------------------------------------------------------------------ the format

local W, H = 1920, 1080
local FPS = 30
local RUNS = 146

-- 2.00:1, which is a decision and not a default. It is the ratio a lot of documentary work
-- sits at now: wider than the frame the footage was shot in, so every plate gets cropped and
-- every composition has to be re-found, and narrow enough that the bars read as intent rather
-- than as a letterbox somebody forgot to turn off.
local BAR = math.floor((H - W / 2.0) / 2 + 0.5)   -- 60px top and bottom

local INK = "#07090c"
local PAPER = "#f2ece1"      -- warm off-white; pure white against this footage is a hole
local DIM = "#f2ece1aa"
local SERIF = "comps/assets/fonts/Fraunces.ttf"
local MONO = "comps/assets/fonts/JetBrainsMono-Regular.ttf"

-- ------------------------------------------------------------------------------- the plates
--
-- Each one with the in-point that was actually chosen by watching it. `media_start` is the
-- moment in the clip; the comment is what is happening there.

local P = {
  boat    = "Plates/e-rope-a-boat-rope-hanging-in-t.mp4",      -- one turquoise boat, still water
  harbour = "../longform/Footage/02-fishing-harbour-boats.mp4", -- Madeira, boats under a cliff town
  marina  = "Plates/b-marina-drone-footage-of-marina-.mp4",     -- Mandalina: yachts, then the shipyard
  coast   = "../longform/Footage/04-aerial-view-coastline-vi.mp4", -- Croatia at golden hour
  work    = "Plates/f-nets-men-pulling-fishnet-whil.mp4",       -- a coracle coming ashore
  surf    = "Plates/g-waves-slow-motion-of-waves-cra.mp4",      -- backlit surf on rock
  road    = "../longform/Footage/01-coastal-road-sea.mp4",      -- a new motorway down to the sea
  street  = "../longform/Footage/03-old-town-narrow-street.mp4", -- cobbles, morning
}

-- ---------------------------------------------------------------------------- the grade
--
-- Four cameras, four days, four countries. Left alone they cut together like four different
-- films: the Croatian drone is cold and flat, the Madeira plate is warm and soft, the surf is
-- blown out on purpose. These are the corrections that make them one picture, and they are
-- per-plate because that is what a grade is -- there is no global setting that fixes all four.
local GRADE = {
  boat    = { effect_contrast = 1.12, effect_saturate = 1.06, effect_brightness = 1.02 },
  harbour = { effect_contrast = 1.10, effect_saturate = 0.94, effect_brightness = 0.99 },
  marina  = { effect_contrast = 1.22, effect_saturate = 0.90, effect_brightness = 1.14 },
  coast   = { effect_contrast = 1.08, effect_saturate = 1.04, effect_brightness = 1.03 },
  work    = { effect_contrast = 1.06, effect_saturate = 0.92, effect_brightness = 1.00 },
  surf    = { effect_contrast = 1.04, effect_saturate = 0.88, effect_brightness = 0.97 },
  road    = { effect_contrast = 1.10, effect_saturate = 0.96, effect_brightness = 0.98 },
  street  = { effect_contrast = 1.05, effect_saturate = 0.90, effect_brightness = 1.00 },
}

return e.comp {
  width = W, height = H, duration = RUNS, fps = FPS,
  background = INK,

  scene = function(s)
    -- ============================================================ components
    --
    -- Four of them, written here because they are this film's and no other's. Each is a
    -- function that builds nodes and hands back what the script needs to move.

    --- One shot. The whole of the edit is calls to this.
    --
    -- A cut is two shots whose windows do not overlap; a dissolve is two that do. Nothing else
    -- is needed, because a video node paints only inside its own `from`..`from+duration` and
    -- costs nothing outside it -- so the edit is a list of windows and the renderer does the
    -- rest. `push` is a slow scale over the shot's life: a still frame held for eight seconds
    -- is a still frame, and a frame that is very slightly growing is a held shot.
    local function shot(plate, at, runs, into, opts)
      opts = opts or {}
      local n = s:video {
        src = P[plate],
        from = at, duration = runs, media_start = into,
        x = 0, y = 0, w = W, h = H,
        opacity = opts.opacity or 1,
        scale = opts.push and 1.0 or nil,
        label = opts.label,
      }
      for k, v in pairs(GRADE[plate]) do n.initial[k] = v end
      return n
    end

    --- Type that arrives by being uncovered rather than by fading.
    --
    -- A fade is what you reach for when nothing else is available; it says nothing about the
    -- thing appearing. This wipes a mask off the words from the left, at the speed a hand
    -- would, with a hairline rule drawing out under them a beat behind. Both are real nodes
    -- the timeline can see and an editor can drag.
    local function titled(text, x, y, size, opts)
      opts = opts or {}
      local word = s:text {
        x = x, y = y, text = text, size = size, font = opts.font or SERIF,
        color = opts.color or PAPER, tracking = opts.tracking or 0,
        reveal = 0, label = opts.label or text,
      }
      local rule = s:rect {
        x = x, y = y + size * 1.28, w = 0, h = 1.5,
        color = opts.color or PAPER, opacity = 0.55, label = (opts.label or text) .. " rule",
      }
      return { word = word, rule = rule, width = opts.rule or (size * #text * 0.52) }
    end

    --- A figure that counts, and the word for what it counts.
    --
    -- The number is stepped rather than tweened, because `text` is not a number and pretending
    -- otherwise would mean rendering a float. Eighteen steps over the life of the shot is
    -- enough that it reads as counting and few enough that the timeline stays legible.
    local function figure(value, unit, x, y)
      local num = s:text {
        x = x, y = y, text = "0", size = 92, font = MONO, color = PAPER,
        tracking = -2, opacity = 0, label = unit .. " figure",
      }
      local cap = s:text {
        x = x + 4, y = y + 104, text = unit, size = 19, font = MONO, color = DIM,
        tracking = 3, opacity = 0, label = unit .. " caption",
      }
      return { num = num, cap = cap, value = value }
    end

    --- Where we are, small, in the corner. Appears after the cut and leaves before it ends,
    --- which is what stops it reading as a permanent badge.
    local function slug(place, x, y)
      return s:text {
        x = x, y = y, text = place, size = 17, font = MONO, color = DIM,
        tracking = 2.5, opacity = 0, label = place,
      }
    end

    -- ============================================================ I. ONE  (0:00 – 0:22)
    --
    -- Two seconds of black first. Nothing else in the film earns attention the way silence
    -- and a dark screen do, and it costs two seconds.

    local one = shot("boat", 2.0, 20.0, 8.0, { label = "One boat" })
    local title = titled("SMALL BOATS", 150, 470, 96, { tracking = 6, rule = 560, label = "Title" })
    local sub = s:text {
      x = 154, y = 600, text = "FOUR COASTS · ONE TRADE", size = 20, font = MONO,
      color = DIM, tracking = 5, opacity = 0, label = "Subtitle",
    }

    -- ============================================================ II. MANY  (0:22 – 0:58)
    --
    -- Five cuts, and the shape of the sequence is the argument: each shot is wider than the
    -- one before it and shorter than the one before it, so the picture opens out while the
    -- cutting closes in. The figures climb with it.

    local many1 = shot("harbour", 22.0, 9.0, 4.0, { label = "Forty" })
    local many2 = shot("coast", 31.0, 7.0, 118.0, { label = "Four hundred" })
    local many3 = shot("marina", 38.0, 6.0, 2.0, { label = "Twelve hundred" })
    local many4 = shot("coast", 44.0, 5.0, 196.0, { label = "The headland" })

    local f1 = figure(40, "BOATS", 150, 720)
    local f2 = figure(400, "BOATS", 150, 720)
    local f3 = figure(1200, "BERTHS", 150, 720)

    local sMadeira = slug("MADEIRA · 32.6°N", 1420, 180)
    local sCroatia = slug("ŠIBENIK · 43.7°N", 1420, 180)

    -- The road, and then the shipyard. Two shots that break the water: one is the way in,
    -- the other is what the marina is for when nobody is looking at it. The film needs a
    -- gear change here or the next section arrives as more of the same.
    local road = shot("road", 49.0, 4.0, 70.0, { label = "The way in" })
    local yard = shot("marina", 53.0, 5.0, 76.0, { label = "The yard" })

    -- ============================================================ III. THE WORK (0:58 – 1:32)
    --
    -- No typography at all for thirty-four seconds. The section is about people doing
    -- something difficult and a caption would be a second voice talking over it.

    local w1 = shot("work", 58.0, 8.0, 19.0, { label = "Rowing in" })
    local w2 = shot("work", 66.0, 7.0, 40.0, { label = "Up the slip" })
    local w3 = shot("work", 73.0, 6.0, 53.0, { label = "Lifted" })
    local w4 = shot("street", 79.0, 6.0, 55.0, { label = "The town behind it" })
    local w5 = shot("harbour", 85.0, 7.0, 20.0, { label = "At rest" })

    -- ============================================================ IV. THE SEA (1:32 – 1:58)
    --
    -- One idea, held. The dissolve at 1:44 is the only one in the film, and it is here because
    -- this is the only place where the meaning is "the same thing, later" rather than "next".

    local sea1 = shot("surf", 92.0, 13.0, 36.0, { label = "The sea" })
    local sea2 = shot("surf", 104.0, 9.0, 55.0, { label = "Settling", opacity = 0 })
    local gold = shot("coast", 113.0, 6.0, 0.5, { label = "Evening" })

    -- ============================================================ V. RETURN (1:58 – 2:26)

    local back = shot("marina", 119.0, 7.0, 30.0, { label = "Coming in" })
    -- The rhyme. Same plate, same framing as the first shot of the film, a different minute
    -- of it -- so it is recognisably the same boat and recognisably later.
    local last = shot("boat", 126.0, 18.0, 44.0, { label = "The same boat" })
    local end_title = titled("SMALL BOATS", 150, 830, 40, { tracking = 4, rule = 232, label = "End title" })
    local credit = s:text {
      x = 154, y = 900, text = "FOOTAGE: PEXELS · SEE CREDITS", size = 15, font = MONO,
      color = DIM, tracking = 3, opacity = 0, label = "Credit",
    }

    -- ============================================================ the format, on top
    --
    -- Built last so they are in front of every plate. Not animated, not clever: the frame is
    -- this shape for the whole film.
    s:rect { x = 0, y = 0, w = W, h = BAR, color = INK, label = "Frame top" }
    s:rect { x = 0, y = H - BAR, w = W, h = BAR, color = INK, label = "Frame bottom" }

    -- The two holds of black, as real nodes: one at the head, one at the tail. A composition
    -- whose background shows through is a composition that is relying on nothing being there,
    -- and "nothing is there" is not something an editor can drag.
    local head = s:rect { x = 0, y = 0, w = W, h = H, color = INK, opacity = 1, label = "Open on black" }
    local tail = s:rect { x = 0, y = 0, w = W, h = H, color = INK, opacity = 0, label = "Out to black" }

    -- ============================================================ sound

    s:audio { src = "Sound/bed-harbour.mp3", at = 0, volume = 0.5, fade_in = 2.5, fade_out = 6,
              label = "Harbour" }
    s:audio { src = "Sound/quay.mp3", at = 58.0, volume = 0.6, fade_in = 2, fade_out = 4,
              label = "The quay" }
    s:audio { src = "Sound/swell.mp3", at = 91.0, volume = 0.85, fade_in = 2.5, fade_out = 6,
              label = "Swell" }

    -- ============================================================ markers
    --
    -- Where the reels are, for anybody opening this in the editor.
    s:marker { at = 2.0,   text = "I · One" }
    s:marker { at = 22.0,  text = "II · Many" }
    s:marker { at = 58.0,  text = "III · The work" }
    s:marker { at = 92.0,  text = "IV · The sea" }
    s:marker { at = 119.0, text = "V · Return" }

    -- ============================================================ the cut
    --
    -- Written as an edit decision list: `t:at(seconds)` puts the cursor on a timecode and the
    -- moves that follow belong to that moment. Read top to bottom it is the film.

    s:script(function(t)
      -- I. ONE ---------------------------------------------------------------------------
      t:at(2.0)
      t:tween(head, 2.4, { opacity = 0 }, "sineInOut")       -- up from black, slowly

      t:at(6.0)
      t:parallel(
        function() t:tween(title.word, 1.5, { reveal = 1 }, "quadOut") end,
        function() t:wait(0.35); t:tween(title.rule, 1.3, { w = title.width }, "expoOut") end
      )
      t:at(8.2); t:tween(sub, 1.0, { opacity = 1 }, "sineOut")

      -- Out well before the cut, so the last four seconds of the shot are only the boat.
      t:at(15.5)
      t:parallel(
        function() t:tween(title.word, 1.1, { opacity = 0 }, "sineIn") end,
        function() t:tween(title.rule, 1.1, { opacity = 0 }, "sineIn") end,
        function() t:tween(sub, 1.1, { opacity = 0 }, "sineIn") end
      )
      -- The push: a fourteen-second hold that is almost imperceptibly closing in.
      t:at(2.0); t:tween(one, 20.0, { scale = 1.06 }, "linear")

      -- II. MANY -------------------------------------------------------------------------
      -- The figures. Each counts up inside its own shot and is gone before the cut.
      local function counts(fig, from, to, at, runs)
        t:at(at)
        t:parallel(
          function() t:tween(fig.num, 0.35, { opacity = 1 }, "quadOut") end,
          function() t:wait(0.2); t:tween(fig.cap, 0.4, { opacity = 1 }, "quadOut") end
        )
        local steps = 16
        for i = 1, steps do
          t:at(at + 0.25 + (runs * 0.45) * (i / steps))
          local v = math.floor(from + (to - from) * (i / steps) + 0.5)
          t:set(fig.num, { text = tostring(v) })
        end
        t:at(at + runs - 1.1)
        t:parallel(
          function() t:tween(fig.num, 0.7, { opacity = 0 }, "sineIn") end,
          function() t:tween(fig.cap, 0.7, { opacity = 0 }, "sineIn") end
        )
      end

      counts(f1, 1, 40, 22.4, 9.0)
      counts(f2, 40, 400, 31.3, 7.0)
      counts(f3, 400, 1200, 38.3, 6.0)

      -- The locators. In after the cut has landed, out before it goes.
      t:at(22.8); t:tween(sMadeira, 0.5, { opacity = 1 }, "quadOut")
      t:at(29.0); t:tween(sMadeira, 0.6, { opacity = 0 }, "sineIn")
      t:at(31.6); t:tween(sCroatia, 0.5, { opacity = 1 }, "quadOut")
      t:at(36.4); t:tween(sCroatia, 0.6, { opacity = 0 }, "sineIn")

      -- Each shot in this section pushes a little harder than the last, which is the same
      -- acceleration the cutting is doing, felt rather than seen.
      t:at(22.0); t:tween(many1, 9.0, { scale = 1.04 }, "linear")
      t:at(31.0); t:tween(many2, 7.0, { scale = 1.05 }, "linear")
      t:at(38.0); t:tween(many3, 6.0, { scale = 1.06 }, "linear")
      t:at(44.0); t:tween(many4, 5.0, { scale = 1.07 }, "linear")
      t:at(49.0); t:tween(road, 4.0, { scale = 1.05 }, "linear")
      t:at(53.0); t:tween(yard, 5.0, { scale = 1.04 }, "linear")

      -- III. THE WORK --------------------------------------------------------------------
      -- Longer holds, gentler pushes. The section is meant to slow the pulse down.
      t:at(58.0); t:tween(w1, 8.0, { scale = 1.03 }, "linear")
      t:at(66.0); t:tween(w2, 7.0, { scale = 1.03 }, "linear")
      t:at(73.0); t:tween(w3, 6.0, { scale = 1.04 }, "linear")
      t:at(79.0); t:tween(w4, 6.0, { scale = 1.03 }, "linear")
      t:at(85.0); t:tween(w5, 7.0, { scale = 1.02 }, "linear")

      -- IV. THE SEA ----------------------------------------------------------------------
      t:at(92.0); t:tween(sea1, 13.0, { scale = 1.05 }, "linear")
      -- The one dissolve in the film. A second and a half, which is long enough to be read as
      -- a dissolve rather than as a soft cut.
      t:at(104.0); t:tween(sea2, 1.5, { opacity = 1 }, "sineInOut")
      t:at(104.0); t:tween(sea2, 9.0, { scale = 1.04 }, "linear")
      t:at(113.0); t:tween(gold, 6.0, { scale = 1.04 }, "linear")

      -- V. RETURN ------------------------------------------------------------------------
      t:at(119.0); t:tween(back, 7.0, { scale = 1.03 }, "linear")
      -- The closing shot is the only one in the film that pulls back rather than pushing in.
      t:at(126.0); t:tween(last, 18.0, { scale = 1.05 }, "linear")

      t:at(131.0)
      t:parallel(
        function() t:tween(end_title.word, 1.2, { reveal = 1 }, "quadOut") end,
        function() t:wait(0.3); t:tween(end_title.rule, 1.2, { w = end_title.width }, "expoOut") end,
        function() t:wait(0.9); t:tween(credit, 0.9, { opacity = 1 }, "sineOut") end
      )

      t:at(140.0)
      t:tween(tail, 4.0, { opacity = 1 }, "sineInOut")
    end)
  end,
}
