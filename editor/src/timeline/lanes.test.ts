import { describe, expect, it } from "vitest";

import type { Outline } from "../types";
import type { Lane } from "./lanes";
import {
  clampZoom,
  easeShape,
  edges,
  fitZoom,
  fraction,
  gapAfter,
  isAudio,
  lanes,
  notes,
  restep,
  snap,
  ticks,
  timeAt,
  zoomStep,
  ZOOM_MAX,
  ZOOM_MIN,
} from "./lanes";

const outline: Outline = {
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

describe("the timeline, derived", () => {
  it("puts what is in front at the top, and sound underneath", () => {
    // A composition paints in build order, so the last thing built is nearest the front — and a
    // layer list reads front first, the same way the picture does. Sound is read differently and
    // every editor separates it, so it goes below.
    const l = lanes(outline);
    expect(l.map((x) => x.node.id)).toEqual(["shader5", "text3", "rect2", "text1", "tts4"]);
    expect(l.map((x) => x.group)).toEqual([
      "picture",
      "picture",
      "picture",
      "picture",
      "sound",
    ]);
  });

  it("indents what something else holds, and keeps it under it", () => {
    const held: Outline = {
      ...outline,
      nodes: [
        { id: "group1", kind: "group", index: 1 },
        { id: "rectA", kind: "rect", index: 2, parent: "group1" },
        { id: "rectB", kind: "rect", index: 3, parent: "group1" },
        { id: "loose", kind: "rect", index: 4 },
      ],
      tracks: [],
      cues: [],
      audio: [],
      cli_only: [],
    };
    const l = lanes(held);
    expect(l.map((x) => [x.node.id, x.depth])).toEqual([
      ["loose", 0],
      ["group1", 0],
      ["rectB", 1],
      ["rectA", 1],
    ]);
  });

  it("keeps movements and values-set-by-hand apart", () => {
    const l = lanes(outline);
    const rect = l.find((x) => x.node.id === "rect2")!;
    const text = l.find((x) => x.node.id === "text1")!;
    expect(rect.bars).toHaveLength(2);
    expect(rect.marks).toHaveLength(0);
    expect(text.marks).toHaveLength(1);
    expect(text.bars).toHaveLength(0);
    expect(text.marks[0].t).toBe(2);
  });

  it("draws a spoken line as a line, not as a value somebody pinned", () => {
    const text = lanes(outline).find((x) => x.node.id === "text3")!;
    expect(text.cues).toHaveLength(2);
    expect(text.marks).toHaveLength(0);
    expect(text.bars).toHaveLength(0);
  });

  it("numbers each movement on a property, which is what a retime names", () => {
    const rect = lanes(outline).find((x) => x.node.id === "rect2")!;
    expect(rect.bars.map((b) => b.occurrence)).toEqual([0, 1]);
    expect(rect.bars[1].t0).toBe(1);
  });

  it("takes the engine's word for when a thing is on screen", () => {
    // This is the whole point of the rewrite: a clip's width is the stretch of time a thing
    // exists for, and that stretch is measured rather than assumed. Two clips here, with a gap.
    const rect = lanes(outline).find((x) => x.node.id === "rect2")!;
    expect(rect.clips).toEqual([
      { t0: 0.15, t1: 1.6 },
      { t0: 2.2, t1: 4 },
    ]);
  });

  it("says nothing rather than something wrong when a thing is never on screen", () => {
    const never: Outline = {
      ...outline,
      nodes: [{ id: "rectX", kind: "rect", index: 1, onscreen: [] }],
      tracks: [],
      cues: [],
      audio: [],
      cli_only: [],
    };
    expect(lanes(never)[0].clips).toEqual([]);
  });

  it("gives a spoken lane the stretch its lines cover", () => {
    const said = lanes(outline).find((x) => x.node.id === "text3")!;
    expect(said.cues).toHaveLength(2);
    expect(said.clips).toEqual([{ t0: 0.55, t1: 2.45 }]);
  });

  it("gives a sound lane the stretch it plays for", () => {
    const sound = lanes(outline).find((x) => x.node.id === "tts4")!;
    expect(sound.audio?.bus).toBe("vo");
    expect(sound.group).toBe("sound");
    expect(sound.clips).toEqual([{ t0: 0.2, t1: 2.7 }]);
  });

  it("gives a property its own row, named in the words the app uses", () => {
    const rect = lanes(outline).find((x) => x.node.id === "rect2")!;
    expect(rect.rows.map((r) => [r.prop, r.name])).toEqual([["w", "Width"]]);
    expect(rect.rows[0].bars).toHaveLength(2);

    const text = lanes(outline).find((x) => x.node.id === "text1")!;
    expect(text.rows.map((r) => r.name)).toEqual(["Visibility"]);
    expect(text.rows[0].marks).toHaveLength(1);
  });

  it("gives a thing that never changes no rows to open", () => {
    const said = lanes(outline).find((x) => x.node.id === "text3")!;
    expect(said.rows).toEqual([]);
  });

  it("marks what the app cannot paint instead of drawing it wrong", () => {
    const shader = lanes(outline).find((x) => x.node.id === "shader5")!;
    expect(shader.unpaintable).toBe("a GLSL shader");
  });

  it("still runs against an engine that does not measure on screen yet", () => {
    const text = lanes(outline).find((x) => x.node.id === "text1")!;
    expect(text.node.onscreen).toBeUndefined();
    expect(text.clips).toEqual([{ t0: 0, t1: 4 }]);
  });

  it("survives an empty composition", () => {
    const bare = { ...outline, nodes: [], tracks: [], cues: [], audio: [], cli_only: [] };
    expect(lanes(bare)).toEqual([]);
  });

  it("places a time and reads one back, on a frame boundary", () => {
    expect(fraction(2, 4)).toBe(0.5);
    expect(fraction(-1, 4)).toBe(0);
    expect(fraction(9, 4)).toBe(1);
    expect(fraction(1, 0)).toBe(0);
    expect(timeAt(0.5, 4, 30)).toBeCloseTo(2, 5);
    // snapped: 1.234s of a 4s comp at 30fps lands on a frame
    expect(timeAt(0.3085, 4, 30) * 30).toBeCloseTo(Math.round(0.3085 * 4 * 30), 5);
  });

  it("puts ticks on numbers a person can count", () => {
    const t = ticks(4, 640);
    expect(t[0]).toBe(0);
    expect(t.every((x, i, a) => i === 0 || x > a[i - 1])).toBe(true);
    expect(t[t.length - 1]).toBeLessThanOrEqual(4);
    expect(ticks(0, 640)).toEqual([]);
    expect(ticks(4, 0)).toEqual([]);
  });

  it("samples a curve that starts at nothing and arrives at everything", () => {
    for (const ease of ["linear", "expoOut", "backOut", "elasticOut", "bounceOut", "nonsense"]) {
      const shape = easeShape(ease);
      expect(shape).toHaveLength(16);
      expect(shape[0]).toBeCloseTo(0, 2);
      expect(shape[15]).toBeCloseTo(1, 2);
    }
  });

  it("shows an overshooting curve going past its target, because it does", () => {
    expect(Math.max(...easeShape("backOut"))).toBeGreaterThan(1);
    expect(Math.max(...easeShape("linear"))).toBeCloseTo(1, 5);
  });

  it("fits the composition to the pane, and lets a person ask for more detail", () => {
    // A timeline that only ever fits is unreadable on a long composition: at a minute wide, a
    // quarter-second movement is two pixels.
    expect(fitZoom(4, 800)).toBe(200);
    expect(fitZoom(0, 800)).toBe(100);
    expect(fitZoom(4, 0)).toBe(100);
    expect(clampZoom(1e9)).toBe(ZOOM_MAX);
    expect(clampZoom(0)).toBe(ZOOM_MIN);
    expect(clampZoom(Number.NaN)).toBe(100);
  });

  it("zooms around the time under the pointer, so it stays under the pointer", () => {
    const anchor = 2;
    const anchorPx = 300;
    const inward = zoomStep(200, 1, anchor, anchorPx);
    expect(inward.pps).toBeGreaterThan(200);
    // The anchor still lands on the same pixel: scroll + px == time * scale.
    expect(inward.scroll + anchorPx).toBeCloseTo(anchor * inward.pps, 5);

    const outward = zoomStep(200, -1, anchor, anchorPx);
    expect(outward.pps).toBeLessThan(200);
    expect(outward.scroll).toBeGreaterThanOrEqual(0);
  });
});

describe("moving a thing up and down the stack", () => {
  const all = lanes(outline);

  it("names the thing it has to paint over to take one step forward", () => {
    // Front first: shader5, text3, rect2, text1. (tts4 is sound and is not in the stack.)
    const front = all.filter((l) => l.group === "picture").map((l) => l.node.id);
    expect(front).toEqual(["shader5", "text3", "rect2", "text1"]);

    // rect2 forward once sits in front of text3, which is what it now paints over.
    expect(restep(all, "rect2", "forward")).toEqual({ node: "rect2", over: "text3" });
    // And the one already at the front has nowhere to go.
    expect(restep(all, "shader5", "forward")).toBeNull();
  });

  it("names it going the other way too, and the very back is nothing at all", () => {
    // rect2 back once puts text1 in front of it, so rect2 now paints over nothing below text1 —
    // which is nothing, because text1 is the last.
    expect(restep(all, "rect2", "back")).toEqual({ node: "rect2", over: null });
    // text3 back once lands between rect2 and text1.
    expect(restep(all, "text3", "back")).toEqual({ node: "text3", over: "text1" });
    // And the one already at the back stays there.
    expect(restep(all, "text1", "back")).toBeNull();
  });

  it("leaves sound out of it, because a mix has no front", () => {
    expect(restep(all, "tts4", "forward")).toBeNull();
    expect(restep(all, "tts4", "back")).toBeNull();
    expect(restep(all, "nothing-like-this", "forward")).toBeNull();
  });

  it("moves a thing inside a group within that group and never out of it", () => {
    const held: Outline = {
      ...outline,
      nodes: [
        { id: "group1", kind: "group", index: 1, label: null, props: {} },
        { id: "a2", kind: "rect", index: 2, label: null, parent: "group1", props: { x: 0 } },
        { id: "b3", kind: "rect", index: 3, label: null, parent: "group1", props: { x: 0 } },
        { id: "c4", kind: "rect", index: 4, label: null, props: { x: 0 } },
      ],
      tracks: [],
      cues: [],
      audio: [],
      cli_only: [],
    };
    const inside = lanes(held);
    // Inside the group, b3 is in front of a2; a2 forward paints over b3.
    expect(restep(inside, "a2", "forward")).toEqual({ node: "a2", over: "b3" });
    // a2 is already the back one of the two, and "the very back" would be out of the group.
    expect(restep(inside, "a2", "back")).toBeNull();
  });
});

describe("a clip let go of near something", () => {
  const all = lanes(outline);

  it("catches on the playhead, the ends, and other clips", () => {
    const targets = edges(all, "rect2", 4, 1.23);
    // Its own edges are not in there: a clip cannot snap to where it already is.
    expect(targets).not.toContain(0.15);
    expect(targets).not.toContain(1.6);
    // The composition's two ends, the playhead, and the narration's start are.
    expect(targets).toContain(0);
    expect(targets).toContain(4);
    expect(targets).toContain(1.23);
    expect(targets).toContain(0.2);
    // Sorted, and each one only once.
    expect(targets).toEqual([...targets].sort((a, b) => a - b));
    expect(new Set(targets).size).toBe(targets.length);
  });

  it("snaps by what a person can see, not by seconds", () => {
    const targets = [0, 1.0, 4];
    // Zoomed out, a tenth of a second is under three pixels: it catches.
    expect(snap(1.06, targets, 28)).toBe(1.0);
    // Zoomed right in, the same tenth is sixty pixels away: it does not.
    expect(snap(1.06, targets, 600)).toBe(1.06);
    // Between two, it takes the nearer.
    expect(snap(0.2, [0, 0.25], 100)).toBe(0.25);
    // And with nothing near it, it stays where it was let go of.
    expect(snap(2.5, targets, 100)).toBe(2.5);
  });
});

describe("the hole after a clip", () => {
  const lane = (id: string, kind: string, t0: number, t1: number): Lane =>
    ({
      node: { id, kind, index: 1, label: null, props: {} },
      name: id,
      group: isAudio(kind) ? "sound" : "picture",
      depth: 0,
      clips: [{ t0, t1 }],
      rows: [],
      bars: [],
      marks: [],
      cues: [],
    }) as unknown as Lane;

  it("finds the stretch before the next thing of its own kind", () => {
    const all = [lane("a", "video", 0, 2), lane("b", "video", 3, 5)];
    expect(gapAfter(all, "a", 10)).toEqual({ t0: 2, t1: 3 });
  });

  it("does not count a picture as what follows a sound", () => {
    // A hole in the narration is the stretch before the next thing you would hear. The clip
    // sitting above it has nothing to do with it, and closing it would not move the clip.
    const all = [lane("shot", "video", 2, 4), lane("line", "tts", 0, 1)];
    expect(gapAfter(all, "line", 10)).toBe(null);
    expect(gapAfter(all, "shot", 10)).toBe(null);
  });

  it("says nothing when the clips touch, or when it is the last one", () => {
    expect(gapAfter([lane("a", "video", 0, 2), lane("b", "video", 2, 4)], "a", 10)).toBe(null);
    expect(gapAfter([lane("a", "video", 0, 2), lane("b", "video", 3, 5)], "b", 10)).toBe(null);
  });

  it("ignores a hole too small to be one", () => {
    const all = [lane("a", "video", 0, 2), lane("b", "video", 2.03, 4)];
    expect(gapAfter(all, "a", 10)).toBe(null);
  });
});

describe("notes on the ruler", () => {
  const withNotes: Outline = {
    ...outline,
    nodes: [
      ...(outline.nodes ?? []),
      { id: "marker9", kind: "marker", index: 9, label: null, props: { at: 3, text: "late" } },
      { id: "marker8", kind: "marker", index: 8, label: null, props: { at: 1.25, text: "early" } },
    ],
  };

  it("reads them in the order they happen", () => {
    expect(notes(withNotes).map((n) => n.text)).toEqual(["early", "late"]);
    expect(notes(withNotes)[0].at).toBe(1.25);
  });

  it("keeps them out of the lanes", () => {
    // A lane is a thing that is on screen for a stretch of time. A note is neither on screen nor
    // a stretch, and given a lane it would draw an empty row saying "never on screen" -- true,
    // and useless.
    const rows = lanes(withNotes).map((l) => l.node.id);
    expect(rows).not.toContain("marker8");
    expect(rows).not.toContain("marker9");
    expect(rows.length).toBe(lanes(outline).length);
  });

  it("says nothing about a composition with no notes in it", () => {
    expect(notes(outline)).toEqual([]);
  });
});

describe("a thing whose file is not there", () => {
  it("keeps its lane, its stretch and its movements", () => {
    const out = {
      comp: { width: 320, height: 180, duration: 10, fps: 30, background: [0, 0, 0], direct: true },
      nodes: [
        {
          id: "v1",
          kind: "video",
          index: 1,
          label: "Beach",
          offline: "missing",
          onscreen: [{ t0: 2, t1: 8 }],
        },
        { id: "r1", kind: "rect", index: 2, label: "Block", onscreen: [{ t0: 0, t1: 10 }] },
      ],
      tracks: [
        {
          node: "v1",
          index: 1,
          prop: "opacity",
          segments: [{ kind: "tween" as const, t0: 2, t1: 3, manual: false, from: 0, to: 1 }],
        },
      ],
      cues: [],
      audio: [],
      cli_only: [],
    };
    // Found by name, not by position: lanes come back front first, which is build order
    // reversed.
    const all = lanes(out);
    const beach = all.find((l) => l.node.id === "v1")!;
    const block = all.find((l) => l.node.id === "r1")!;
    expect(beach.offline).toBe("missing");
    expect(beach.clips).toEqual([{ t0: 2, t1: 8 }]);
    expect(beach.bars).toHaveLength(1);
    // The one that is fine says nothing, so "offline" reads as a fact about that lane rather
    // than a field every lane carries.
    expect(block.offline).toBeUndefined();
  });
});
