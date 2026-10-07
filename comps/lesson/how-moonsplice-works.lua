-- How Moonsplice Works -- an educational composition, rendered by the system it explains.
--
-- Narration : moonsplice tts --provider openrouter   (openai/gpt-audio-mini)
-- Cue times : vision/moonsplice_vision/audiofacts.align  (word timings, frame-accurate)
-- Generated : tools/make-lesson.py -- do not hand-edit, regenerate instead.
--
-- One script, not one per chapter. Every s:script runs, but they share a single
-- recorder cursor, so a second one starts where the first ended rather than at zero.
-- Keeping it to one timeline means the generator owns absolute time outright.
local e = require("moonsplice")

local MONO = "comps/assets/fonts/JetBrainsMono-Regular.ttf"
local SANS = "comps/assets/fonts/Roboto-Regular.ttf"
local BOLD = "comps/assets/fonts/Roboto-Bold.ttf"

local TEAL, BLUE, AMBER, PINK = "#3ee0c6", "#4f8cff", "#f2b33d", "#e85aa8"
local INK, DIM, FAINT, PANEL = "#e8edf7", "#8593a8", "#818ea6", "#141b26"

local unpack = table.unpack or unpack

return e.comp {
  width = 1920, height = 1080, duration = 160.45, fps = 30,
  -- Acknowledged, not hidden: lint counts these and reports the count. A generated
  -- lesson comp reuses one ease and keeps several things moving at once by construction.
  lint_allow = { "ease_monoculture", "motion_density", "competing_beats",
    -- 22-26px mono annotation at 1920x1080. The floor is tuned for captions, and
    -- these are labels and code lines read on a large frame, not subtitles.
    "text_min_size" },
  background = "#0a0e14",

  scene = function(s)
    -- helpers ---------------------------------------------------------------
    local function fade(t, nodes, d, each, to)
      local fns = {}
      for i, n in ipairs(nodes) do
        fns[i] = function() t:wait((i - 1) * each); t:tween(n, d, { opacity = to }, "sineOut") end
      end
      t:parallel(unpack(fns))
    end

    -- narration: one clip per chapter, placed at its baked time ---------------
    s:audio { src = "comps/lesson/narration/00_open.mp3", at = 0.600, volume = 1.0,
      text = "This video was made by the system it describes. Every frame you are about to see is a Moonsplice composition, and the voice is running through its own audio pipeline." }
    s:audio { src = "comps/lesson/narration/01_fn.mp3", at = 11.750, volume = 1.0,
      text = "Most video tools store a timeline: a list of clips, laid end to end. Moonsplice stores a function instead. You hand it a time, in seconds, and it returns the frame at that time. Nothing is kept. Everything is computed." }
    s:audio { src = "comps/lesson/narration/02_seek.mp3", at = 27.300, volume = 1.0,
      text = "Because a frame depends only on its own time, frame nine hundred does not need the eight hundred and ninety nine frames before it. The renderer can jump anywhere, in any order, and always get the same answer." }
    s:audio { src = "comps/lesson/narration/03_declare.mp3", at = 40.100, volume = 1.0,
      text = "A composition declares what exists. A rectangle here, a line of type there, and how each of them changes over time. It never issues a draw call. The scene graph is just data, evaluated fresh every time you ask for a frame." }
    s:audio { src = "comps/lesson/narration/04_det.mp3", at = 56.550, volume = 1.0,
      text = "The renderer owns the virtual machine. The clock is stubbed out, the random seed is fixed, and no file or network access happens while a frame is being drawn. So the same composition, rendered twice, produces the same bytes." }
    s:audio { src = "comps/lesson/narration/05_hash.mp3", at = 71.150, volume = 1.0,
      text = "That turns eyeballing into arithmetic. Move one caption three tenths of a second later, re-render, and compare all one hundred and eight frame hashes. Nine of them differ. Ninety nine are identical. You know exactly what your change touched." }
    s:audio { src = "comps/lesson/narration/06_lift.mp3", at = 85.750, volume = 1.0,
      text = "Now the useful part. Because the composition knows its own structure, every node, every position, every cue time, it can write itself down. Not as pixels, but as facts. What holds, over which interval. What happens, at which instant." }
    s:audio { src = "comps/lesson/narration/07_perceive.mp3", at = 102.950, volume = 1.0,
      text = "Point that grammar at real video and the shape stays the same. A tracker, a depth model, an aligner: each one measures something and writes a fact. But a measurement can be wrong, so every perceived fact carries its producer and its confidence. A fact with no source is exact. That one rule tells a reader which kind it is holding." }
    s:audio { src = "comps/lesson/narration/08_lower.mp3", at = 126.350, volume = 1.0,
      text = "And the facts go back. Name a node, a verb, and a time. The lowering rewrites the source that produced the fact, and the frame hashes prove the edit touched only what it named." }
    s:audio { src = "comps/lesson/narration/09_why.mp3", at = 138.200, volume = 1.0,
      text = "Models cannot reliably edit video from pixels. They describe a clip fluently, and wrongly. But they can read a grammar with times and identities in it, and they can write one back. Everything else, the purity, the determinism, the hashes, exists to make that last step safe." }
    s:audio { src = "comps/lesson/narration/10_close.mp3", at = 155.750, volume = 1.0,
      text = "Moonsplice. Programmatic video from Lua." }

    -- captions: word-aligned, so the line turns over when the voice does -----
    s:captions { x = 960, y = 946, size = 38, font = SANS, color = INK,
      anchor = "center", cues = {
        { 0.740, 2.922, "This video was made by the system" },
        { 2.922, 5.370, "it describes. Every frame you are about" },
        { 5.370, 7.505, "to see is a Moonsplice composition," },
        { 7.505, 9.195, "and the voice is running through its" },
        { 9.195, 10.880, "own audio pipeline." },
        { 11.840, 14.580, "Most video tools store a timeline:" },
        { 14.580, 15.635, "a list of clips," },
        { 15.635, 16.850, "laid end to end." },
        { 16.850, 18.935, "Moonsplice stores a function instead." },
        { 18.935, 20.110, "You hand it a time," },
        { 20.110, 22.157, "in seconds, and it returns the frame" },
        { 22.157, 23.090, "at that time." },
        { 23.090, 24.170, "Nothing is kept." },
        { 24.170, 25.829, "Everything is computed." },
        { 27.400, 29.945, "Because a frame depends only on its" },
        { 29.945, 32.400, "own time, frame nine hundred does not" },
        { 32.400, 33.831, "need the eight hundred and ninety nine" },
        { 33.831, 35.090, "frames before it." },
        { 35.090, 36.580, "The renderer can jump anywhere," },
        { 36.580, 37.445, "in any order," },
        { 37.445, 39.209, "and always get the same answer." },
        { 40.100, 43.120, "A composition declares what exists." },
        { 43.120, 44.540, "A rectangle here," },
        { 44.540, 46.285, "a line of type there," },
        { 46.285, 47.995, "and how each of them changes over" },
        { 47.995, 50.745, "time. It never issues a draw call." },
        { 50.745, 52.500, "The scene graph is just data," },
        { 52.500, 54.889, "evaluated fresh every time you ask for" },
        { 54.889, 55.640, "a frame." },
        { 56.550, 59.370, "The renderer owns the virtual machine." },
        { 59.370, 60.755, "The clock is stubbed out," },
        { 60.755, 62.250, "the random seed is fixed," },
        { 62.250, 64.440, "and no file or network access happens" },
        { 64.440, 66.170, "while a frame is being drawn." },
        { 66.170, 67.800, "So the same composition," },
        { 67.800, 70.350, "rendered twice, produces the same bytes." },
        { 71.210, 74.085, "That turns eyeballing into arithmetic." },
        { 74.085, 75.855, "Move one caption three tenths of a" },
        { 75.855, 77.415, "second later, re-render," },
        { 77.415, 79.000, "and compare all one hundred and eight" },
        { 79.000, 81.120, "frame hashes. Nine of them differ." },
        { 81.120, 82.645, "Ninety nine are identical." },
        { 82.645, 84.879, "You know exactly what your change touched." },
        { 85.830, 87.890, "Now the useful part." },
        { 87.890, 90.495, "Because the composition knows its own structure," },
        { 90.495, 92.245, "every node, every position," },
        { 92.245, 93.545, "every cue time," },
        { 93.545, 95.230, "it can write itself down." },
        { 95.230, 96.280, "Not as pixels," },
        { 96.280, 97.575, "but as facts." },
        { 97.575, 99.525, "What holds, over which interval." },
        { 99.525, 101.679, "What happens, at which instant." },
        { 102.970, 105.452, "Point that grammar at real video and" },
        { 105.452, 107.485, "the shape stays the same." },
        { 107.485, 109.275, "A tracker, a depth model," },
        { 109.275, 111.895, "an aligner: each one measures something and" },
        { 111.895, 113.155, "writes a fact." },
        { 113.155, 114.740, "But a measurement can be wrong," },
        { 114.740, 117.895, "so every perceived fact carries its producer" },
        { 117.895, 119.330, "and its confidence." },
        { 119.330, 121.785, "A fact with no source is exact." },
        { 121.785, 123.685, "That one rule tells a reader which" },
        { 123.685, 125.019, "kind it is holding." },
        { 126.350, 128.230, "And the facts go back." },
        { 128.230, 129.225, "Name a node," },
        { 129.225, 130.890, "a verb, and a time." },
        { 130.890, 132.996, "The lowering rewrites the source that produced" },
        { 132.996, 134.875, "the fact, and the frame hashes prove" },
        { 134.875, 137.049, "the edit touched only what it named." },
        { 138.280, 142.000, "Models cannot reliably edit video from pixels." },
        { 142.000, 143.505, "They describe a clip fluently," },
        { 143.505, 145.280, "and wrongly. But they can read a" },
        { 145.280, 147.665, "grammar with times and identities in it," },
        { 147.665, 149.245, "and they can write one back." },
        { 149.245, 150.765, "Everything else, the purity," },
        { 150.765, 152.245, "the determinism, the hashes," },
        { 152.245, 154.740, "exists to make that last step safe." },
        { 155.750, 158.776, "Moonsplice. Programmatic video from Lua." },
      } }

    -- nodes ------------------------------------------------------------------
    local N = {}
    -- Runs the whole comp, inside the parallel below. Without continuous motion
    -- a chapter that fades in and holds is a frozen frame, which lint rejects.
    N.rail_bg = s:rect { x = 120, y = 1032, w = 1680, h = 3, color = PANEL }
    N.rail = s:rect { x = 120, y = 1032, w = 6, h = 3, color = TEAL }

    -- open ----------------------------------------------------------------
    N.op_t = s:text { x = 960, y = 432, text = "How Moonsplice Works", size = 104, font = BOLD, color = INK, anchor = "center", opacity = 0 }
    N.op_s = s:text { x = 960, y = 520, text = "made by the system it describes", size = 34, font = SANS, color = DIM, anchor = "center", opacity = 0 }
    N.op_c0 = s:rect { x = 240, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c1 = s:rect { x = 300, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c2 = s:rect { x = 360, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c3 = s:rect { x = 420, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c4 = s:rect { x = 480, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c5 = s:rect { x = 540, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c6 = s:rect { x = 600, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c7 = s:rect { x = 660, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c8 = s:rect { x = 720, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c9 = s:rect { x = 780, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c10 = s:rect { x = 840, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c11 = s:rect { x = 900, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c12 = s:rect { x = 960, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c13 = s:rect { x = 1020, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c14 = s:rect { x = 1080, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c15 = s:rect { x = 1140, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c16 = s:rect { x = 1200, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c17 = s:rect { x = 1260, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c18 = s:rect { x = 1320, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c19 = s:rect { x = 1380, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c20 = s:rect { x = 1440, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c21 = s:rect { x = 1500, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c22 = s:rect { x = 1560, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_c23 = s:rect { x = 1620, y = 640, w = 52, h = 34, rx = 3, color = PANEL, opacity = 0 }
    N.op_p = s:rect { x = 240, y = 640, w = 52, h = 34, rx = 3, color = TEAL, opacity = 0 }

    -- fn ------------------------------------------------------------------
    N.fn_n = s:text { x = 120, y = 112, text = "01", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.fn_t = s:text { x = 120, y = 150, text = "A composition is a function", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.fn_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.fn_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.fn_pl = s:rect { x = 180, y = 392, w = 520, h = 264, rx = 10, color = PANEL, opacity = 0 }
    N.fn_ll = s:text { x = 214, y = 424, text = "time", size = 22, font = MONO, color = FAINT, opacity = 0 }
    N.fn_ar = s:rect { x = 736, y = 520, w = 150, h = 4, color = FAINT, opacity = 0 }
    N.fn_ah = s:circle { x = 898, y = 522, r = 8, color = FAINT, opacity = 0 }
    N.fn_pr = s:rect { x = 940, y = 352, w = 800, h = 344, rx = 10, color = PANEL, opacity = 0 }
    N.fn_lr = s:text { x = 974, y = 384, text = "frame", size = 22, font = MONO, color = FAINT, opacity = 0 }
    N.fn_d = s:circle { x = 1050, y = 560, r = 44, color = TEAL, opacity = 0 }
    N.fn_c = s:text { x = 960, y = 740, text = "the frame is computed, never stored", size = 28, font = SANS, color = DIM, anchor = "center", opacity = 0 }
    s:captions { x = 440, y = 540, size = 58, font = MONO,   -- fn_ro
      color = TEAL, anchor = "center", cues = {
        { 17.150, 17.350, "t = 0.00" },
        { 17.350, 17.550, "t = 0.19" },
        { 17.550, 17.750, "t = 0.38" },
        { 17.750, 17.950, "t = 0.56" },
        { 17.950, 18.150, "t = 0.75" },
        { 18.150, 18.350, "t = 0.94" },
        { 18.350, 18.550, "t = 1.12" },
        { 18.550, 18.750, "t = 1.31" },
        { 18.750, 18.950, "t = 1.50" },
        { 18.950, 19.150, "t = 1.69" },
        { 19.150, 19.350, "t = 1.88" },
        { 19.350, 19.550, "t = 2.06" },
        { 19.550, 19.750, "t = 2.25" },
        { 19.750, 19.950, "t = 2.44" },
        { 19.950, 20.150, "t = 2.62" },
        { 20.150, 20.350, "t = 2.81" },
        { 20.350, 20.550, "t = 3.00" },
        { 20.550, 20.750, "t = 3.19" },
        { 20.750, 20.950, "t = 3.38" },
        { 20.950, 21.150, "t = 3.56" },
        { 21.150, 21.350, "t = 3.75" },
        { 21.350, 21.550, "t = 3.94" },
        { 21.550, 21.750, "t = 4.12" },
        { 21.750, 21.950, "t = 4.31" },
        { 21.950, 22.150, "t = 4.50" },
        { 22.150, 22.350, "t = 4.69" },
        { 22.350, 22.550, "t = 4.88" },
        { 22.550, 22.750, "t = 5.06" },
        { 22.750, 22.950, "t = 5.25" },
        { 22.950, 23.150, "t = 5.44" },
        { 23.150, 23.350, "t = 5.62" },
        { 23.350, 23.550, "t = 5.81" },
      } }

    -- seek ----------------------------------------------------------------
    N.sk_n = s:text { x = 120, y = 112, text = "02", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.sk_t = s:text { x = 120, y = 150, text = "Seek, not playback", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.sk_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.sk_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.sk_c0 = s:rect { x = 168, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c1 = s:rect { x = 212, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c2 = s:rect { x = 256, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c3 = s:rect { x = 300, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c4 = s:rect { x = 344, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c5 = s:rect { x = 388, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c6 = s:rect { x = 432, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c7 = s:rect { x = 476, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c8 = s:rect { x = 520, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c9 = s:rect { x = 564, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c10 = s:rect { x = 608, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c11 = s:rect { x = 652, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c12 = s:rect { x = 696, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c13 = s:rect { x = 740, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c14 = s:rect { x = 784, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c15 = s:rect { x = 828, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c16 = s:rect { x = 872, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c17 = s:rect { x = 916, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c18 = s:rect { x = 960, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c19 = s:rect { x = 1004, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c20 = s:rect { x = 1048, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c21 = s:rect { x = 1092, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c22 = s:rect { x = 1136, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c23 = s:rect { x = 1180, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c24 = s:rect { x = 1224, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c25 = s:rect { x = 1268, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c26 = s:rect { x = 1312, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c27 = s:rect { x = 1356, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c28 = s:rect { x = 1400, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c29 = s:rect { x = 1444, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c30 = s:rect { x = 1488, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c31 = s:rect { x = 1532, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c32 = s:rect { x = 1576, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c33 = s:rect { x = 1620, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c34 = s:rect { x = 1664, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_c35 = s:rect { x = 1708, y = 462, w = 38, h = 58, rx = 3, color = PANEL, opacity = 0 }
    N.sk_p = s:rect { x = 168, y = 462, w = 38, h = 58, rx = 3, color = TEAL, opacity = 0 }
    N.sk_l = s:text { x = 960, y = 700, text = "any frame, any order, same answer", size = 28, font = SANS, color = DIM, anchor = "center", opacity = 0 }
    s:captions { x = 960, y = 600, size = 42, font = MONO,   -- sk_ro
      color = TEAL, anchor = "center", cues = {
        { 29.500, 30.360, "frame 12" },
        { 30.360, 31.220, "frame 31" },
        { 31.220, 32.080, "frame 4" },
        { 32.080, 32.940, "frame 22" },
        { 32.940, 33.800, "frame 9" },
        { 33.800, 34.660, "frame 35" },
        { 34.660, 35.520, "frame 17" },
      } }

    -- declare -------------------------------------------------------------
    N.dc_n = s:text { x = 120, y = 112, text = "03", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.dc_t = s:text { x = 120, y = 150, text = "Describe, don't draw", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.dc_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.dc_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.dc_l0 = s:text { x = 180, y = 404, text = "s:rect   { x = 1180, y = 392, w = 300, h = 170 }", size = 25, font = MONO, color = DIM, opacity = 0 }
    N.dc_l1 = s:text { x = 180, y = 456, text = "s:circle { x = 1610, y = 478, r = 84 }", size = 25, font = MONO, color = DIM, opacity = 0 }
    N.dc_l2 = s:text { x = 180, y = 508, text = "s:text   { text = \"TYPE\", size = 64 }", size = 25, font = MONO, color = DIM, opacity = 0 }
    N.dc_l3 = s:text { x = 180, y = 560, text = "t:tween(box, 0.9, { x = 1060 })", size = 25, font = MONO, color = DIM, opacity = 0 }
    N.dc_b = s:rect { x = 1180, y = 392, w = 300, h = 170, rx = 8, color = BLUE, opacity = 0 }
    N.dc_d = s:circle { x = 1610, y = 478, r = 84, color = TEAL, opacity = 0 }
    N.dc_y = s:text { x = 1180, y = 610, text = "TYPE", size = 64, font = BOLD, color = INK, opacity = 0 }
    N.dc_c = s:text { x = 180, y = 700, text = "the scene graph is data, evaluated fresh", size = 26, font = SANS, color = FAINT, opacity = 0 }

    -- det -----------------------------------------------------------------
    N.dt_n = s:text { x = 120, y = 112, text = "04", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.dt_t = s:text { x = 120, y = 150, text = "Determinism by construction", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.dt_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.dt_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.dt_p0 = s:rect { x = 240, y = 372, w = 600, h = 300, rx = 10, color = PANEL, opacity = 0 }
    N.dt_h0 = s:text { x = 272, y = 402, text = "render 1", size = 22, font = MONO, color = FAINT, opacity = 0 }
    N.dt_c0 = s:circle { x = 410, y = 530, r = 54, color = TEAL, opacity = 0 }
    N.dt_r0 = s:rect { x = 540, y = 486, w = 180, h = 92, rx = 8, color = BLUE, opacity = 0 }
    N.dt_s0 = s:text { x = 540, y = 712, text = "15ca0cde58d07a47", size = 26, font = MONO, color = AMBER, anchor = "center", opacity = 0 }
    N.dt_p1 = s:rect { x = 1080, y = 372, w = 600, h = 300, rx = 10, color = PANEL, opacity = 0 }
    N.dt_h1 = s:text { x = 1112, y = 402, text = "render 2", size = 22, font = MONO, color = FAINT, opacity = 0 }
    N.dt_c1 = s:circle { x = 1250, y = 530, r = 54, color = TEAL, opacity = 0 }
    N.dt_r1 = s:rect { x = 1380, y = 486, w = 180, h = 92, rx = 8, color = BLUE, opacity = 0 }
    N.dt_s1 = s:text { x = 1380, y = 712, text = "15ca0cde58d07a47", size = 26, font = MONO, color = AMBER, anchor = "center", opacity = 0 }
    N.dt_v = s:text { x = 960, y = 790, text = "same bytes, every time", size = 34, font = BOLD, color = TEAL, anchor = "center", opacity = 0 }
    N.dt_l = s:text { x = 960, y = 848, text = "clock stubbed  ·  seed fixed  ·  no I/O while drawing", size = 24, font = SANS, color = FAINT, anchor = "center", opacity = 0 }

    -- hash ----------------------------------------------------------------
    N.hs_n = s:text { x = 120, y = 112, text = "05", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.hs_t = s:text { x = 120, y = 150, text = "A hash is a test", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.hs_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.hs_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.hs_c0 = s:rect { x = 180, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c1 = s:rect { x = 232, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c2 = s:rect { x = 284, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c3 = s:rect { x = 336, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c4 = s:rect { x = 388, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c5 = s:rect { x = 440, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c6 = s:rect { x = 492, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c7 = s:rect { x = 544, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c8 = s:rect { x = 596, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c9 = s:rect { x = 648, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c10 = s:rect { x = 700, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c11 = s:rect { x = 752, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c12 = s:rect { x = 804, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c13 = s:rect { x = 856, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c14 = s:rect { x = 908, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c15 = s:rect { x = 960, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c16 = s:rect { x = 1012, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c17 = s:rect { x = 1064, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c18 = s:rect { x = 1116, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c19 = s:rect { x = 1168, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c20 = s:rect { x = 1220, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c21 = s:rect { x = 1272, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c22 = s:rect { x = 1324, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c23 = s:rect { x = 1376, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c24 = s:rect { x = 1428, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c25 = s:rect { x = 1480, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c26 = s:rect { x = 1532, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c27 = s:rect { x = 1584, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c28 = s:rect { x = 1636, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c29 = s:rect { x = 1688, y = 420, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c30 = s:rect { x = 180, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c31 = s:rect { x = 232, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c32 = s:rect { x = 284, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c33 = s:rect { x = 336, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c34 = s:rect { x = 388, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c35 = s:rect { x = 440, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c36 = s:rect { x = 492, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c37 = s:rect { x = 544, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c38 = s:rect { x = 596, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c39 = s:rect { x = 648, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c40 = s:rect { x = 700, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c41 = s:rect { x = 752, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c42 = s:rect { x = 804, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c43 = s:rect { x = 856, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c44 = s:rect { x = 908, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c45 = s:rect { x = 960, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c46 = s:rect { x = 1012, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c47 = s:rect { x = 1064, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c48 = s:rect { x = 1116, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c49 = s:rect { x = 1168, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c50 = s:rect { x = 1220, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c51 = s:rect { x = 1272, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c52 = s:rect { x = 1324, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c53 = s:rect { x = 1376, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c54 = s:rect { x = 1428, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c55 = s:rect { x = 1480, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c56 = s:rect { x = 1532, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c57 = s:rect { x = 1584, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c58 = s:rect { x = 1636, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c59 = s:rect { x = 1688, y = 454, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c60 = s:rect { x = 180, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c61 = s:rect { x = 232, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c62 = s:rect { x = 284, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c63 = s:rect { x = 336, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c64 = s:rect { x = 388, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c65 = s:rect { x = 440, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c66 = s:rect { x = 492, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c67 = s:rect { x = 544, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c68 = s:rect { x = 596, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c69 = s:rect { x = 648, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c70 = s:rect { x = 700, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c71 = s:rect { x = 752, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c72 = s:rect { x = 804, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c73 = s:rect { x = 856, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c74 = s:rect { x = 908, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c75 = s:rect { x = 960, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c76 = s:rect { x = 1012, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c77 = s:rect { x = 1064, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c78 = s:rect { x = 1116, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c79 = s:rect { x = 1168, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c80 = s:rect { x = 1220, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c81 = s:rect { x = 1272, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c82 = s:rect { x = 1324, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c83 = s:rect { x = 1376, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c84 = s:rect { x = 1428, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c85 = s:rect { x = 1480, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c86 = s:rect { x = 1532, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c87 = s:rect { x = 1584, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c88 = s:rect { x = 1636, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c89 = s:rect { x = 1688, y = 488, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c90 = s:rect { x = 180, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c91 = s:rect { x = 232, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c92 = s:rect { x = 284, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c93 = s:rect { x = 336, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c94 = s:rect { x = 388, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c95 = s:rect { x = 440, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c96 = s:rect { x = 492, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c97 = s:rect { x = 544, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c98 = s:rect { x = 596, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c99 = s:rect { x = 648, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c100 = s:rect { x = 700, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c101 = s:rect { x = 752, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c102 = s:rect { x = 804, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c103 = s:rect { x = 856, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c104 = s:rect { x = 908, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c105 = s:rect { x = 960, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c106 = s:rect { x = 1012, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_c107 = s:rect { x = 1064, y = 522, w = 46, h = 20, rx = 2, color = PANEL, opacity = 0 }
    N.hs_l = s:text { x = 180, y = 382, text = "108 frames  ·  one caption moved 0.3s later", size = 24, font = MONO, color = FAINT, opacity = 0 }
    N.hs_v = s:text { x = 180, y = 596, text = "9 differ   99 identical", size = 40, font = BOLD, color = TEAL, opacity = 0 }

    -- lift ----------------------------------------------------------------
    N.lf_n = s:text { x = 120, y = 112, text = "06", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.lf_t = s:text { x = 120, y = 150, text = "The comp describes itself", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.lf_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.lf_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.lf_p = s:rect { x = 180, y = 372, w = 600, h = 368, rx = 10, color = PANEL, opacity = 0 }
    N.lf_b = s:rect { x = 232, y = 432, w = 210, h = 116, rx = 6, color = BLUE, opacity = 0 }
    N.lf_d = s:circle { x = 636, y = 556, r = 58, color = TEAL, opacity = 0 }
    N.lf_type = s:text { x = 236, y = 596, text = "TYPE", size = 44, font = BOLD, color = INK, opacity = 0 }
    N.lf_a = s:rect { x = 820, y = 552, w = 110, h = 4, color = FAINT, opacity = 0 }
    N.lf_f0 = s:text { x = 976, y = 404, text = "entity(text6, \"text\").", size = 25, font = MONO, color = INK, opacity = 0 }
    N.lf_f1 = s:text { x = 976, y = 450, text = "holds(visible(text6), 0.000, 3.600).", size = 25, font = MONO, color = INK, opacity = 0 }
    N.lf_f2 = s:text { x = 976, y = 496, text = "holds(in_third(text6, left), 0.000, 3.600).", size = 25, font = MONO, color = INK, opacity = 0 }
    N.lf_f3 = s:text { x = 976, y = 542, text = "holds(text(text6, \"Hold the cut.\"), 0.567, 1.467).", size = 25, font = MONO, color = INK, opacity = 0 }
    N.lf_f4 = s:text { x = 976, y = 588, text = "happens(text_change(text6), 0.567).", size = 25, font = MONO, color = INK, opacity = 0 }
    N.lf_note = s:text { x = 976, y = 664, text = "no src line -- these are exact", size = 26, font = MONO, color = TEAL, opacity = 0 }

    -- perceive ------------------------------------------------------------
    N.pc_n = s:text { x = 120, y = 112, text = "07", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.pc_t = s:text { x = 120, y = 150, text = "The same grammar, from footage", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.pc_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.pc_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.pc_p = s:rect { x = 180, y = 372, w = 600, h = 368, rx = 10, color = PANEL, opacity = 0 }
    N.pc_f = s:rect { x = 212, y = 404, w = 536, h = 304, rx = 6, color = "#1d2735", opacity = 0 }
    N.pc_b0 = s:rect { x = 330, y = 452, w = 220, h = 3, color = AMBER, opacity = 0 }
    N.pc_b1 = s:rect { x = 330, y = 646, w = 220, h = 3, color = AMBER, opacity = 0 }
    N.pc_b2 = s:rect { x = 330, y = 452, w = 3, h = 197, color = AMBER, opacity = 0 }
    N.pc_b3 = s:rect { x = 547, y = 452, w = 3, h = 197, color = AMBER, opacity = 0 }
    N.pc_e = s:text { x = 330, y = 418, text = "e1", size = 24, font = MONO, color = AMBER, opacity = 0 }
    N.pc_f0 = s:text { x = 900, y = 404, text = "entity(e1, \"beer bottle\", seed(8.520)).", size = 25, font = MONO, color = INK, opacity = 0 }
    N.pc_s0 = s:text { x = 928, y = 444, text = "src(.., detector_agreement, 0.71).", size = 21, font = MONO, color = FAINT, opacity = 0 }
    N.pc_f1 = s:text { x = 900, y = 500, text = "holds(visible(e1), 2.100, 10.800).", size = 25, font = MONO, color = INK, opacity = 0 }
    N.pc_s1 = s:text { x = 928, y = 540, text = "src(.., sam2, 0.71).", size = 21, font = MONO, color = FAINT, opacity = 0 }
    N.pc_f2 = s:text { x = 900, y = 596, text = "happens(release(e1, e2), 8.500).", size = 25, font = MONO, color = INK, opacity = 0 }
    N.pc_s2 = s:text { x = 928, y = 636, text = "src(.., contact_gap, 1.00).", size = 21, font = MONO, color = FAINT, opacity = 0 }
    N.pc_note = s:text { x = 900, y = 700, text = "measured, so every line names its source", size = 26, font = MONO, color = AMBER, opacity = 0 }

    -- lower ---------------------------------------------------------------
    N.lw_n = s:text { x = 120, y = 112, text = "08", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.lw_t = s:text { x = 120, y = 150, text = "Editing by assertion", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.lw_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.lw_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.lw_a1 = s:rect { x = 958, y = 462, w = 4, h = 52, color = FAINT, opacity = 0 }
    N.lw_a2 = s:rect { x = 958, y = 596, w = 4, h = 52, color = FAINT, opacity = 0 }
    N.lw_k1 = s:text { x = 984, y = 472, text = "lower()", size = 22, font = MONO, color = FAINT, opacity = 0 }
    N.lw_k2 = s:text { x = 984, y = 606, text = "render + hash", size = 22, font = MONO, color = FAINT, opacity = 0 }
    N.lw_c0 = s:rect { x = 642, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c1 = s:rect { x = 660, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c2 = s:rect { x = 678, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c3 = s:rect { x = 696, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c4 = s:rect { x = 714, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c5 = s:rect { x = 732, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c6 = s:rect { x = 750, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c7 = s:rect { x = 768, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c8 = s:rect { x = 786, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c9 = s:rect { x = 804, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c10 = s:rect { x = 822, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c11 = s:rect { x = 840, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c12 = s:rect { x = 858, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c13 = s:rect { x = 876, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c14 = s:rect { x = 894, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c15 = s:rect { x = 912, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c16 = s:rect { x = 930, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c17 = s:rect { x = 948, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c18 = s:rect { x = 966, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c19 = s:rect { x = 984, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c20 = s:rect { x = 1002, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c21 = s:rect { x = 1020, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c22 = s:rect { x = 1038, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c23 = s:rect { x = 1056, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c24 = s:rect { x = 1074, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c25 = s:rect { x = 1092, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c26 = s:rect { x = 1110, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c27 = s:rect { x = 1128, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c28 = s:rect { x = 1146, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c29 = s:rect { x = 1164, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c30 = s:rect { x = 1182, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c31 = s:rect { x = 1200, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c32 = s:rect { x = 1218, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c33 = s:rect { x = 1236, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c34 = s:rect { x = 1254, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_c35 = s:rect { x = 1272, y = 684, w = 14, h = 34, rx = 2, color = PANEL, opacity = 0 }
    N.lw_v = s:text { x = 960, y = 760, text = "9 frames changed   99 untouched", size = 30, font = BOLD, color = TEAL, anchor = "center", opacity = 0 }
    s:captions { x = 960, y = 418, size = 30, font = MONO,   -- lw_r1
      color = INK, anchor = "center", cues = {
        { 126.150, 131.450, "holds(text(text6, \"Hold the cut.\"), 0.567, 1.467)." },
        { 131.450, 137.850, "holds(text(text6, \"Hold the cut.\"), 0.867, 1.467)." },
      } }
    s:captions { x = 960, y = 552, size = 30, font = MONO,   -- lw_r2
      color = AMBER, anchor = "center", cues = {
        { 126.150, 131.450, "{ 0.55, 1.45, \"Hold the cut.\" }" },
        { 131.450, 137.850, "{ 0.85, 1.45, \"Hold the cut.\" }" },
      } }

    -- why -----------------------------------------------------------------
    N.wy_n = s:text { x = 120, y = 112, text = "09", size = 24, font = MONO, color = TEAL, opacity = 0 }
    N.wy_t = s:text { x = 120, y = 150, text = "Why it is built this way", size = 50, font = BOLD, color = INK, opacity = 0 }
    N.wy_r = s:rect { x = 120, y = 228, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.wy_s = s:rect { x = 120, y = 227, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }
    N.wy_d = s:rect { x = 959, y = 372, w = 3, h = 340, color = PANEL, opacity = 0 }
    N.wy_h0 = s:text { x = 200, y = 392, text = "FROM PIXELS", size = 26, font = MONO, color = FAINT, opacity = 0 }
    N.wy_l00 = s:text { x = 200, y = 462, text = "describe the frame", size = 30, font = SANS, color = DIM, opacity = 0 }
    N.wy_l01 = s:text { x = 200, y = 516, text = "guess a timestamp", size = 30, font = SANS, color = DIM, opacity = 0 }
    N.wy_l02 = s:text { x = 200, y = 570, text = "hope it landed", size = 30, font = SANS, color = DIM, opacity = 0 }
    N.wy_m0 = s:text { x = 200, y = 648, text = "tIoU 0.00 - 0.11", size = 36, font = BOLD, color = AMBER, opacity = 0 }
    N.wy_h1 = s:text { x = 1030, y = 392, text = "FROM FACTS", size = 26, font = MONO, color = TEAL, opacity = 0 }
    N.wy_l10 = s:text { x = 1030, y = 462, text = "the node has an id", size = 30, font = SANS, color = INK, opacity = 0 }
    N.wy_l11 = s:text { x = 1030, y = 516, text = "the fact carries the time", size = 30, font = SANS, color = INK, opacity = 0 }
    N.wy_l12 = s:text { x = 1030, y = 570, text = "hashes prove the edit", size = 30, font = SANS, color = INK, opacity = 0 }
    N.wy_m1 = s:text { x = 1030, y = 648, text = "exact", size = 36, font = BOLD, color = TEAL, opacity = 0 }

    -- close ---------------------------------------------------------------
    N.cl_t = s:text { x = 960, y = 468, text = "Moonsplice", size = 128, font = BOLD, color = INK, anchor = "center", opacity = 0 }
    N.cl_s = s:text { x = 960, y = 576, text = "Programmatic video from Lua.", size = 36, font = SANS, color = DIM, anchor = "center", opacity = 0 }
    N.cl_r = s:rect { x = 770, y = 632, w = 380, h = 3, color = PANEL, opacity = 0 }
    N.cl_p = s:rect { x = 770, y = 631, w = 76, h = 5, rx = 2, color = TEAL, opacity = 0 }

    -- one timeline; every wait below is derived from the narration timings ---
    s:script(function(t)
      t:parallel(function()
        t:tween(N.rail, 160.350, { w = 1680 }, "linear")
      end, function()
        -- open: narration 0.60s .. 10.95s
        t:wait(0.250)
        fade(t, { N.op_t, N.op_s, N.op_c0, N.op_c1, N.op_c2, N.op_c3, N.op_c4, N.op_c5, N.op_c6, N.op_c7, N.op_c8, N.op_c9, N.op_c10, N.op_c11, N.op_c12, N.op_c13, N.op_c14, N.op_c15, N.op_c16, N.op_c17, N.op_c18, N.op_c19, N.op_c20, N.op_c21, N.op_c22, N.op_c23, N.op_p }, 0.5, 0.0346, 1)
        t:parallel(function()
          t:tween(N.op_p, 1.2, { x = 1620 }, "sineInOut")
          t:tween(N.op_p, 1.2, { x = 240 }, "sineInOut")
          t:tween(N.op_p, 1.2, { x = 1620 }, "sineInOut")
          t:tween(N.op_p, 1.2, { x = 240 }, "sineInOut")
          t:tween(N.op_p, 1.2, { x = 1620 }, "sineInOut")
          t:tween(N.op_p, 1.2, { x = 240 }, "sineInOut")
          t:tween(N.op_p, 1.2, { x = 1620 }, "sineInOut")
          t:wait(0.530)
        end, function()
          t:wait(8.930)
        end)
        fade(t, { N.op_t, N.op_s, N.op_c0, N.op_c1, N.op_c2, N.op_c3, N.op_c4, N.op_c5, N.op_c6, N.op_c7, N.op_c8, N.op_c9, N.op_c10, N.op_c11, N.op_c12, N.op_c13, N.op_c14, N.op_c15, N.op_c16, N.op_c17, N.op_c18, N.op_c19, N.op_c20, N.op_c21, N.op_c22, N.op_c23, N.op_p }, 0.32, 0.0192, 0)
        -- fn: narration 11.75s .. 26.50s
        t:wait(0.000)
        fade(t, { N.fn_n, N.fn_t, N.fn_r, N.fn_s, N.fn_pl, N.fn_ll, N.fn_ar, N.fn_ah, N.fn_pr, N.fn_lr, N.fn_d, N.fn_c }, 0.5, 0.0600, 1)
        t:parallel(function()
          t:tween(N.fn_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.fn_s, 1.2, { x = 424 }, "sineInOut")
          t:wait(0.595)
        end, function()
            t:wait(1.200)
            t:tween(N.fn_d, 6.4, { x = 1630 }, "linear")
          t:wait(6.195)
        end)
        fade(t, { N.fn_n, N.fn_t, N.fn_r, N.fn_s, N.fn_pl, N.fn_ll, N.fn_ar, N.fn_ah, N.fn_pr, N.fn_lr, N.fn_d, N.fn_c }, 0.32, 0.0250, 0)
        -- seek: narration 27.30s .. 39.30s
        t:wait(0.000)
        fade(t, { N.sk_n, N.sk_t, N.sk_r, N.sk_s, N.sk_c0, N.sk_c1, N.sk_c2, N.sk_c3, N.sk_c4, N.sk_c5, N.sk_c6, N.sk_c7, N.sk_c8, N.sk_c9, N.sk_c10, N.sk_c11, N.sk_c12, N.sk_c13, N.sk_c14, N.sk_c15, N.sk_c16, N.sk_c17, N.sk_c18, N.sk_c19, N.sk_c20, N.sk_c21, N.sk_c22, N.sk_c23, N.sk_c24, N.sk_c25, N.sk_c26, N.sk_c27, N.sk_c28, N.sk_c29, N.sk_c30, N.sk_c31, N.sk_c32, N.sk_c33, N.sk_c34, N.sk_c35, N.sk_p, N.sk_l }, 0.5, 0.0220, 1)
        t:parallel(function()
          t:tween(N.sk_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.sk_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.sk_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.sk_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.sk_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.sk_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.sk_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.sk_s, 1.2, { x = 120 }, "sineInOut")
          t:wait(0.980)
        end, function()
            t:wait(2.200)
            t:tween(N.sk_p, 0.14, { x = 696 }, "expoOut")
            t:wait(0.720)
            t:tween(N.sk_p, 0.14, { x = 1532 }, "expoOut")
            t:wait(0.720)
            t:tween(N.sk_p, 0.14, { x = 344 }, "expoOut")
            t:wait(0.720)
            t:tween(N.sk_p, 0.14, { x = 1136 }, "expoOut")
            t:wait(0.720)
            t:tween(N.sk_p, 0.14, { x = 564 }, "expoOut")
            t:wait(0.720)
            t:tween(N.sk_p, 0.14, { x = 1708 }, "expoOut")
            t:wait(0.720)
            t:tween(N.sk_p, 0.14, { x = 916 }, "expoOut")
            t:wait(0.720)
          t:wait(2.360)
        end)
        fade(t, { N.sk_n, N.sk_t, N.sk_r, N.sk_s, N.sk_c0, N.sk_c1, N.sk_c2, N.sk_c3, N.sk_c4, N.sk_c5, N.sk_c6, N.sk_c7, N.sk_c8, N.sk_c9, N.sk_c10, N.sk_c11, N.sk_c12, N.sk_c13, N.sk_c14, N.sk_c15, N.sk_c16, N.sk_c17, N.sk_c18, N.sk_c19, N.sk_c20, N.sk_c21, N.sk_c22, N.sk_c23, N.sk_c24, N.sk_c25, N.sk_c26, N.sk_c27, N.sk_c28, N.sk_c29, N.sk_c30, N.sk_c31, N.sk_c32, N.sk_c33, N.sk_c34, N.sk_c35, N.sk_p, N.sk_l }, 0.32, 0.0122, 0)
        -- declare: narration 40.10s .. 55.75s
        t:wait(0.000)
        fade(t, { N.dc_n, N.dc_t, N.dc_r, N.dc_s, N.dc_l0, N.dc_l1, N.dc_l2, N.dc_l3, N.dc_b, N.dc_d, N.dc_y, N.dc_c }, 0.5, 0.0600, 1)
        t:parallel(function()
          t:tween(N.dc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dc_s, 1.2, { x = 120 }, "sineInOut")
          t:wait(0.295)
        end, function()
            t:wait(2.400)
            t:tween(N.dc_b, 0.9, { x = 1060 }, "cubicInOut")
          t:wait(11.395)
        end)
        fade(t, { N.dc_n, N.dc_t, N.dc_r, N.dc_s, N.dc_l0, N.dc_l1, N.dc_l2, N.dc_l3, N.dc_b, N.dc_d, N.dc_y, N.dc_c }, 0.32, 0.0250, 0)
        -- det: narration 56.55s .. 70.35s
        t:wait(-0.000)
        fade(t, { N.dt_n, N.dt_t, N.dt_r, N.dt_s, N.dt_p0, N.dt_h0, N.dt_c0, N.dt_r0, N.dt_s0, N.dt_p1, N.dt_h1, N.dt_c1, N.dt_r1, N.dt_s1, N.dt_v, N.dt_l }, 0.5, 0.0600, 1)
        t:parallel(function()
          t:tween(N.dt_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.dt_s, 1.2, { x = 120 }, "sineInOut")
          t:wait(0.505)
        end, function()
          t:wait(12.505)
        end)
        fade(t, { N.dt_n, N.dt_t, N.dt_r, N.dt_s, N.dt_p0, N.dt_h0, N.dt_c0, N.dt_r0, N.dt_s0, N.dt_p1, N.dt_h1, N.dt_c1, N.dt_r1, N.dt_s1, N.dt_v, N.dt_l }, 0.32, 0.0250, 0)
        -- hash: narration 71.15s .. 84.95s
        t:wait(0.000)
        fade(t, { N.hs_n, N.hs_t, N.hs_r, N.hs_s, N.hs_c0, N.hs_c1, N.hs_c2, N.hs_c3, N.hs_c4, N.hs_c5, N.hs_c6, N.hs_c7, N.hs_c8, N.hs_c9, N.hs_c10, N.hs_c11, N.hs_c12, N.hs_c13, N.hs_c14, N.hs_c15, N.hs_c16, N.hs_c17, N.hs_c18, N.hs_c19, N.hs_c20, N.hs_c21, N.hs_c22, N.hs_c23, N.hs_c24, N.hs_c25, N.hs_c26, N.hs_c27, N.hs_c28, N.hs_c29, N.hs_c30, N.hs_c31, N.hs_c32, N.hs_c33, N.hs_c34, N.hs_c35, N.hs_c36, N.hs_c37, N.hs_c38, N.hs_c39, N.hs_c40, N.hs_c41, N.hs_c42, N.hs_c43, N.hs_c44, N.hs_c45, N.hs_c46, N.hs_c47, N.hs_c48, N.hs_c49, N.hs_c50, N.hs_c51, N.hs_c52, N.hs_c53, N.hs_c54, N.hs_c55, N.hs_c56, N.hs_c57, N.hs_c58, N.hs_c59, N.hs_c60, N.hs_c61, N.hs_c62, N.hs_c63, N.hs_c64, N.hs_c65, N.hs_c66, N.hs_c67, N.hs_c68, N.hs_c69, N.hs_c70, N.hs_c71, N.hs_c72, N.hs_c73, N.hs_c74, N.hs_c75, N.hs_c76, N.hs_c77, N.hs_c78, N.hs_c79, N.hs_c80, N.hs_c81, N.hs_c82, N.hs_c83, N.hs_c84, N.hs_c85, N.hs_c86, N.hs_c87, N.hs_c88, N.hs_c89, N.hs_c90, N.hs_c91, N.hs_c92, N.hs_c93, N.hs_c94, N.hs_c95, N.hs_c96, N.hs_c97, N.hs_c98, N.hs_c99, N.hs_c100, N.hs_c101, N.hs_c102, N.hs_c103, N.hs_c104, N.hs_c105, N.hs_c106, N.hs_c107, N.hs_l }, 0.5, 0.0080, 1)
        t:parallel(function()
          t:tween(N.hs_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.hs_s, 1.2, { x = 120 }, "sineInOut")
          t:wait(0.380)
        end, function()
            t:wait(4.200)
            t:parallel(function() t:tween(N.hs_c17, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c18, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c19, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c20, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c21, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c22, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c23, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c24, 0.55, { color = TEAL }, "sineOut") end, function() t:tween(N.hs_c25, 0.55, { color = TEAL }, "sineOut") end)
          fade(t, { N.hs_v }, 0.45, 0.04, 1)
          t:wait(7.180)
        end)
        fade(t, { N.hs_n, N.hs_t, N.hs_r, N.hs_s, N.hs_c0, N.hs_c1, N.hs_c2, N.hs_c3, N.hs_c4, N.hs_c5, N.hs_c6, N.hs_c7, N.hs_c8, N.hs_c9, N.hs_c10, N.hs_c11, N.hs_c12, N.hs_c13, N.hs_c14, N.hs_c15, N.hs_c16, N.hs_c17, N.hs_c18, N.hs_c19, N.hs_c20, N.hs_c21, N.hs_c22, N.hs_c23, N.hs_c24, N.hs_c25, N.hs_c26, N.hs_c27, N.hs_c28, N.hs_c29, N.hs_c30, N.hs_c31, N.hs_c32, N.hs_c33, N.hs_c34, N.hs_c35, N.hs_c36, N.hs_c37, N.hs_c38, N.hs_c39, N.hs_c40, N.hs_c41, N.hs_c42, N.hs_c43, N.hs_c44, N.hs_c45, N.hs_c46, N.hs_c47, N.hs_c48, N.hs_c49, N.hs_c50, N.hs_c51, N.hs_c52, N.hs_c53, N.hs_c54, N.hs_c55, N.hs_c56, N.hs_c57, N.hs_c58, N.hs_c59, N.hs_c60, N.hs_c61, N.hs_c62, N.hs_c63, N.hs_c64, N.hs_c65, N.hs_c66, N.hs_c67, N.hs_c68, N.hs_c69, N.hs_c70, N.hs_c71, N.hs_c72, N.hs_c73, N.hs_c74, N.hs_c75, N.hs_c76, N.hs_c77, N.hs_c78, N.hs_c79, N.hs_c80, N.hs_c81, N.hs_c82, N.hs_c83, N.hs_c84, N.hs_c85, N.hs_c86, N.hs_c87, N.hs_c88, N.hs_c89, N.hs_c90, N.hs_c91, N.hs_c92, N.hs_c93, N.hs_c94, N.hs_c95, N.hs_c96, N.hs_c97, N.hs_c98, N.hs_c99, N.hs_c100, N.hs_c101, N.hs_c102, N.hs_c103, N.hs_c104, N.hs_c105, N.hs_c106, N.hs_c107, N.hs_l, N.hs_v }, 0.32, 0.0044, 0)
        -- lift: narration 85.75s .. 102.15s
        t:wait(0.000)
        fade(t, { N.lf_n, N.lf_t, N.lf_r, N.lf_s, N.lf_p, N.lf_b, N.lf_d, N.lf_type, N.lf_a, N.lf_f0, N.lf_f1, N.lf_f2, N.lf_f3, N.lf_f4, N.lf_note }, 0.5, 0.0600, 1)
        t:parallel(function()
          t:tween(N.lf_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lf_s, 1.2, { x = 120 }, "sineInOut")
          t:wait(0.790)
        end, function()
          t:wait(15.190)
        end)
        fade(t, { N.lf_n, N.lf_t, N.lf_r, N.lf_s, N.lf_p, N.lf_b, N.lf_d, N.lf_type, N.lf_a, N.lf_f0, N.lf_f1, N.lf_f2, N.lf_f3, N.lf_f4, N.lf_note }, 0.32, 0.0250, 0)
        -- perceive: narration 102.95s .. 125.55s
        t:wait(0.000)
        fade(t, { N.pc_n, N.pc_t, N.pc_r, N.pc_s, N.pc_p, N.pc_f, N.pc_b0, N.pc_b1, N.pc_b2, N.pc_b3, N.pc_e, N.pc_f0, N.pc_s0, N.pc_f1, N.pc_s1, N.pc_f2, N.pc_s2, N.pc_note }, 0.5, 0.0529, 1)
        t:parallel(function()
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.pc_s, 1.2, { x = 424 }, "sineInOut")
          t:wait(0.855)
        end, function()
          t:wait(21.255)
        end)
        fade(t, { N.pc_n, N.pc_t, N.pc_r, N.pc_s, N.pc_p, N.pc_f, N.pc_b0, N.pc_b1, N.pc_b2, N.pc_b3, N.pc_e, N.pc_f0, N.pc_s0, N.pc_f1, N.pc_s1, N.pc_f2, N.pc_s2, N.pc_note }, 0.32, 0.0250, 0)
        -- lower: narration 126.35s .. 137.40s
        t:wait(0.000)
        fade(t, { N.lw_n, N.lw_t, N.lw_r, N.lw_s, N.lw_a1, N.lw_a2, N.lw_k1, N.lw_k2, N.lw_c0, N.lw_c1, N.lw_c2, N.lw_c3, N.lw_c4, N.lw_c5, N.lw_c6, N.lw_c7, N.lw_c8, N.lw_c9, N.lw_c10, N.lw_c11, N.lw_c12, N.lw_c13, N.lw_c14, N.lw_c15, N.lw_c16, N.lw_c17, N.lw_c18, N.lw_c19, N.lw_c20, N.lw_c21, N.lw_c22, N.lw_c23, N.lw_c24, N.lw_c25, N.lw_c26, N.lw_c27, N.lw_c28, N.lw_c29, N.lw_c30, N.lw_c31, N.lw_c32, N.lw_c33, N.lw_c34, N.lw_c35 }, 0.5, 0.0209, 1)
        t:parallel(function()
          t:tween(N.lw_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lw_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lw_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lw_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lw_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lw_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.lw_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.lw_s, 1.2, { x = 120 }, "sineInOut")
          t:wait(0.030)
        end, function()
            t:wait(5.500)
            t:parallel(function() t:tween(N.lw_c5, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c6, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c7, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c8, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c9, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c10, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c11, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c12, 0.45, { color = TEAL }, "sineOut") end, function() t:tween(N.lw_c13, 0.45, { color = TEAL }, "sineOut") end)
          fade(t, { N.lw_v }, 0.45, 0.04, 1)
          t:wait(3.230)
        end)
        fade(t, { N.lw_n, N.lw_t, N.lw_r, N.lw_s, N.lw_a1, N.lw_a2, N.lw_k1, N.lw_k2, N.lw_c0, N.lw_c1, N.lw_c2, N.lw_c3, N.lw_c4, N.lw_c5, N.lw_c6, N.lw_c7, N.lw_c8, N.lw_c9, N.lw_c10, N.lw_c11, N.lw_c12, N.lw_c13, N.lw_c14, N.lw_c15, N.lw_c16, N.lw_c17, N.lw_c18, N.lw_c19, N.lw_c20, N.lw_c21, N.lw_c22, N.lw_c23, N.lw_c24, N.lw_c25, N.lw_c26, N.lw_c27, N.lw_c28, N.lw_c29, N.lw_c30, N.lw_c31, N.lw_c32, N.lw_c33, N.lw_c34, N.lw_c35, N.lw_v }, 0.32, 0.0114, 0)
        -- why: narration 138.20s .. 154.95s
        t:wait(0.000)
        fade(t, { N.wy_n, N.wy_t, N.wy_r, N.wy_s, N.wy_d, N.wy_h0, N.wy_l00, N.wy_l01, N.wy_l02, N.wy_m0, N.wy_h1, N.wy_l10, N.wy_l11, N.wy_l12, N.wy_m1 }, 0.5, 0.0600, 1)
        t:parallel(function()
          t:tween(N.wy_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 120 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 424 }, "sineInOut")
          t:tween(N.wy_s, 1.2, { x = 120 }, "sineInOut")
          t:wait(1.140)
        end, function()
          t:wait(15.540)
        end)
        fade(t, { N.wy_n, N.wy_t, N.wy_r, N.wy_s, N.wy_d, N.wy_h0, N.wy_l00, N.wy_l01, N.wy_l02, N.wy_m0, N.wy_h1, N.wy_l10, N.wy_l11, N.wy_l12, N.wy_m1 }, 0.32, 0.0250, 0)
        -- close: narration 155.75s .. 159.05s
        t:wait(0.000)
        fade(t, { N.cl_t, N.cl_s, N.cl_r, N.cl_p }, 0.5, 0.0600, 1)
        t:parallel(function()
          t:tween(N.cl_p, 1.2, { x = 1150 }, "sineInOut")
          t:tween(N.cl_p, 1.2, { x = 770 }, "sineInOut")
          t:wait(0.625)
        end, function()
          t:wait(3.025)
        end)
        fade(t, { N.cl_t, N.cl_s, N.cl_r, N.cl_p }, 0.32, 0.0250, 0)
      end)
    end)
  end,
}
