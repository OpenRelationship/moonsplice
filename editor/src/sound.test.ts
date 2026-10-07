import { describe, expect, it } from "vitest";

import { cue, level, samePlace, spanOf } from "./sound";
import type { AudioView } from "./types";

function sound(over: Partial<AudioView> = {}): AudioView {
  return {
    id: "vo1",
    kind: "tts",
    at: 2,
    duration: 4,
    media_start: 0,
    volume: 1,
    bus: false,
    label: "A line",
    ...over,
  };
}

describe("what should be sounding, and when", () => {
  const DUR = 20;

  it("says nothing about a clip the window has not reached", () => {
    expect(cue([sound()], DUR, 0, 1, true)).toEqual([]);
    expect(cue([sound()], DUR, 10, 1, true)).toEqual([]);
  });

  it("starts a clip at the right moment, from the top of its file", () => {
    const [c] = cue([sound({ media_start: 1.5 })], DUR, 1.5, 1, true);
    expect(c.node).toBe("vo1");
    expect(c.after).toBeCloseTo(0.5, 9); // half a second from now
    expect(c.from).toBeCloseTo(1.5, 9); // where in its own file
    expect(c.lasts).toBeCloseTo(0.5, 9); // what is left of this window
  });

  it("joins a clip that is already sounding part way through itself", () => {
    // Playback begins at 3.5, which is a second and a half into a clip that began at 2.
    const [c] = cue([sound({ media_start: 10 })], DUR, 3.5, 1, true);
    expect(c.after).toBe(0);
    expect(c.from).toBeCloseTo(11.5, 9);
    expect(c.lasts).toBeCloseTo(1, 9);
  });

  it("does not cue the same clip twice as the window slides", () => {
    const mix = [sound()];
    const first = cue(mix, DUR, 1.5, 1, true); // catches its start at 2
    expect(first.length).toBe(1);
    // The next window, sliding forward. The clip is still running and must not start again.
    const second = cue(mix, DUR, 2.5, 1, false);
    expect(second).toEqual([]);
    // But starting again from there -- a seek -- has to join it where it is.
    const seeked = cue(mix, DUR, 2.5, 1, true);
    expect(seeked.length).toBe(1);
    expect(seeked[0].after).toBe(0);
  });

  it("leaves out what the composition has already silenced", () => {
    expect(cue([sound({ volume: 0 })], DUR, 1.5, 1, true)).toEqual([]);
  });

  it("gives the soonest first, so a window that is cut short loses the far end", () => {
    const mix = [
      sound({ id: "c", at: 1.8 }),
      sound({ id: "a", at: 1.2 }),
      sound({ id: "b", at: 1.5 }),
    ];
    expect(cue(mix, DUR, 1, 1, true).map((c) => c.node)).toEqual(["a", "b", "c"]);
  });

  it("runs a clip only as far as the composition does", () => {
    // Four seconds of clip at eighteen seconds into a twenty second composition.
    const [c] = cue([sound({ at: 18 })], DUR, 18, 10, true);
    expect(c.lasts).toBeCloseTo(2, 9);
    expect(spanOf(sound({ at: 18 }), DUR)).toEqual([18, 20]);
    // And one with no length of its own runs to the end.
    expect(spanOf(sound({ at: 3, duration: undefined }), DUR)).toEqual([3, 20]);
  });
});

describe("how loud it is on the way in and out", () => {
  const a = sound({ volume: 0.8, fade_in: 1, fade_out: 2, duration: 10 });

  it("ramps up from nothing and down to it", () => {
    expect(level(a, 0, 10)).toBeCloseTo(0, 9);
    expect(level(a, 0.5, 10)).toBeCloseTo(0.4, 9);
    expect(level(a, 1, 10)).toBeCloseTo(0.8, 9);
    expect(level(a, 5, 10)).toBeCloseTo(0.8, 9);
    expect(level(a, 9, 10)).toBeCloseTo(0.4, 9);
    expect(level(a, 10, 10)).toBeCloseTo(0, 9);
  });

  it("starts part way up the ramp when playback joins mid-fade", () => {
    // The one thing "just play from here" gets audibly wrong: a clip joined half a second into
    // its own one-second fade has to begin at half, not at nothing and not at full.
    const [c] = cue([a], 20, 2.5, 1, true);
    expect(c.gain).toBeCloseTo(0.4, 9);
    expect(c.rampTo).toEqual([0.5, 0.8]); // half a second of ramp left, up to 0.8
  });

  it("says when to begin fading out, counted from this cue rather than from the clip", () => {
    const [c] = cue([a], 20, 2, 12, true);
    // The clip runs 2..12 with a two second fade out, so the ramp down starts eight seconds in.
    expect(c.rampDown).toEqual([8, 2]);
    // Joined at nine seconds in, the fade out is already under way and starts immediately.
    const [mid] = cue([a], 20, 11, 2, true);
    expect(mid.rampDown?.[0]).toBe(0);
    expect(mid.gain).toBeCloseTo(0.8 * 0.5, 9);
  });

  it("has no ramps at all when the composition asked for none", () => {
    const plain = sound({ fade_in: 0, fade_out: 0, duration: 4 });
    const [c] = cue([plain], 20, 2, 1, true);
    expect(c.rampTo).toBeNull();
    expect(c.rampDown).toBeNull();
    expect(c.gain).toBe(1);
  });
});

describe("a seek that is not a seek", () => {
  it("counts two times in one frame as the same place", () => {
    expect(samePlace(1.0, 1.0 + 1 / 90, 30)).toBe(true);
    expect(samePlace(1.0, 1.05, 30)).toBe(false);
    expect(samePlace(1.0, 1.0 + 1 / 90, 0)).toBe(true);
  });
});
