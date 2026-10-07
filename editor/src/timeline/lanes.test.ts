import { describe, expect, it } from "vitest";
import type { Outline } from "../types";
import type { Lane } from "./lanes";
import { edges, gapAfter, isAudio, lanes, notes, restep, snap } from "./lanes";
import { outline } from "./lanes.fixture";

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
