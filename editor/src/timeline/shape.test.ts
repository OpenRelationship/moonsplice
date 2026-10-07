import { describe, expect, it } from "vitest";

import { BOX, coarser, wavePath, windowed } from "./shape";

describe("a sound drawn as a shape", () => {
  it("draws loud wide and quiet narrow, about the middle", () => {
    const path = wavePath([255, 0, 255]);
    // Three points along the top and three back along the bottom, closed.
    expect(path.startsWith("M")).toBe(true);
    expect(path.endsWith("Z")).toBe(true);
    const ys = [...path.matchAll(/[ML](?:[\d.]+) ([\d.]+)/g)].map((m) => Number(m[1]));
    expect(ys.length).toBe(6);
    // The loud ones reach for the edges; the quiet one sits on the middle.
    expect(Math.min(...ys)).toBeLessThan(4);
    expect(Math.max(...ys)).toBeGreaterThan(BOX.h - 4);
    expect(ys[1]).toBeCloseTo(BOX.h / 2 - 1, 5);
  });

  it("still draws a line for a sound that is silent", () => {
    // Silence is a sound that is there. A bar with nothing drawn in it reads as one that failed.
    const path = wavePath([0, 0, 0, 0]);
    expect(path).not.toBe("");
    const ys = [...path.matchAll(/[ML](?:[\d.]+) ([\d.]+)/g)].map((m) => Number(m[1]));
    expect(Math.max(...ys) - Math.min(...ys)).toBeCloseTo(2, 5);
  });

  it("says nothing when it knows nothing", () => {
    expect(wavePath([])).toBe("");
  });

  it("takes the loudest when it has to draw fewer points, never the average", () => {
    // One spike in a quiet passage is the thing a person is looking for; an average erases it.
    const peaks = [4, 4, 250, 4, 4, 4, 4, 4];
    expect(coarser(peaks, 2)).toEqual([250, 4]);
    expect(coarser(peaks, 8)).toEqual(peaks);
    expect(coarser(peaks, 99)).toEqual(peaks);
    expect(coarser(peaks, 0)).toEqual(peaks);
  });

  it("draws the part of the file the clip actually plays", () => {
    const peaks = Array.from({ length: 100 }, (_, i) => i);
    // A four second file, played from one second for two.
    const part = windowed(peaks, 1, 2, 4);
    expect(part.length).toBe(50);
    expect(part[0]).toBe(25);
    expect(part[part.length - 1]).toBe(74);

    // The whole of it is the whole of it.
    expect(windowed(peaks, 0, 4, 4)).toEqual(peaks);
    // And with no idea how long the file is, there is nothing to slice against.
    expect(windowed(peaks, 1, 2, undefined)).toEqual(peaks);
    expect(windowed([], 1, 2, 4)).toEqual([]);
  });
});
