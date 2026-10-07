import { describe, expect, it } from "vitest";
import type { Outline } from "../types";
import {
  clampZoom,
  easeShape,
  fitZoom,
  fraction,
  lanes,
  ticks,
  timeAt,
  zoomStep,
  ZOOM_MAX,
  ZOOM_MIN,
} from "./lanes";
import { outline } from "./lanes.fixture";

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
