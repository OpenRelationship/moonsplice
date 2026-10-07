import { describe, expect, it, vi } from "vitest";

import { CROWDED, crowded, dragDrop, flatten } from "./Library";
import type { TreeItem } from "../types";

describe("dropping things into a project", () => {
  it("highlights the folder under the cursor, and stops when the drag leaves", () => {
    const over = vi.fn();
    const drop = vi.fn();
    const at = () => "Interviews";
    dragDrop({ type: "over", position: { x: 40, y: 200 } }, over, drop, at);
    expect(over).toHaveBeenLastCalledWith("Interviews");
    dragDrop({ type: "leave" }, over, drop, at);
    expect(over).toHaveBeenLastCalledWith(null);
    expect(drop).not.toHaveBeenCalled();
  });

  it("treats the pane itself as the top of the project", () => {
    const over = vi.fn();
    dragDrop({ type: "over", position: { x: 40, y: 600 } }, over, vi.fn(), () => null);
    expect(over).toHaveBeenLastCalledWith("");
  });

  it("takes whatever was dropped, whatever it is, into the folder it landed on", () => {
    const over = vi.fn();
    const drop = vi.fn();
    dragDrop(
      {
        type: "drop",
        paths: ["/a/Earth Night.mp4", "/a/notes.tsv", "/a/thing.qqq"],
        position: { x: 40, y: 200 },
      },
      over,
      drop,
      () => "Interviews",
    );
    // The highlight goes off the moment it lands, not when the copy finishes.
    expect(over).toHaveBeenLastCalledWith(null);
    expect(drop).toHaveBeenCalledWith(
      ["/a/Earth Night.mp4", "/a/notes.tsv", "/a/thing.qqq"],
      "Interviews",
    );
  });

  it("does nothing on a drop of nothing, rather than saying it added none", () => {
    const drop = vi.fn();
    dragDrop({ type: "drop" }, vi.fn(), drop);
    expect(drop).toHaveBeenCalledWith([], "");
  });

  it("ignores an event it does not know", () => {
    const over = vi.fn();
    const drop = vi.fn();
    dragDrop({ type: "enter" }, over, drop);
    expect(over).not.toHaveBeenCalled();
    expect(drop).not.toHaveBeenCalled();
  });
});

describe("the tree", () => {
  const tree: TreeItem[] = [
    {
      what: "folder",
      name: "Interviews",
      at: "Interviews",
      items: [
        { what: "asset", asset: { id: "day-one", name: "Day one", kind: "footage", size: 10 } },
        {
          what: "folder",
          name: "Offcuts",
          at: "Interviews/Offcuts",
          items: [
            { what: "asset", asset: { id: "take-9", name: "Take 9", kind: "footage", size: 10 } },
          ],
        },
      ],
    },
    {
      what: "composition",
      comp: {
        id: "opening",
        title: "Opening",
        variations: [{ id: "opening", title: "Wide", aspect: "16:9", empty: false }],
      },
    },
  ];

  it("flattens to everything in it, however deep", () => {
    const names = flatten(tree).map((i) =>
      i.what === "folder" ? `${i.name}/` : i.what === "asset" ? i.asset.name : i.comp.title,
    );
    expect(names).toEqual(["Interviews/", "Day one", "Offcuts/", "Take 9", "Opening"]);
  });
});

describe("a folder that would fill the pane", () => {
  const folder = (at: string, items: TreeItem[]): TreeItem => ({
    what: "folder",
    name: at,
    at,
    items,
  });
  const asset = (id: string): TreeItem => ({
    what: "asset",
    asset: { id, name: id, kind: "audio", at: "", size: null } as never,
  });

  it("starts shut, and a small one does not", () => {
    // The project that made this necessary: seventy narration lines in a folder called Sound,
    // and the pane was a list of them and nothing else -- no footage, no compositions, not even
    // the folders they were in.
    const tree = [
      folder(
        "Sound",
        Array.from({ length: 71 }, (_, i) => asset(`vo-${i}`)),
      ),
      folder("Footage", [asset("a"), asset("b"), asset("c")]),
    ];
    expect(crowded(tree)).toEqual(["Sound"]);
  });

  it("counts what a folder holds, not everything underneath it", () => {
    // Three folders is three rows and is perfectly readable, however much is further down.
    const tree = [
      folder("Everything", [
        folder(
          "Sound",
          Array.from({ length: 30 }, (_, i) => asset(`s-${i}`)),
        ),
        folder("Footage", [asset("a")]),
        folder("Stills", [asset("b")]),
      ]),
    ];
    expect(crowded(tree)).toEqual(["Sound"]);
  });

  it("says nothing about a project with nothing crowded in it", () => {
    expect(crowded([])).toEqual([]);
    expect(crowded([folder("Footage", [asset("a")])])).toEqual([]);
    // Exactly at the line is still open: the line is "more than this", not "this many".
    expect(
      crowded([folder("Just enough", Array.from({ length: CROWDED }, (_, i) => asset(`x${i}`)))]),
    ).toEqual([]);
  });
});
