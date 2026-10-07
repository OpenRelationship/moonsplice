import { describe, expect, it } from "vitest";

import { GROUPS } from "./Keys";

describe("the sheet of quick ways", () => {
  it("says every one of them in words a person could read aloud", () => {
    const all = GROUPS.flatMap((g) => g.keys);
    expect(all.length).toBeGreaterThan(10);
    for (const [key, what] of all) {
      // No key is spelled the way a keyboard event spells it. A shortcut somebody cannot read
      // aloud is a shortcut they will not remember.
      for (const code of ["Meta", "Arrow", "Key", "Digit", "ctrlKey", "metaKey"]) {
        expect(key, `${key} reads like code`).not.toContain(code);
      }
      expect(what[0]).toBe(what[0].toUpperCase());
      expect(what).not.toContain("_");
      expect(what.length).toBeLessThan(70);
    }
  });

  it("names each one once", () => {
    const keys = GROUPS.flatMap((g) => g.keys.map(([k]) => k));
    expect(new Set(keys).size).toBe(keys.length);
  });

  it("covers every shortcut the app actually listens for", async () => {
    // The sheet and the handler have to agree, or it is documentation rather than help.
    const fs = await import("node:fs");
    const path = await import("node:path");
    const app = fs.readFileSync(path.resolve(process.cwd(), "src/App.tsx"), "utf8");
    const said = GROUPS.flatMap((g) => g.keys.map(([k]) => k)).join(" ");
    const listens: [string, string][] = [
      ['case " "', "Space"],
      ['case "ArrowLeft"', "←"],
      ['case "Home"', "Home"],
      ['case "Delete"', "Delete"],
      ['e.key === "]"', "]"],
      ['e.key === "["', "["],
      ['e.key.toLowerCase() === "k"', "K"],
      ['e.key.toLowerCase() === "z"', "Z"],
    ];
    for (const [source, shown] of listens) {
      expect(app, `${source} is not handled any more`).toContain(source);
      expect(said, `${shown} is handled but not on the sheet`).toContain(shown);
    }
  });
});
