import { useEffect, useMemo, useRef, useState } from "react";
import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { useStudio } from "../state";
import { Icon } from "../ui/bits";
import { edges, snap, type Clip, type Lane } from "./lanes";
import { BOX, coarser, wavePath, windowed } from "./shape";
import { TINT, iconFor } from "./LaneRow";
import { useShape } from "./useShape";

/** One stretch of time a thing is on screen.
 *
 *  While the lane is closed, the keyframes inside that stretch are drawn along its lower edge:
 *  present and countable, without pretending to be legible at two pixels. Open the lane to work
 *  on them. */
export function ClipBar({
  clip,
  pps,
  lane,
  open,
  selected,
  variation,
  onSelect,
  onSay,
  stack,
  duration,
}: {
  clip: Clip;
  pps: number;
  lane: Lane;
  open: boolean;
  selected: boolean;
  variation: string;
  onSelect: () => void;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
  stack: Lane[];
  duration: number;
}) {
  // A clip with a length of its own can be dragged along the track and trimmed at either end.
  // A rectangle cannot: it is on screen for as long as the composition says, and the thing that
  // moves it is a movement. The composition says which is which -- `from` for a clip, `at` for a
  // sound -- so the handles appear exactly where there is something to take hold of.
  const props = (lane.node.props ?? {}) as Record<string, unknown>;
  const holdable = "from" in props || "at" in props;
  const [drag, setDrag] = useState<{ edge: "in" | "out" | null; x0: number; dx: number } | null>(
    null,
  );
  // Only the clip you are working on watches the playhead. Ninety lanes all subscribing to it
  // would re-render the whole timeline on every frame of playback; a selector that answers 0 for
  // the rest answers the same 0 every time, so they do not.
  const watching = selected || drag !== null;
  const playhead = useStudio((s) => (watching ? s.playhead : 0));

  // What this clip should catch on while it is being dragged: the playhead, the ends of the
  // composition, and where every other clip begins and stops.
  const catches = useMemo(
    () => (watching ? edges(stack, lane.node.id, duration, playhead) : []),
    [watching, stack, lane.node.id, duration, playhead],
  );
  /** Where a drag of `dx` pixels from `base` lands once it has caught on something. */
  const landing = (base: number, dx: number) => snap(base + dx / pps, catches, pps);

  const take = (edge: "in" | "out" | null) => (e: React.PointerEvent) => {
    e.stopPropagation();
    onSelect();
    if (!holdable) return;
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    setDrag({ edge, x0: e.clientX, dx: 0 });
  };

  const move = (e: React.PointerEvent) => {
    if (!drag) return;
    setDrag({ ...drag, dx: e.clientX - drag.x0 });
  };

  const drop = async (e: React.PointerEvent) => {
    if (!drag) return;
    const dx = e.clientX - drag.x0;
    setDrag(null);
    if (Math.abs(dx) < 2) return; // a click, not a drag
    const from = drag.edge === "out" ? clip.t1 : clip.t0;
    try {
      const said = await bridge.gesture(
        variation,
        drag.edge === null
          ? { gesture: "slide", node: lane.node.id, t: landing(from, dx) }
          : { gesture: "trim", node: lane.node.id, edge: drag.edge, t: landing(from, dx) },
      );
      if (said.what[0]) onSay("said", said.what[0]);
    } catch (err) {
      onSay("refused", why(err));
    }
  };

  const cut = async () => {
    try {
      const said = await bridge.gesture(variation, {
        gesture: "split",
        node: lane.node.id,
        t: playhead,
      });
      if (said.what[0]) onSay("said", said.what[0]);
    } catch (err) {
      onSay("refused", why(err));
    }
  };

  // While dragging, the bar goes where the drag will actually land -- caught on whatever it is
  // near -- rather than where the pointer is. A clip that snaps on release and not before is a
  // clip that jumps out from under you at the last moment.
  const held = drag ? (drag.edge === "out" ? clip.t1 : clip.t0) : 0;
  const shift = drag ? (landing(held, drag.dx) - held) * pps : 0;
  const left = clip.t0 * pps + (drag && drag.edge !== "out" ? shift : 0);
  const within = (t: number) => t >= clip.t0 - 1e-6 && t <= clip.t1 + 1e-6;
  const bars = open ? [] : lane.bars.filter((b) => within(b.t0));
  const marks = open ? [] : lane.marks.filter((m) => within(m.t));
  const tint = TINT[lane.group === "sound" ? "sound" : lane.node.kind] ?? null;
  // What this clip needed is not on the disk. It is still a clip: the same length, in the same
  // place, still draggable, still trimmable -- an edit does not stop being an edit because the
  // footage moved, and an editor that took the clip away would lose the work as well as the
  // file. What changes is that it stops pretending to have a picture.
  const offline = lane.offline;

  // A sound draws what it sounds like. Seventy lanes of identical grey tell you there is
  // narration at four minutes; they do not tell you whether it is a sentence or a breath.
  const width = Math.max(2, (clip.t1 - clip.t0) * pps);
  const shape = useShape(variation, lane.node.id, lane.group === "sound" && width > 12);
  const drawn = useMemo(() => {
    if (!shape) return "";
    const a = lane.audio;
    const part = windowed(shape, a?.media_start ?? 0, clip.t1 - clip.t0, a?.media_duration);
    // Never more points than the bar has pixels: past that it is detail nobody can see and
    // path data nobody needs.
    return wavePath(coarser(part, Math.max(8, Math.round(width))));
  }, [shape, lane.audio, clip.t0, clip.t1, width]);

  // A cut needs a piece either side of it, so the handle only appears where there would be two.
  const cutAt =
    selected && holdable && !drag && playhead > clip.t0 + 1e-6 && playhead < clip.t1 - 1e-6
      ? (playhead - clip.t0) * pps
      : null;

  return (
    <div
      className="absolute top-1/2 -translate-y-1/2 overflow-hidden rounded-[3px]"
      style={{
        left,
        width: Math.max(
          2,
          drag?.edge === "out" ? width + shift : drag?.edge === "in" ? width - shift : width,
        ),
        height: 18,
        cursor: holdable ? (drag?.edge ? "col-resize" : "grab") : undefined,
        // One tone for every clip, with a hint of what kind of thing it is — enough to scan a
        // long list by, not enough to become a code a person has to learn.
        background: offline
          ? // Hatched, the way every editor has drawn offline media: readable at two pixels
            // wide and at two hundred, and not mistakable for a colour that means something.
            "repeating-linear-gradient(135deg," +
            " color-mix(in oklab, var(--warn) 22%, var(--clip)) 0 5px," +
            " color-mix(in oklab, var(--warn) 8%, var(--clip)) 5px 10px)"
          : tint
            ? `color-mix(in oklab, ${tint} 18%, var(--clip))`
            : "var(--clip)",
        boxShadow: selected
          ? "inset 0 0 0 1.5px var(--focus)"
          : offline
            ? "inset 0 0 0 1px color-mix(in oklab, var(--warn) 55%, var(--clip-edge))"
            : `inset 0 0 0 1px ${tint ? `color-mix(in oklab, ${tint} 40%, var(--clip-edge))` : "var(--clip-edge)"}`,
      }}
      title={
        offline
          ? `${lane.name} is ${fmt.offlineWhy(offline)} — the clip is still here, so putting the file back and reopening brings the picture back`
          : holdable
            ? `On screen from ${fmt.seconds(clip.t0)} to ${fmt.seconds(clip.t1)} — drag to move it, drag an end to trim it`
            : `On screen from ${fmt.seconds(clip.t0)} to ${fmt.seconds(clip.t1)}`
      }
      onPointerDown={take(null)}
      onPointerMove={move}
      onPointerUp={(e) => void drop(e)}
      onPointerCancel={() => setDrag(null)}
    >
      {/* What the drag will do, in numbers, while it is being done. A bar that moves and says
          nothing leaves you reading the ruler; this says the one number that changed. */}
      {drag ? (
        <span
          className="tnum pointer-events-none absolute left-1 top-1/2 z-[3] -translate-y-1/2 rounded-[2px] px-1 text-[9.5px]"
          style={{ background: "var(--ink-0)", color: "var(--text-1)" }}
        >
          {drag.edge === null
            ? fmt.seconds(landing(clip.t0, drag.dx))
            : `${fmt.seconds(
                drag.edge === "in"
                  ? clip.t1 - landing(clip.t0, drag.dx)
                  : landing(clip.t1, drag.dx) - clip.t0,
              )} long`}
        </span>
      ) : null}

      {/* The razor, where the playhead crosses the clip you picked. Every editor has this and
          every editor hides it behind a shortcut as well; this is the one you can see. */}
      {cutAt !== null ? (
        <button
          type="button"
          className="group/cut absolute inset-y-0 z-[2] flex w-[13px] -translate-x-1/2 items-center justify-center"
          style={{ left: cutAt }}
          title="Cut it in two here"
          aria-label="Cut it in two here"
          onPointerDown={(e) => e.stopPropagation()}
          onClick={(e) => {
            e.stopPropagation();
            void cut();
          }}
        >
          <span
            className="h-full w-px opacity-70 group-hover/cut:opacity-100"
            style={{ background: "var(--text-1)" }}
          />
          <span
            className="absolute -top-[13px] flex h-[13px] w-[13px] items-center justify-center rounded-[3px] opacity-0 transition-opacity group-hover/cut:opacity-100"
            style={{ background: "var(--ink-2)", color: "var(--text-1)" }}
          >
            <Icon name="razor" className="h-[9px] w-[9px]" />
          </span>
        </button>
      ) : null}

      {/* The two ends, where a trim is taken hold of. Only on something that has a length. */}
      {holdable && width > 14 ? (
        <>
          <span
            className="absolute inset-y-0 left-0 w-[5px] cursor-col-resize"
            onPointerDown={take("in")}
            onPointerMove={move}
            onPointerUp={(e) => void drop(e)}
            aria-label="Trim the start"
          />
          <span
            className="absolute inset-y-0 right-0 w-[5px] cursor-col-resize"
            onPointerDown={take("out")}
            onPointerMove={move}
            onPointerUp={(e) => void drop(e)}
            aria-label="Trim the end"
          />
        </>
      ) : null}
      {drawn ? (
        <svg
          className="pointer-events-none absolute inset-0 h-full w-full"
          viewBox={`0 0 ${BOX.w} ${BOX.h}`}
          preserveAspectRatio="none"
          aria-hidden
        >
          <path d={drawn} fill="var(--wave)" />
        </svg>
      ) : null}
      {bars.map((b, i) => (
        <span
          key={`b${i}`}
          className="absolute bottom-0 h-[2px] rounded-full"
          style={{
            left: (b.t0 - clip.t0) * pps,
            width: Math.max(2, (b.t1 - b.t0) * pps),
            background: "var(--move)",
          }}
          aria-hidden
        />
      ))}
      {marks.map((m, i) => (
        <span
          key={`m${i}`}
          className="absolute bottom-[1.5px] h-[4px] w-[4px] -translate-x-1/2 rotate-45"
          style={{ left: (m.t - clip.t0) * pps, background: "var(--pin)" }}
          aria-hidden
        />
      ))}
    </div>
  );
}

/** What a thing is called, and where it is renamed.
 *
 *  A shape nobody named is "Block 2", which is a position and not a name: reorder the stack and
 *  it becomes Block 1 while the thing has not changed. Double-clicking it writes a name into the
 *  composition, which then survives everything — the same place every other change goes. */
export function LaneName({
  lane,
  variation,
  onSelect,
  onSay,
}: {
  lane: Lane;
  variation: string;
  onSelect: () => void;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
}) {
  const [typing, setTyping] = useState<string | null>(null);
  const box = useRef<HTMLInputElement>(null);

  useEffect(() => {
    if (typing !== null) box.current?.select();
  }, [typing]);

  const land = async (said: string) => {
    const name = said.trim();
    setTyping(null);
    if (!name || name === lane.name) return;
    try {
      const done = await bridge.gesture(variation, {
        gesture: "set_value",
        node: lane.node.id,
        key: "label",
        value: name,
      });
      if (done.what[0]) onSay("said", done.what[0]);
    } catch (err) {
      onSay("refused", why(err));
    }
  };

  if (typing !== null) {
    return (
      <span className="flex min-w-0 flex-1 items-center gap-1.5 pr-2">
        <Icon name={iconFor(lane)} className="shrink-0 text-[var(--text-3)]" />
        <input
          ref={box}
          value={typing}
          onChange={(e) => setTyping(e.target.value)}
          onBlur={() => void land(typing)}
          onKeyDown={(e) => {
            e.stopPropagation();
            if (e.key === "Enter") void land(typing);
            if (e.key === "Escape") setTyping(null);
          }}
          className="min-w-0 flex-1 rounded-[2px] px-1 text-[12px] outline-none"
          style={{ background: "var(--ink-0)", color: "var(--text-1)" }}
          aria-label="What this is called"
        />
      </span>
    );
  }

  return (
    <button
      type="button"
      onClick={onSelect}
      onDoubleClick={() => setTyping(lane.name)}
      title={`${lane.name} — double-click to rename`}
      className="flex min-w-0 flex-1 items-center gap-1.5 pr-2 text-left"
    >
      <Icon name={iconFor(lane)} className="shrink-0 text-[var(--text-3)]" />
      <span className="min-w-0 flex-1 truncate text-[12px] text-[var(--text-1)]">{lane.name}</span>
    </button>
  );
}
