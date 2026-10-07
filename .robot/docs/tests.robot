*** Settings ***
Documentation    moonsplice test plan
...
...    Ordered by phase. Every render-affecting change must pass the tier it touches.
...    Env note: dev machine had a disk crunch; keep ≥10GB free before render/model tests
...    (weights ~3GB, spike outputs small, decode corpus ~1GB).
Metadata    Source    cadence@56ddad1:tests/PLAN.md

*** Test Cases ***
P0 — spike gates (must pass before any framework code)
    [Documentation]    - [x] **S1 offscreen render**: PASS 2026-08-01 (LÖVE 11.5, 1px borderless window,
    ...    \ \ \ \ \ \ macOS; xvfb Linux path still untested).
    ...    - [x] **S2 ffmpeg pipe**: PASS — 90 frames raw RGBA → ffmpeg stdin → valid mp4
    ...    \ \ \ \ \ \ (ffprobe: h264, 1280x720, 30fps, 90 frames exact). `spikes/p0/`.
    ...    - [x] **S3 determinism**: PASS — run-twice, 90/90 identical frame md5s.
    ...    - [x] **S4 fixed-dt seek**: PASS — shuffled render order → identical hashes.
    ...    - [x] **S5 throughput**: PASS — **132 fps @720p render+encode = 4.4× realtime** on
    ...    \ \ \ \ \ \ M-series, LÖVE 11.5, sync readback, io.popen (unoptimized floor; hash-mode
    ...    \ \ \ \ \ \ 36fps shows Lua-side md5 is the bottleneck there, not render).
    ...    \ \ \ \ \ \ Note: install cask with quarantine strip (`xattr -dr com.apple.quarantine
    ...    \ \ \ \ \ \ /Applications/love.app`) or Gatekeeper eats the app.
    [Tags]    doc    source:cadence@56ddad1:tests/PLAN.md
    Skip    prose

P1 — core render ✅ gate green 2026-08-01 (tests/run_p1.sh, 7/7)
    [Documentation]    - [x] **Golden frames**: `tests/golden/hello.md5` per-frame md5 (same-machine exact;
    ...    \ \ \ \ \ \ SSIM cross-machine tier later).
    ...    - [x] **Determinism**: render-twice identical + out-of-order identical, every run.
    ...    - [x] **Guard rails verified failing**: duration overrun, os.time in comp, overlapping
    ...    \ \ \ \ \ \ tweens on same node.prop — all rejected at compile/load (`.robot/fixtures/`).
    ...    - [x] **Encode validity**: ffprobe counts exactly duration×fps frames.
    ...    - [x] **No-hang invariant**: `love.errorhandler` overridden → errors print to stderr
    ...    \ \ \ \ \ \ and exit 1 (default LÖVE error screen loops forever in a window).
    ...    \ \ \ \ \ \ `SDL_MAC_BACKGROUND_APP=1` on render/hash = no dock icon / focus steal.
    ...    - [ ] **Seek-grid sweep** (HF-style): sample timepoints, assert non-blank frames.
    ...    - [x] **Audio graph** (2026-08-01): `s:audio/tts/sfx` → filter_complex (atrim/volume/
    ...    \ \ \ \ \ \ afade/adelay/amix, clamp+pad to comp duration) → aac mux with `-c copy`.
    ...    \ \ \ \ \ \ Verified: stream durations exact, clip placement by volume-window probe
    ...    \ \ \ \ \ \ (Cadence's `examples/audio_test.lua`, not carried over). Media resolves in `post_scene` hook → scripts pace
    ...    \ \ \ \ \ \ to resolved TTS/clip durations. NOT yet covered: >32-input recursive merge,
    ...    \ \ \ \ \ \ volume envelopes from tweens, live ElevenLabs call (key absent on dev machine —
    ...    \ \ \ \ \ \ code path written, cache-keyed; needs `ELEVENLABS_API_KEY` to validate).
    ...
    ...    *Perf log (multi.lua = 1080×1920, 3 video nodes/2 active, full animation)*
    ...
    ...    | date | change | multi fps | vertical fps |
    ...    |------|--------|-----------|--------------|
    ...    | 08-01 | jpg-extraction v0 | — | 22 |
    ...    | 08-01 | FFI decode (RGBA sws) | 24.9 | 23.8 |
    ...    | 08-01 | +buffer reuse, skip-convert, frame-threading | 24.6 | 32.4 |
    ...    | 08-01 | YUV-native planes + GPU shader + prefetch worker | 24.6* | 30* |
    ...    | 08-01 | +FFI fwrite (kill getString) + x264 veryfast | 44.6 | 53.5 |
    ...    | 08-01 | +LÖVE 12 (Metal, async readback pipeline) | 44.8 | 60.8 |
    ...    | 08-01 | draft tier (VideoToolbox hw encode) | **69–76** | — |
    ...
    ...    *flat because encode pipe was the bottleneck masking the win — lesson: profile first.
    ...    Encode is now the wall at standard quality (x264 veryfast); draw = 4ms/frame.
    [Tags]    doc    source:cadence@56ddad1:tests/PLAN.md
    Skip    prose

P2 — moonsplice-decode
    [Documentation]    Corpus (checked into tests/corpus/ or fetched, ~1GB): open-GOP h264, h264 10-bit,
    ...    hevc, vp9, av1, prores4444, VFR clip, mp4 with edit list, B-frame-heavy, webm, mkv.
    ...
    ...    - [ ] **D1 exact seek**: for each corpus file, request frames {0, 1, N/2, N-1, random
    ...    \ \ \ \ \ \ 50} by index and by PTS → decoded-frame hash matches linear-decode reference.
    ...    - [ ] **D2 out-of-order = in-order**: shuffled requests produce identical hashes.
    ...    - [ ] **D3 hw = sw**: VideoToolbox/NVDEC decode YUV bit-compares to software decode
    ...    \ \ \ \ \ \ per codec (spec conformance verified in practice; 10-bit h264 expected sw).
    ...    - [ ] **D4 conversion pin**: YUV→RGB path output hash stable across runs; fixed-point
    ...    \ \ \ \ \ \ path bit-identical cross-machine (CI: mac + linux runner).
    ...    - [ ] **D5 index cache**: second open skips linear pass; corrupted index detected
    ...    \ \ \ \ \ \ and rebuilt.
    ...    - [ ] **D6 cache bounds**: global cap honored under 4 concurrent streams; no
    ...    \ \ \ \ \ \ "no frame found" class failures at minimum cache size.
    ...    - [ ] **D7 shm throughput**: sustained 4K60 (2GB/s) through ring buffer without
    ...    \ \ \ \ \ \ frame drops on dev machine.
    [Tags]    doc    source:cadence@56ddad1:tests/PLAN.md
    Skip    prose

P2.5 — verification tiers (.robot/docs/checks.robot) ✅ tiers 0-2 live 2026-08-01
    [Documentation]    - [x] `moonsplice lint` — static timeline analyzer (`core/moonsplice/lint.lua`), ~24 codes,
    ...    \ \ \ \ \ \ `--json`/`--strict`, `lint_allow` escape hatches; validated on example suite
    ...    \ \ \ \ \ \ (hello: 1 honest warn; kinetic_promo: 56→5 after lint-driven fixes).
    ...    - [x] `moonsplice check` — seek-grid pixel audits (`core/runtime/checkmode.lua`): render
    ...    \ \ \ \ \ \ errors, blank frames, frozen-confirm, measured contrast, determinism.
    ...    - [ ] threshold config file (`moonsplice.toml`); calibrate on a larger comp corpus.
    ...    - [ ] tier-2 golden/SSIM flags; finer sampling grid for small text.
    [Tags]    doc    source:cadence@56ddad1:tests/PLAN.md
    Skip    prose

P3 — perceptual (probe/check)
    [Documentation]    - [ ] **M1 model load**: MobileCLIP2-S2 + C-RADIOv3-B + X-CLIP-B + CLAP load and
    ...    \ \ \ \ \ \ embed on MPS/ANE; throughput logged (target: probe ≤ render wall-clock).
    ...    - [ ] **M2 assert.visible**: synthetic comp (known logo at known window) →
    ...    \ \ \ \ \ \ probability crosses threshold inside window, below outside.
    ...    - [ ] **M3 derived signals**: synthetic freeze/cut/black comps → detected at correct
    ...    \ \ \ \ \ \ timestamps (embedding-delta detectors).
    ...    - [ ] **M4 audio asserts**: TTS VO over music comp → CLAP margin detects VO window;
    ...    \ \ \ \ \ \ silence gap detected.
    ...    - [ ] **M5 calibration drift**: golden embedding sidecar per example comp; cosine
    ...    \ \ \ \ \ \ drift >ε vs pinned model version fails (catches silent model swaps).
    [Tags]    doc    source:cadence@56ddad1:tests/PLAN.md
    Skip    prose

P4 — resolve + ElevenLabs
    [Documentation]    - **R1**: content-hash cache — same script+voice = zero API calls on re-render.
    ...    - **R2**: TTS clip duration matches ffprobe within 1 frame; word timestamps
    ...    \ \ monotonic; `waitUntil('word:x')` fires within ±1 frame of timestamp.
    ...    - **R3**: render phase with network blackholed (no DNS) succeeds after resolve.
    [Tags]    doc    source:cadence@56ddad1:tests/PLAN.md
    Skip    prose

Continuous
    [Documentation]    - Render-twice byte-compare on every example comp, every CI run (cheapest, highest
    ...    \ \ value — catches determinism regressions immediately).
    ...    - love-host vs rust-host pixel parity (SSIM corpus, HF-style tiers) once rust host
    ...    \ \ exists.
    [Tags]    doc    source:cadence@56ddad1:tests/PLAN.md
    Skip    prose

