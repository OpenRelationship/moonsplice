*** Settings ***
Documentation    The fact log — one grammar for what a comp is and what a clip shows (continued)

*** Test Cases ***
Layout
    [Documentation]    ```
    ...    vision/moonsplice_vision/
    ...    \ \ facts.py \ \ \ \ \ \ \ grammar, comp lifter, agreed_runs (derived confidence)
    ...    \ \ lower.py \ \ \ \ \ \ \ fact-log edits back into Lua source
    ...    \ \ perceive.py \ \ \ \ orchestrates producers into a log for a clip
    ...    \ \ tracking.py \ \ \ \ full recognition (tags grounded by YOLO-World) or prompts; EdgeTAM/SAM 2 propagation
    ...    \ \ tags.py \ \ \ \ \ \ \ \ RAM++ keyframe tags, shimmed for transformers 5
    ...    \ \ clips.py \ \ \ \ \ \ \ a perceived video cut into clips, each with media and its own fact log
    ...    \ \ fetch.py \ \ \ \ \ \ \ URLs (pages via yt-dlp, signed CDN links) into a keyed media store
    ...    \ \ devices.py \ \ \ \ \ cuda, then mps, then cpu (MOONSPLICE_DEVICE overrides)
    ...    \ \ camerafacts.py \ still/pan/tilt/dolly/zoom/handheld, DA3 intrinsics separate dolly from zoom
    ...    \ \ audiofacts.py \ \ words, beats, loudness, forced alignment, sound-source correlation
    ...    \ \ diarize.py \ \ \ \ \ speaker turns from clustered ECAPA embeddings, named after entities
    ...    \ \ ocr.py \ \ \ \ \ \ \ \ \ on-screen text as a fluent, boundaries bisected
    ...    \ \ landmarks.py \ \ \ posture and facing from pose keypoints; hands where the library works
    ...    \ \ identity.py \ \ \ \ the same subject after a cut, calibrated against same-frame pairs
    ...    \ \ boundaries.py \ \ where the action turns over inside a shot
    ...    \ \ clipeval.py \ \ \ \ the real-pixels/exact-truth harness
    ...    \ \ vendor/ \ \ \ \ \ \ \ \ pinned Apache-2.0 MediaPipe ONNX wrappers (OpenCV Zoo)
    ...    ```
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

Research log
    [Documentation]    Benchmarks: VEBench (temporal IoU 0.00–0.11 for edit localization), AgenticVBench (best agent 31%
    ...    vs humans 81–95%), CameraBench (camera-motion taxonomy). Models used: Depth Anything 3 small
    ...    (Apache, depth + per-frame intrinsics), SAM 2.1 small (propagation), YOLO-World v2 (open-vocabulary
    ...    seeds), YOLO11n-pose (COCO-17), RapidOCR (PaddleOCR models on onnxruntime, no torch), torchaudio
    ...    MMS forced alignment, faster-whisper (what was said, never when), librosa (beats, loudness),
    ...    SpeechBrain ECAPA-TDNN (speaker embeddings for diarization), MediaPipe palm detection and hand
    ...    landmarks as ONNX (OpenCV Zoo), which is how hands work on a Mac at all.
    ...
    ...    Cross-shot identity is Foote-style in spirit and CLIP-based in fact; the boundary detector is
    ...    Foote's novelty score over a self-similarity matrix with CLIP embeddings in place of audio features.
    ...
    ...    Candidates considered and not adopted: SAM 3 and Grounding DINO 1.5 for seeding (swap in when
    ...    available), pyannote for diarization (gated; ECAPA clustering stands in, and would be replaced by
    ...    it for overlap-aware segmentation if the gate were ever opened), InsightFace + OSNet + DINOv3 as
    ...    stronger opinions on identity
    ...    than appearance alone, L2CS-Net for gaze, Kinetics-GEBD / V-JEPA-class predictive features for
    ...    event boundaries. Each would slot in as another producer behind the same fact, which is the point
    ...    of writing the interface as a grammar rather than as an API.
    [Tags]    doc    source:cadence@56ddad1:docs/FACTS.md
    Skip    prose

