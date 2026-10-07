import type { Outline } from "../types";

export const outline: Outline = {
  comp: {
    width: 1280,
    height: 720,
    duration: 4,
    fps: 30,
    background: [0, 0, 0],
    direct: true,
    title: "Hero",
  },
  nodes: [
    { id: "text1", kind: "text", index: 1, label: "35  CAPTIONS", props: { x: 48, y: 36 } },
    {
      id: "rect2",
      kind: "rect",
      index: 2,
      label: null,
      props: { x: 80, y: 528, w: 0 },
      // Measured by the engine: on, off for a beat, on again.
      onscreen: [
        { t0: 0.15, t1: 1.6 },
        { t0: 2.2, t1: 4 },
      ],
    },
    { id: "text3", kind: "text", index: 3, label: "Hold the cut." },
    { id: "tts4", kind: "tts", index: 4, label: "Narration" },
    { id: "shader5", kind: "shader", index: 5, label: null },
  ],
  tracks: [
    {
      node: "rect2",
      index: 2,
      prop: "w",
      segments: [
        { kind: "tween", t0: 0.15, t1: 0.55, from: 0, to: 640, ease: "expoOut", manual: false },
        { kind: "tween", t0: 1.0, t1: 1.4, from: 640, to: 320, ease: "sineOut", manual: false },
      ],
    },
    {
      node: "text1",
      index: 1,
      prop: "opacity",
      segments: [{ kind: "pin", t0: 2, t1: 2, to: 0, manual: true }],
    },
    {
      // What a caption's own lines look like in the timeline model: steps on `text`, which the
      // engine tags `cue` precisely so the lane does not mistake them for hand-pinned values.
      node: "text3",
      index: 3,
      prop: "text",
      segments: [
        { kind: "cue", t0: 0.55, t1: 0.55, to: "Hold the cut.", manual: false },
        { kind: "cue", t0: 1.45, t1: 1.45, to: "Let the type land.", manual: false },
      ],
    },
  ],
  cues: [
    { node: "text3", index: 0, t0: 0.55, t1: 1.45, text: "Hold the cut." },
    { node: "text3", index: 1, t0: 1.45, t1: 2.45, text: "Let the type land." },
  ],
  audio: [
    { id: "tts4", kind: "tts", at: 0.2, duration: 2.5, volume: 1, bus: "vo", label: "Narration" },
  ],
  cli_only: [{ node: "shader5", kind: "shader", why: "a GLSL shader" }],
};
