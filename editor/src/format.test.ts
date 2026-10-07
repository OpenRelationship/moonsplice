import { describe, expect, it } from "vitest";

import { clampHeight } from "./state";

import * as fmt from "./format";
import { names, offlineSaid, offlineWhy } from "./format";

describe("what the app says", () => {
  it("reads a duration the way a person would say it", () => {
    expect(fmt.seconds(0)).toBe("0s");
    expect(fmt.seconds(0.04)).toBe("40ms");
    expect(fmt.seconds(0.4)).toBe("0.4s");
    expect(fmt.seconds(1.5)).toBe("1.5s");
    expect(fmt.seconds(2)).toBe("2s");
    expect(fmt.seconds(59.9)).toBe("59.9s");
  });

  it("says minutes once there are minutes", () => {
    // "600s" is a number somebody has to do arithmetic on before it means anything, and it is
    // what the transport said the length of a ten minute edit was; the ruler counted "540s" for
    // nine minutes in. Nobody works in seconds at that scale.
    expect(fmt.seconds(60)).toBe("1:00");
    expect(fmt.seconds(75)).toBe("1:15");
    expect(fmt.seconds(125)).toBe("2:05");
    expect(fmt.seconds(600)).toBe("10:00");
    // A tenth when it needs one, and never finer.
    expect(fmt.seconds(90.5)).toBe("1:30.5");
    expect(fmt.seconds(545.5)).toBe("9:05.5");
    // And it carries rather than saying ":60".
    expect(fmt.seconds(599.96)).toBe("10:00");
    expect(fmt.seconds(-90)).toBe("-1:30");
  });

  it("keeps the playhead's figures from jittering", () => {
    expect(fmt.timecode(0)).toBe("0:00.0");
    expect(fmt.timecode(4.29)).toBe("0:04.2");
    expect(fmt.timecode(75)).toBe("1:15.0");
  });

  it("says a size, never a byte count", () => {
    expect(fmt.size(null)).toBeNull();
    expect(fmt.size(900)).toBe("900 bytes");
    expect(fmt.size(2048)).toBe("2.0 KB");
    expect(fmt.size(40 * 1024 * 1024)).toBe("40 MB");
  });

  it("turns a field name into what it does", () => {
    expect(fmt.property("x")).toBe("Across");
    expect(fmt.property("opacity")).toBe("Visibility");
    expect(fmt.property("effect_hue_rotate")).toBe("Hue");
    // No word of its own: still words, and never the `effect_` prefix a programmer typed.
    expect(fmt.property("effect_bloom")).toBe("Bloom");
    expect(fmt.property("truck_u")).toBe("Truck u");
  });

  it("never shows a curve's identifier", () => {
    expect(fmt.curve("expoOut")).toBe("Arriving");
    expect(fmt.curve(undefined)).toBe("Even");
    // An unknown one is still words rather than an identifier. The old fallback left the
    // first letter lower-case, which was an accident of the regex, not a decision.
    expect(fmt.curve("wobbleOut")).toBe("Wobble out");
  });

  it("names a kind of thing in one word", () => {
    expect(fmt.kind("text")).toBe("Words");
    expect(fmt.kind("rect")).toBe("Block");
    expect(fmt.kind("tts")).toBe("Voice");
    expect(fmt.kind("mystery")).toBe("Mystery");
  });

  it("calls a thing by its own words when it has any", () => {
    expect(fmt.nodeName({ kind: "text", label: "Hold the cut." })).toBe("Hold the cut.");
    expect(fmt.nodeName({ kind: "rect", label: null })).toBe("Block");
    expect(fmt.nodeName({ kind: "rect", label: "   " })).toBe("Block");
  });

  it("turns the outline's colour triple into a swatch", () => {
    expect(fmt.swatch([1, 0, 0])).toBe("#ff0000");
    expect(fmt.swatch([0, 0.5, 1])).toBe("#0080ff");
    expect(fmt.swatch(4)).toBeNull();
    expect(fmt.swatch(["a", "b", "c"])).toBeNull();
  });

  it("rounds a value rather than showing a receipt", () => {
    expect(fmt.value(12.3456)).toBe("12.35");
    expect(fmt.value(12)).toBe("12");
    expect(fmt.value(true)).toBe("yes");
    expect(fmt.value(null)).toBe("—");
  });

  it("summarises a batch of changes as a sentence", () => {
    expect(fmt.changes([])).toBe("nothing changed");
    expect(fmt.changes(["moved the title"])).toBe("moved the title");
    expect(fmt.changes(["moved the title", "a", "b"])).toBe("moved the title, and 2 more");
  });
});

describe("how tall the timeline may be", () => {
  it("never leaves the window with no room for a frame", () => {
    expect(clampHeight(100_000)).toBeLessThan(window.innerHeight);
  });

  it("never shrinks a lane to a sliver", () => {
    expect(clampHeight(0)).toBeGreaterThanOrEqual(132);
  });

  it("leaves a sensible height alone", () => {
    expect(clampHeight(228)).toBe(228);
  });
});

describe("naming the things in a composition", () => {
  it("leaves a thing with a name of its own alone", () => {
    const m = names([
      { id: "a", kind: "text", label: "EDITOR" },
      { id: "b", kind: "rect" },
    ]);
    expect(m.get("a")).toBe("EDITOR");
    expect(m.get("b")).toBe("Block");
  });

  it("numbers the ones that would otherwise share a name", () => {
    const m = names([
      { id: "a", kind: "rect" },
      { id: "b", kind: "rect" },
      { id: "c", kind: "text", label: "Title" },
    ]);
    expect(m.get("a")).toBe("Block 1");
    expect(m.get("b")).toBe("Block 2");
    expect(m.get("c")).toBe("Title");
  });

  it("numbers repeated labels too, because a name two things share is not a name", () => {
    const m = names([
      { id: "a", kind: "text", label: "Cut" },
      { id: "b", kind: "text", label: "Cut" },
    ]);
    expect([...m.values()]).toEqual(["Cut 1", "Cut 2"]);
  });
});

// What the app says about a thing whose file is not there.
//
// The whole point of the offline path is that the app can say what is wrong without showing a
// path, so what it says has to be a sentence a person could have said out loud -- not a word
// from the renderer, and not a count of nodes.
describe("what is not on the air", () => {
  it("says one thing by name", () => {
    expect(
      offlineSaid([{ kind: "video", label: "Beach Sunset", offline: "missing" }]),
    ).toBe("Beach Sunset is missing.");
  });

  it("counts them when several share a reason, because naming nine is not a sentence", () => {
    const nine = Array.from({ length: 9 }, (_, i) => ({
      kind: "audio",
      label: `Line ${i}`,
      offline: "missing",
    }));
    expect(offlineSaid(nine)).toBe("9 things are missing.");
  });

  it("stops trying to be specific when the reasons differ", () => {
    expect(
      offlineSaid([
        { kind: "video", label: "Clip", offline: "missing" },
        { kind: "tts", label: "Line", offline: "needs a key" },
      ]),
    ).toBe("2 things are not playing.");
  });

  it("says nothing at all when nothing is wrong", () => {
    expect(offlineSaid([{ kind: "rect", label: "Block" }])).toBeNull();
  });

  it("never shows a word the renderer invented", () => {
    // A renderer newer than this window is the case this guards: an unknown word reaching the
    // screen is the app speaking a language nobody wrote.
    expect(offlineWhy("some future reason")).toBe(offlineWhy("would not load"));
    expect(offlineWhy(undefined)).toBe(offlineWhy("would not load"));
  });
});
