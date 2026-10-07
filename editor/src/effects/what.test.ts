import { describe, expect, it } from "vitest";

import * as fmt from "../format";
import { DOES, EFFECTS, effectsOn, matching, sections } from "./what";

describe("the effects panel", () => {
  it("the effects panel follows what is selected", () => {
    // A block has a place, a size and a look; it has no tracking, because it is not type.
    const block = { x: 100, y: 50, w: 400, h: 200, opacity: 1, color: [1, 1, 1] };
    expect(sections(block).map((s) => s.title)).toEqual(["Place", "Size", "Look"]);
    expect(sections(block).find((s) => s.title === "Size")?.keys).toEqual(["w", "h"]);

    // A thing with only a position has only the one section, not three with two empty.
    expect(sections({ x: 0, y: 0 }).map((s) => s.title)).toEqual(["Place"]);

    // Nothing selected is nothing to show.
    expect(sections(null)).toEqual([]);
    expect(effectsOn(null)).toEqual({ keys: [], busy: 0 });
  });

  it("says how many effects are doing something", () => {
    // Resting values are not news: a saturation of 1 and a blur of 0 change nothing.
    const resting = { effect_blur: 0, effect_saturate: 1, effect_opacity: 1 };
    expect(effectsOn(resting)).toEqual({
      keys: ["effect_blur", "effect_saturate", "effect_opacity"],
      busy: 0,
    });
    const working = { effect_blur: 6, effect_saturate: 1, effect_opacity: 0.4 };
    expect(effectsOn(working).busy).toBe(2);
  });

  it("with nothing selected every effect is listed collapsed", () => {
    // The whole catalogue, and every entry explains itself, because there is nothing on screen
    // to show it on.
    expect(matching("")).toEqual(EFFECTS);
    for (const k of EFFECTS) expect(DOES[k], `${k} says what it does`).toBeTruthy();

    // Searching is over the words a person reads.
    expect(matching("black")).toEqual(["effect_grayscale"]);
    expect(matching("fade")).toEqual(["effect_opacity"]);
    // A search reads the sentences too, so "colour" finds the four that are about colour.
    expect(matching("colour")).toEqual([
      "effect_saturate",
      "effect_hue_rotate",
      "effect_grayscale",
      "effect_invert",
    ]);
    expect(matching("zzz")).toEqual([]);

    // And never over the keys underneath them, which a person never sees.
    expect(matching("effect_")).toEqual([]);
    for (const k of EFFECTS) expect(fmt.property(k)).not.toContain("effect");
  });
});
