import { describe, expect, it } from "vitest";

import raw from "../vocabulary.json";
import * as fmt from "./format";

type Table = Record<string, string>;
const vocab = raw as unknown as {
  property: Table;
  kind: Table;
  curve: Table;
  curveMenu: string[];
};

// The words live in one file so the timeline, the notices and the agent cannot disagree about
// what a thing is called. These check the file is whole and that the UI actually reads it —
// `src-tauri/src/words.rs` has the matching checks on the other side.

describe("the shared vocabulary", () => {
  it("covers every kind the timeline can draw a lane for", () => {
    for (const k of ["text", "rect", "captions", "image", "video", "audio", "tts", "group"]) {
      expect(vocab.kind[k], k).toBeTruthy();
      expect(fmt.kind(k)).toBe(vocab.kind[k]);
    }
  });

  it("offers only curves it has a word for", () => {
    for (const c of vocab.curveMenu) {
      expect(vocab.curve[c], c).toBeTruthy();
      expect(fmt.curve(c)).toBe(vocab.curve[c]);
    }
    expect(fmt.CURVES).toEqual(vocab.curveMenu);
  });

  it("says nothing that looks like an identifier", () => {
    const codey = (s: string) => /[_:.(]/.test(s) || /[a-z][A-Z]/.test(s);
    for (const table of [vocab.property, vocab.kind, vocab.curve]) {
      for (const [key, word] of Object.entries(table)) {
        expect(codey(word), `${key} -> ${word}`).toBe(false);
      }
    }
  });

  it("gives every property the inspector shows a word of its own", () => {
    for (const p of ["x", "y", "w", "h", "opacity", "size", "rotation", "scale", "color", "text"]) {
      expect(vocab.property[p], p).toBeTruthy();
    }
  });
});
