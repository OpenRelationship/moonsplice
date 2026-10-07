import { useMemo, useState } from "react";
import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { type Tab } from "../state";
import { Distinction } from "../ui/bits";
import { gapAfter, type Lane, type Note as NoteView } from "./lanes";
import { showKeys } from "../Keys";
import { NAME_COL, SOUND_H } from "./sizes";

export function Footer({
  lanes: all,
  legend,
  stride,
  cli,
}: {
  lanes: Lane[];
  legend: boolean;
  stride: number;
  cli?: { why: string }[];
}) {
  const shown = all.filter((l) => l.group === "picture").length;
  const heard = all.length - shown;
  return (
    <div
      className="flex h-[24px] shrink-0 items-center justify-between gap-3 border-t px-3"
      style={{ borderColor: "var(--edge-soft)" }}
    >
      {/* The key is worth a line of attention only once a lane is open and the marks are on
          screen to be keyed. Closed, the clips speak for themselves. */}
      {legend ? (
        <Distinction
          moves={all.some((l) => l.bars.length > 0)}
          pins={all.some((l) => l.marks.length > 0)}
        />
      ) : (
        <span />
      )}
      <div className="flex items-center gap-3">
        {cli?.length ? (
          <span className="text-[10.5px] text-[var(--warn)]">
            {cli.length === 1
              ? "1 thing here can only be rendered from the command line"
              : `${cli.length} things here can only be rendered from the command line`}
          </span>
        ) : stride > 1 ? (
          <span
            className="text-[10.5px] text-[var(--text-3)]"
            title={`On screen was measured every ${stride} frames, so a flash shorter than that may not show`}
          >
            measured coarsely
          </span>
        ) : null}
        <span className="tnum text-[10.5px] text-[var(--text-3)]">
          {shown} {shown === 1 ? "thing" : "things"}
          {heard > 0 ? `, ${heard} ${heard === 1 ? "sound" : "sounds"}` : ""}
        </span>
        {/* The only place the shortcuts are advertised. One character, at the far end of a line
            nobody reads twice — enough to be found, not enough to be in the way. */}
        <button
          type="button"
          onClick={showKeys}
          title="The quick ways"
          aria-label="The quick ways"
          className="flex h-[15px] w-[15px] items-center justify-center rounded-full text-[10px] text-[var(--text-3)] hover:text-[var(--text-1)]"
          style={{ border: "1px solid var(--edge-soft)" }}
        >
          ?
        </button>
      </div>
    </div>
  );
}

/** Where sound begins. Every editor draws this line, and for the same reason: a person scanning
 *  for a shot and a person scanning for a cue are not looking for the same thing. */
export function SoundDivider({ width }: { width: number }) {
  return (
    <div className="flex border-b" style={{ height: SOUND_H, borderColor: "var(--edge-soft)" }}>
      <div
        className="sticky left-0 z-10 flex shrink-0 items-center border-r px-2"
        style={{ width: NAME_COL, background: "var(--ink-0)", borderColor: "var(--edge-soft)" }}
      >
        <span className="text-[9.5px] font-semibold uppercase tracking-[0.09em] text-[var(--text-3)]">
          Sound
        </span>
      </div>
      <div style={{ width, background: "var(--ink-0)" }} />
    </div>
  );
}

export function Playhead({
  t,
  pps,
  grab,
}: {
  t: number;
  pps: number;
  grab: (e: React.PointerEvent) => void;
}) {
  return (
    <div
      className="pointer-events-none absolute bottom-0 top-0 z-[15] w-px"
      style={{ left: NAME_COL + t * pps, background: "var(--text-1)" }}
    >
      <span
        role="slider"
        aria-label="Playhead"
        aria-valuenow={Math.round(t * 1000) / 1000}
        tabIndex={-1}
        className="pointer-events-auto absolute -left-[5px] top-0 h-[10px] w-[11px] cursor-ew-resize"
        style={{ background: "var(--text-1)", clipPath: "polygon(0 0, 100% 0, 50% 100%)" }}
        onPointerDown={grab}
      />
    </div>
  );
}

/**
 * One note on the ruler.
 *
 * A flag, the way every editor draws one, and the three things a person does with one: click it
 * to go there, double-click to change what it says, and the small cross to take it out. It is
 * not selected into the inspector, because a note has no properties worth a panel -- when it is
 * and what it says are the whole of it, and both are edited right here.
 */
export function Note({
  note,
  pps,
  variation,
  onSeek,
  onSay,
}: {
  note: NoteView;
  pps: number;
  variation: string;
  onSeek: (t: number) => void;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
}) {
  const [saying, setSaying] = useState<string | null>(null);

  const rename = async (text: string) => {
    setSaying(null);
    const said = text.trim();
    if (!said || said === note.text) return;
    try {
      const done = await bridge.gesture(variation, {
        gesture: "set_value",
        node: note.id,
        key: "text",
        value: said,
      });
      onSay("said", done.what[0] ?? "Changed the note");
    } catch (err) {
      onSay("refused", why(err));
    }
  };

  return (
    <div
      className="group/note absolute bottom-0 z-[3] flex items-end"
      style={{ left: note.at * pps }}
    >
      <span className="h-full w-px" style={{ background: "var(--pin)" }} aria-hidden />
      {saying === null ? (
        <button
          type="button"
          className="ml-px flex h-[12px] max-w-[160px] items-center gap-1 rounded-r-[3px] pl-1 pr-0.5 text-[9.5px] leading-none"
          style={{ background: "var(--pin-dim)", color: "var(--text-1)" }}
          title={`${note.text} — ${fmt.seconds(note.at)}. Double-click to change it.`}
          onPointerDown={(e) => e.stopPropagation()}
          onClick={(e) => {
            e.stopPropagation();
            onSeek(note.at);
          }}
          onDoubleClick={(e) => {
            e.stopPropagation();
            setSaying(note.text);
          }}
        >
          <span className="truncate">{note.text}</span>
          <span
            role="button"
            tabIndex={-1}
            aria-label={`Take out the note “${note.text}”`}
            className="shrink-0 px-0.5 opacity-0 transition-opacity group-hover/note:opacity-70 hover:!opacity-100"
            onPointerDown={(e) => e.stopPropagation()}
            onClick={async (e) => {
              e.stopPropagation();
              try {
                const gone = await bridge.gesture(variation, {
                  gesture: "remove",
                  node: note.id,
                });
                onSay("said", gone.what[0] ?? "Took the note out");
              } catch (err) {
                onSay("refused", why(err));
              }
            }}
          >
            ×
          </span>
        </button>
      ) : (
        <input
          autoFocus
          value={saying}
          className="ml-px h-[12px] w-[140px] rounded-r-[3px] px-1 text-[9.5px] leading-none outline-none"
          style={{ background: "var(--ink-2)", color: "var(--text-1)" }}
          onPointerDown={(e) => e.stopPropagation()}
          onChange={(e) => setSaying(e.target.value)}
          onBlur={(e) => void rename(e.target.value)}
          onKeyDown={(e) => {
            if (e.key === "Enter") void rename(e.currentTarget.value);
            if (e.key === "Escape") setSaying(null);
            e.stopPropagation();
          }}
        />
      )}
    </div>
  );
}

/**
 * The empty stretch after a clip, and the one click that closes it.
 *
 * A ripple is the edit in a cutting room that is about the things you did *not* touch, and that
 * is exactly what makes it frightening: you press a key and nine things move. So it is drawn
 * first. The hole is hatched, it says how long it is, and clicking it pulls the rest of its own
 * kind up to meet the clip -- and if something after it is animated, the app says so instead,
 * because a movement is written against the composition's clock and would be left behind.
 */
export function Gap({
  lane,
  stack,
  pps,
  tab,
  onSay,
}: {
  lane: Lane;
  stack: Lane[];
  pps: number;
  tab: Tab;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
}) {
  const gap = useMemo(
    () => gapAfter(stack, lane.node.id, tab.meta.duration),
    [stack, lane.node.id, tab.meta.duration],
  );
  if (!gap) return null;
  const width = (gap.t1 - gap.t0) * pps;
  if (width < 8) return null;

  return (
    <button
      type="button"
      className="group/gap absolute top-1/2 h-[18px] -translate-y-1/2 overflow-hidden rounded-[3px] transition-colors"
      style={{
        left: gap.t0 * pps,
        width,
        border: "1px dashed var(--edge)",
        background:
          "repeating-linear-gradient(135deg, transparent 0 5px, color-mix(in oklab, var(--text-3) 12%, transparent) 5px 6px)",
      }}
      title={`Nothing here for ${fmt.seconds(gap.t1 - gap.t0)} — close it and bring the rest up`}
      aria-label={`Close the ${fmt.seconds(gap.t1 - gap.t0)} gap`}
      onPointerDown={(e) => e.stopPropagation()}
      onClick={async (e) => {
        e.stopPropagation();
        try {
          const done = await bridge.gesture(tab.variation, {
            gesture: "close_gap",
            after: lane.node.id,
          });
          onSay("said", done.what[0] ?? "Closed the gap");
        } catch (err) {
          onSay("refused", why(err));
        }
      }}
    >
      <span className="absolute inset-0 flex items-center justify-center gap-1 text-[10px] text-[var(--text-3)] opacity-0 transition-opacity group-hover/gap:opacity-100">
        <span
          className="h-px w-3"
          style={{ background: "currentColor" }}
          aria-hidden
        />
        close
      </span>
    </button>
  );
}
