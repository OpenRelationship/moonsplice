// What the keyboard does, said once, where somebody can find it.
//
// Every shortcut in this app is a thing you can also do with the mouse — that is the rule, and
// it is why none of them had to be documented to be usable. But a person who has been using it
// for a week wants the fast way, and hunting for it in a menu they have never opened is not
// discovery. `?` shows this; anything dismisses it.
//
// The words are the app's words. No key is spelled the way a keyboard event spells it: there is
// no "Meta", no "ArrowLeft", no "KeyK". A shortcut a person cannot read aloud is a shortcut they
// will not remember.

import { useEffect, useState } from "react";

const MAC = typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform);
/** The modifier, spelled the way the machine in front of you spells it. */
const MOD = MAC ? "⌘" : "Ctrl";

interface Group {
  title: string;
  keys: [string, string][];
}

export const GROUPS: Group[] = [
  {
    title: "Watching",
    keys: [
      ["Space", "Play, or stop"],
      ["L / J", "Faster, forwards or backwards; press again to double"],
      ["K", "Stop, from any speed"],
      ["← →", "One frame back, one frame on"],
      ["Shift ← →", "Ten frames at a time"],
      ["Home / End", "To the start, to the end"],
    ],
  },
  {
    title: "Editing",
    keys: [
      ["M", "Pin a note where you are looking"],
      [`${MOD} K`, "Cut the picked clip where the playhead is"],
      ["Delete", "Take the picked thing out"],
      [`${MOD} Delete`, "Take it out and close the gap it leaves"],
      [`${MOD} ]`, "Bring it forward, in front of the next thing"],
      [`${MOD} [`, "Send it back, behind the last thing"],
      [`${MOD} Z`, "Undo"],
      [`${MOD} ⇧ Z`, "Redo"],
    ],
  },
  {
    title: "With the mouse",
    keys: [
      ["Drag a clip", "Moves it; it catches on the playhead and on other clips"],
      ["Drag its ends", "Trims it, without moving the picture inside"],
      ["Drag a movement's ends", "Moves when it starts, or how long it runs"],
      ["Double-click a name", "Renames it"],
      ["Click the hatched gap", "Closes it, and brings the rest of its own kind up"],
      ["Double-click a note", "Changes what it says; clicking one goes there"],
    ],
  },
];

/** Ask for the sheet from somewhere else in the app. The sheet listens for the key, so this is
 *  the key — one listener, one way in, and nothing to keep in step. */
export function showKeys() {
  window.dispatchEvent(new KeyboardEvent("keydown", { key: "?" }));
}

/** The sheet itself. It is not a dialog: nothing in it can be acted on, so nothing in it can be
 *  got wrong, and anything at all puts it away. */
export function Keys() {
  const [open, setOpen] = useState(false);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const el = e.target as HTMLElement | null;
      const typing =
        !!el &&
        (el.tagName === "INPUT" ||
          el.tagName === "TEXTAREA" ||
          el.tagName === "SELECT" ||
          el.isContentEditable);
      if (typing) return;
      if (e.key === "?" || (e.key === "/" && e.shiftKey)) {
        e.preventDefault();
        setOpen((was) => !was);
        return;
      }
      if (open) setOpen(false);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [open]);

  if (!open) return null;

  return (
    <div
      className="fixed inset-0 z-[100] flex items-center justify-center p-8"
      style={{ background: "color-mix(in oklab, var(--ink-0) 72%, transparent)" }}
      onPointerDown={() => setOpen(false)}
      role="presentation"
    >
      <div
        className="max-h-full w-full max-w-[560px] overflow-auto rounded-[var(--radius)] p-6"
        style={{
          background: "var(--ink-1)",
          boxShadow: "var(--shadow-lift)",
          border: "1px solid var(--edge-soft)",
        }}
        onPointerDown={(e) => e.stopPropagation()}
      >
        <div className="mb-4 flex items-baseline justify-between">
          <h2 className="text-[13px] font-semibold text-[var(--text-1)]">The quick ways</h2>
          <span className="text-[10.5px] text-[var(--text-3)]">
            Everything here can also be done with the mouse
          </span>
        </div>
        {GROUPS.map((group) => (
          <section key={group.title} className="mb-4 last:mb-0">
            <h3 className="mb-1.5 text-[9.5px] font-semibold uppercase tracking-[0.09em] text-[var(--text-3)]">
              {group.title}
            </h3>
            <dl className="grid grid-cols-[minmax(0,148px)_1fr] gap-x-4 gap-y-1">
              {group.keys.map(([key, what]) => (
                <div key={key} className="contents">
                  <dt className="tnum truncate text-[11.5px] text-[var(--text-2)]">{key}</dt>
                  <dd className="text-[11.5px] text-[var(--text-1)]">{what}</dd>
                </div>
              ))}
            </dl>
          </section>
        ))}
      </div>
    </div>
  );
}
