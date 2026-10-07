import { describe, expect, it } from "vitest";

import { frameUrl } from "./bridge";
import { lanes } from "./timeline/lanes";
import { timeAt } from "./timeline/lanes";
import { useStudio, type Tab } from "./state";
import type { Outline } from "./types";

// The two scenarios from `context/projects/studio/features/project-sync/` that are about what
// the UI holds and what it does, rather than about what the engine writes. The other seventeen
// are in `src-tauri/tests/spec.rs`; `bin/studio-spec` checks every scenario has one of these.

const outline = {
  comp: { width: 1280, height: 720, duration: 3.6, fps: 30 },
  nodes: [{ id: "rect2", kind: "rect", index: 1, label: null, props: { x: 80, w: 0 } }],
  tracks: [
    {
      node: "rect2",
      index: 1,
      prop: "w",
      segments: [{ kind: "tween", t0: 0.15, t1: 0.55, from: 0, to: 640, ease: "expoOut", manual: false }],
    },
  ],
} as unknown as Outline;

function tab(hash: string, o: Outline = outline): Tab {
  return {
    variation: "hero",
    composition: "hero",
    title: "Hero",
    aspect: "16:9",
    meta: { width: 1280, height: 720, duration: 3.6, fps: 30 },
    hash,
    outline: o,
    undo: 0,
    redo: 0,
    undoLabel: null,
    redoLabel: null,
  };
}

describe("project sync, in the UI", () => {
  it("no second copy exists", () => {
    useStudio.setState({ tabs: [tab("aaaa")], active: "hero", playhead: 0 });

    // What the UI holds about a composition is a hash and the outline the engine sent with it.
    // There is no field for its text, and no dirty flag -- if saving were a separate act the
    // two copies would already have diverged.
    const held = useStudio.getState().tabs[0];
    const keys = Object.keys(held).sort();
    expect(keys).toEqual(
      [
        "aspect",
        "composition",
        "hash",
        "meta",
        "outline",
        "redo",
        "redoLabel",
        "title",
        "undo",
        "undoLabel",
        "variation",
      ].sort(),
    );
    expect(keys).not.toContain("text");
    expect(keys).not.toContain("source");
    expect(keys).not.toContain("dirty");
    expect("dirty" in useStudio.getState()).toBe(false);

    // Everything the timeline draws is derived, by a pure function, from that outline. Given
    // the same outline it gives the same lanes; it keeps nothing of its own between calls.
    const once = lanes(held.outline);
    const twice = lanes(held.outline);
    expect(twice).toEqual(once);
    expect(once[0].bars[0].segment).toBe(held.outline.tracks[0].segments[0]);

    // And the only way the held outline changes is a new one arriving from Rust: `updateTab`
    // replaces it wholesale. There is no mutator for a node, a track or a value.
    const store = useStudio.getState() as unknown as Record<string, unknown>;
    const mutators = Object.keys(store).filter(
      (k) => typeof store[k] === "function" && /node|track|prop|segment|value/i.test(k),
    );
    expect(mutators).toEqual([]);
  });

  it("a change from the timeline reaches the preview", () => {
    useStudio.setState({ tabs: [tab("aaaa")], active: "hero", playhead: 0 });
    const base = "cframe://localhost/";

    // A drag ends at some time on the ruler. The preview asks for the frame at that time, and
    // the time is snapped to a frame so the request is one the cache can answer twice.
    const dropped = timeAt(0.5, 3.6, 30);
    useStudio.getState().seek(dropped);
    const at = useStudio.getState().playhead;
    expect(at).toBeCloseTo(Math.round(1.8 * 30) / 30, 9);

    const before = frameUrl(base, "hero", "aaaa", at, 960, 540);

    // The drag became an edit, so Rust sent a new hash. Every part of the key is in the URL, so
    // the preview re-seeks at the current time against the new source without being told to.
    useStudio.getState().updateTab("hero", { hash: "bbbb" });
    const after = frameUrl(
      base,
      "hero",
      useStudio.getState().tabs[0].hash,
      useStudio.getState().playhead,
      960,
      540,
    );

    expect(after).not.toBe(before);
    expect(after).toContain("/bbbb/");
    expect(after).toContain(`/${Math.round(at * 1000)}/`);
    expect(useStudio.getState().playhead).toBe(at);
  });
});
