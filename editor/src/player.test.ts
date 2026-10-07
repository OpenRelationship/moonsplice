import { afterEach, describe, expect, it, vi } from "vitest";

import {
  FRESH,
  pace,
  paint,
  pump,
  RATES,
  saidRate,
  scaleFor,
  SCALES,
  shuttle,
  sized,
  STAMP,
  warm,
  warmth,
} from "./player";

import { useStudio } from "./state";
import type { Tab } from "./state";

function open(fps: number, duration: number): Tab {
  return {
    variation: "v",
    composition: "c",
    title: "T",
    aspect: "16:9",
    meta: { width: 1280, height: 720, duration, fps },
    hash: "h",
    outline: { comp: { width: 1280, height: 720, duration, fps }, nodes: [], tracks: [] } as never,
    undo: 0,
    redo: 0,
    undoLabel: null,
    redoLabel: null,
  };
}

describe("the playhead", () => {
  it("lands on a frame, not between two", () => {
    useStudio.setState({ tabs: [open(30, 3.6)], active: "v" });
    // Wall-clock time from a 60 Hz loop, which is what playback hands it.
    useStudio.getState().seek(1.0483333);
    expect(useStudio.getState().playhead).toBeCloseTo(31 / 30, 9);
    useStudio.getState().seek(2.51);
    expect(useStudio.getState().playhead).toBeCloseTo(75 / 30, 9);
  });

  it("gives the same answer twice for two times in the same frame, which is what makes the cache work", () => {
    useStudio.setState({ tabs: [open(30, 3.6)], active: "v" });
    useStudio.getState().seek(1.0);
    const a = useStudio.getState().playhead;
    useStudio.getState().seek(1.0 + 1 / 90);
    const b = useStudio.getState().playhead;
    expect(Math.round(b * 1000)).toBe(Math.round(a * 1000));
  });

  it("stays inside the composition", () => {
    useStudio.setState({ tabs: [open(24, 2)], active: "v" });
    useStudio.getState().seek(-5);
    expect(useStudio.getState().playhead).toBe(0);
    useStudio.getState().seek(99);
    expect(useStudio.getState().playhead).toBe(2);
  });

  it("does not snap when the composition has no frame rate to snap to", () => {
    useStudio.setState({ tabs: [open(0, 5)], active: "v" });
    useStudio.getState().seek(1.234567);
    expect(useStudio.getState().playhead).toBeCloseTo(1.234567, 9);
  });
});

// ---------------------------------------------------------------- the frame, bytes to picture

/** A response the frame server would send: the size, then the pixels.
 *
 *  The size is on the front of the body rather than in a header, and that is the whole point --
 *  the headers were there and could not be read, because the page and the frames come from
 *  different schemes and script may only read what CORS safelists on a cross-origin response.
 *  So the test sends what the app really sends. */
function frame(w: number, h: number, fill = 7): Response {
  const bytes = new Uint8Array(STAMP + w * h * 4).fill(fill, STAMP);
  const stamp = new DataView(bytes.buffer, 0, STAMP);
  stamp.setUint32(0, w, true);
  stamp.setUint32(4, h, true);
  return new Response(bytes, {
    status: 200,
    headers: { "content-type": "application/octet-stream" },
  });
}

/** Somewhere to paint that remembers what it was given. */
function surface() {
  const painted: { w: number; h: number; first: number; length: number }[] = [];
  return {
    painted,
    put(pixels: Uint8ClampedArray<ArrayBuffer>, w: number, h: number) {
      painted.push({ w, h, first: pixels[0], length: pixels.length });
    },
  };
}

describe("a frame on its way to the picture", () => {
  it("reads the size out of the first eight bytes, little-endian", () => {
    // Written by `stamped` in src-tauri/src/lib.rs and read here, with nothing in between to
    // check that the two agree -- so both sides assert the layout against the same literal.
    // 1920 = 0x780, 1080 = 0x438.
    const bytes = new Uint8Array([0x80, 0x07, 0x00, 0x00, 0x38, 0x04, 0x00, 0x00]);
    const stamp = new DataView(bytes.buffer, 0, STAMP);
    expect(STAMP).toBe(8);
    expect(stamp.getUint32(0, true)).toBe(1920);
    expect(stamp.getUint32(4, true)).toBe(1080);
  });

  const real = globalThis.fetch;
  afterEach(() => {
    globalThis.fetch = real;
  });

  it("paints the pixels at the size the frame says it is", async () => {
    // Not the size that was asked for: the renderer keeps the composition's proportions inside
    // the box, so what comes back is what goes on the canvas.
    globalThis.fetch = vi.fn(async () => frame(96, 54)) as never;
    const s = surface();
    expect(await paint("cframe://localhost/v/h/500/128x128.raw", s)).toBe(true);
    expect(s.painted).toEqual([{ w: 96, h: 54, first: 7, length: 96 * 54 * 4 }]);
  });

  it("refuses a frame that is not whole rather than painting half of one", async () => {
    const s = surface();
    // A body shorter than the size it claims -- a cut-off frame.
    globalThis.fetch = vi.fn(async () => {
      const bytes = new Uint8Array(STAMP + 10);
      const stamp = new DataView(bytes.buffer, 0, STAMP);
      stamp.setUint32(0, 96, true);
      stamp.setUint32(4, 54, true);
      return new Response(bytes, { status: 200 });
    }) as never;
    expect(await paint("cframe://localhost/v/h/500/96x54.raw", s)).toBe(false);

    // A frame with nothing on the front of it at all: whatever that is, it is not a frame, and
    // painting a guess would be worse than keeping the last picture that was whole.
    globalThis.fetch = vi.fn(
      async () => new Response(new Uint8Array(96 * 54 * 4), { status: 200 }),
    ) as never;
    expect(await paint("cframe://localhost/v/h/500/96x54.raw", s)).toBe(false);

    // A composition that closed.
    globalThis.fetch = vi.fn(async () => new Response("gone", { status: 404 })) as never;
    expect(await paint("cframe://localhost/v/h/500/96x54.raw", s)).toBe(false);

    // A frame server that is not there at all.
    globalThis.fetch = vi.fn(async () => {
      throw new Error("no such scheme");
    }) as never;
    expect(await paint("cframe://localhost/v/h/500/96x54.raw", s)).toBe(false);

    expect(s.painted, "nothing half-painted ever reached the canvas").toEqual([]);
  });

  it("goes to the newest frame and counts the ones it passed", async () => {
    // The playhead moves while a frame is loading. What the pane must never do is paint its way
    // through the backlog: it goes straight to where the playhead is now, and says how many
    // frames it skipped to get there.
    const wanted = ["a", "b", "c", "c"];
    let i = 0;
    const seen: string[] = [];
    const drops: string[] = [];
    await pump(
      () => wanted[Math.min(i, wanted.length - 1)],
      () => true,
      async (url) => {
        seen.push(url);
        i += 2; // two frames went by while this one was being painted
        return true;
      },
      (url) => drops.push(url),
    );
    // b was never painted: nobody would have seen it. And the frame it passed is counted.
    expect(seen).toEqual(["a", "c"]);
    expect(drops).toEqual(["a"]);
  });

  it("stops when the composition it was painting is gone", async () => {
    const seen: string[] = [];
    let alive = true;
    await pump(
      () => "x",
      () => alive,
      async (url) => {
        seen.push(url);
        alive = false;
        return true;
      },
      () => {},
    );
    expect(seen).toEqual(["x"]);
  });

  it("asks for a warmed frame without carrying it back", async () => {
    const asked: string[] = [];
    globalThis.fetch = vi.fn(async (u: string) => {
      asked.push(u);
      return new Response(null, { status: 204 });
    }) as never;
    warm("cframe://localhost/v/h/900/96x54.raw");
    expect(asked).toEqual(["cframe://localhost/v/h/900/96x54.raw?warm=1"]);
  });
});

// Keeping up, which is a scheduling question and not a rendering one.
//
// The pump paints one frame at a time and asks for the newest wanted one afterwards, so a frame
// that costs ten times its budget does not queue -- it just means nine frames nobody saw. That
// is the right bargain and it is not enough on its own: at 300 ms a frame the picture chases the
// playhead for ever and never arrives. What fixes it is asking for less picture, which is what
// every editor in the world does and says so in a menu.
describe("how big to draw a moving picture", () => {
  const BUDGET = 1000 / 30; // 33.3 ms

  it("asks for everything when everything fits", () => {
    expect(scaleFor(10, BUDGET, 1)).toBe(1);
    expect(scaleFor(BUDGET, BUDGET, 1)).toBe(1);
  });

  it("asks for a quarter of the area when a frame costs four budgets", () => {
    // Cost goes with area, so half the width is a quarter of the work.
    expect(scaleFor(BUDGET * 4, BUDGET, 1)).toBe(0.5);
  });

  it("never asks for less than the smallest step, however slow it is", () => {
    expect(scaleFor(100_000, BUDGET, 1)).toBe(SCALES[SCALES.length - 1]);
  });

  it("reads its own scale, so it does not keep shrinking what is already small", () => {
    // A frame that costs a budget *at half size* is already the right size. The controller has
    // to know what it measured at, or it would halve again every frame until it hit the floor.
    expect(scaleFor(BUDGET, BUDGET, 0.5)).toBe(0.5);
  });

  it("gets smaller at once and bigger slowly", () => {
    // Down: one slow frame is enough, because falling behind is something a person sees.
    let p = pace(FRESH, BUDGET * 9, BUDGET);
    expect(p.scale).toBeLessThan(1);
    const small = p.scale;

    // Up: easy frames do not immediately restore it, or a busy passage would flicker between
    // two sizes -- which reads far worse than the smaller one.
    p = pace(p, 0.2, BUDGET);
    p = pace(p, 0.2, BUDGET);
    p = pace(p, 0.2, BUDGET);
    expect(p.scale).toBe(small);

    // And then one step, not all the way back, however easy the frames got.
    let steps = 0;
    while (p.scale === small && steps < 40) {
      p = pace(p, 0.2, BUDGET);
      steps += 1;
    }
    expect(SCALES.indexOf(p.scale)).toBe(SCALES.indexOf(small) - 1);
  });

  it("does not shrink itself over frames that were cheap because it shrank them", () => {
    // The trap. A slow frame drops the size; the next frame is fast *because* it is smaller,
    // and a controller that averages raw milliseconds reads that as "still too slow at the new
    // size" and goes down again, all the way to the floor. Every measurement is normalised to
    // what it would have cost full size, so this cannot happen.
    let p = pace(FRESH, BUDGET * 9, BUDGET);
    const small = p.scale;
    for (let i = 0; i < 3; i += 1) {
      // The same composition, drawn at the new size: nine budgets scaled by the area.
      p = pace(p, BUDGET * 9 * small * small, BUDGET);
      expect(p.scale).toBe(small);
    }
  });

  it("settles instead of oscillating", () => {
    // A composition that costs four budgets at full size. Played for a hundred frames, the
    // player should find one size and stay there -- the thing a naive "too slow? halve it"
    // controller never does.
    let p = FRESH;
    const seen: number[] = [];
    for (let i = 0; i < 100; i += 1) {
      const took = BUDGET * 4 * p.scale * p.scale; // cost goes with area
      p = pace(p, took, BUDGET);
      if (i > 40) seen.push(p.scale);
    }
    expect(new Set(seen).size).toBe(1);
    expect(seen[0]).toBe(0.5);
  });

  it("ignores a frame that cost nothing measurable", () => {
    expect(pace(FRESH, 0, BUDGET)).toEqual(FRESH);
    expect(pace(FRESH, 12, 0)).toEqual(FRESH);
  });
});

describe("how far ahead to warm", () => {
  const BUDGET = 1000 / 30;

  it("warms the lot while frames are cheap", () => {
    expect(warmth(4, BUDGET, 6)).toBe(6);
  });

  it("stops lending the renderer's time when frames are dear", () => {
    // Six frames nobody has reached yet is six frames of a single queue's time spent while the
    // frame somebody is looking at waits behind them.
    expect(warmth(BUDGET * 10, BUDGET, 6)).toBe(1);
    expect(warmth(BUDGET * 2, BUDGET, 6)).toBe(3);
  });

  it("asks for everything before it has measured anything", () => {
    expect(warmth(0, BUDGET, 6)).toBe(6);
  });
});

describe("the size actually asked for", () => {
  it("is even, so no scaler is handed its worst case", () => {
    for (const px of [1280, 1281, 999, 3]) {
      for (const s of SCALES) {
        expect(sized(px, s) % 2).toBe(0);
      }
    }
  });

  it("is never nothing, however small the pane gets", () => {
    expect(sized(1, 0.25)).toBeGreaterThan(0);
    expect(sized(0, 0.25)).toBeGreaterThan(0);
  });
});

describe("the shuttle", () => {
  it("playing faster and backwards is one ladder of speeds", () => {
    // L from full reverse slows the reverse, crosses over, and speeds up forwards. One key, one
    // direction, the whole range -- which is why it is a ladder with no zero in it.
    let rate = -8;
    const going: number[] = [];
    for (let i = 0; i < 7; i += 1) {
      rate = shuttle(rate, "l");
      going.push(rate);
    }
    expect(going).toEqual([-4, -2, -1, 1, 2, 4, 8]);

    const back: number[] = [];
    for (let i = 0; i < 7; i += 1) {
      rate = shuttle(rate, "j");
      back.push(rate);
    }
    expect(back).toEqual([4, 2, 1, -1, -2, -4, -8]);
  });

  it("stops at the ends rather than wrapping round", () => {
    expect(shuttle(8, "l")).toBe(8);
    expect(shuttle(-8, "j")).toBe(-8);
  });

  it("plays from a stop, in the direction the key means", () => {
    expect(shuttle(0, "l")).toBe(1);
    expect(shuttle(0, "j")).toBe(-1);
  });

  it("stops from anywhere at all", () => {
    for (const rate of [...RATES, 0, 3.5]) {
      expect(shuttle(rate, "k")).toBe(0);
    }
  });

  it("says the speed the way a person would", () => {
    // Nobody says "one times" about the speed a thing was shot at, so at that speed it says
    // nothing -- a transport that announces "1x" is a transport announcing that it is working.
    expect(saidRate(1)).toBe(null);
    expect(saidRate(2)).toBe("2x");
    expect(saidRate(-1)).toBe("backwards");
    expect(saidRate(-4)).toBe("4x backwards");
  });
});
