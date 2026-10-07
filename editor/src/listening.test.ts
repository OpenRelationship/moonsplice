// How loud the preview is.
//
// The number itself is one line of a store, so what is worth testing is the two rules around it:
// that it cannot leave 0..1 however it is asked to, and that it is not an edit -- it must not
// reach the source, the undo stack, or anything that is exported.

import { describe, expect, it } from "vitest";

import { useStudio } from "./state";

describe("the listening level", () => {
  it("starts somewhere audible", () => {
    const at = useStudio.getState().listening;
    expect(at).toBeGreaterThan(0);
    expect(at).toBeLessThanOrEqual(1);
  });

  it("cannot be set outside what a gain can be", () => {
    const set = useStudio.getState().setListening;
    set(4);
    expect(useStudio.getState().listening).toBe(1);
    set(-2);
    expect(useStudio.getState().listening).toBe(0);
    set(0.35);
    expect(useStudio.getState().listening).toBe(0.35);
  });

  it("how loud the preview is changes nothing that is written down", () => {
    // Silence is not the same as `volume = 0` on a clip: one is about this pair of ears and the
    // other is written down and rendered. If setting it ever touched a tab, that line would
    // have been crossed.
    const before = useStudio.getState();
    const tabs = before.tabs;
    const project = before.project;
    before.setListening(0);
    const after = useStudio.getState();
    expect(after.tabs).toBe(tabs);
    expect(after.project).toBe(project);
    after.setListening(0.8);
  });

  it("is the only control in the transport that is not an edit", async () => {
    const fs = await import("node:fs");
    const path = await import("node:path");
    const src = fs.readFileSync(path.resolve(process.cwd(), "src/stage/Stage.tsx"), "utf8");
    // It has to be reachable without a mouse and nameable by a screen reader, because it is a
    // slider and a slider with no name is a smear of pixels.
    expect(src).toContain('aria-label="How loud the preview is"');
    // The speaker restores where it was rather than guessing a level.
    expect(src).toContain("wasAt.current");
  });
});
