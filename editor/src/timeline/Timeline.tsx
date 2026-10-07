// The timeline.
//
// It works the way the timeline in any editor works, and that is the point. A **clip** is a bar
// whose width is the stretch of time a thing is on screen, so the widest shape in a lane carries
// the answer to the first question anybody asks of a timeline; the engine measures that stretch
// (`core/moonsplice/onscreen.lua`) rather than the app guessing at it. A lane **opens** into one row
// per property, named — a composition with thirty things in it has a hundred properties, and all
// of them at once is what made this unreadable. Sound sits below picture, because it is read
// differently. The scale is a number of pixels per second a person can change, not a fit to the
// pane, so a long composition is scrolled rather than crushed.
//
// Inside an open lane, a movement is a teal bar with its curve drawn in it and a value set by
// hand is an amber diamond. That is not decoration: `app-shell` requires a manual value to read
// as a different kind of thing from a tween, and it *is* one — a movement relates two values
// over a duration, a pin is a value somebody decided at an instant.
//
// Every drag here names a lowering verb. The one that has none — moving where a movement starts
// — is attempted and refused, because the alternative is a second way to edit a composition.

import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import clsx from "clsx";

import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { activeTab, useStudio, type Tab } from "../state";
import { Button, Distinction, Empty, Icon } from "../ui/bits";
import {
  easeShape,
  fitZoom,
  edges,
  gapAfter,
  lanes,
  notes,
  restep,
  snap,
  ticks,
  zoomStep,
  type Bar,
  type Clip,
  type Lane,
  type Note as NoteView,
  type Row,
} from "./lanes";
import { BOX, coarser, wavePath, windowed } from "./shape";
import { showKeys } from "../Keys";

/** Every sound shape the window has asked for, by composition and name.
 *
 *  A module-level map rather than state, because the answer does not change while the app is
 *  open and two lanes of the same sound must not ask twice. `null` is "asked and there is no
 *  answer" -- a sound that would not read is not asked about again. */
const SHAPES = new Map<string, number[] | null>();
const ASKING = new Set<string>();

/** The shape of one sound, fetched the first time a lane wants it. */
function useShape(variation: string, node: string, wanted: boolean): number[] | null {
  const key = `${variation}\u0000${node}`;
  const [shape, setShape] = useState<number[] | null>(() => SHAPES.get(key) ?? null);

  useEffect(() => {
    if (!wanted || SHAPES.has(key)) {
      setShape(SHAPES.get(key) ?? null);
      return;
    }
    if (ASKING.has(key)) return;
    ASKING.add(key);
    let alive = true;
    bridge
      .soundShape(variation, node)
      .then((peaks) => {
        SHAPES.set(key, peaks);
        if (alive) setShape(peaks);
      })
      .catch(() => {
        // A sound the app cannot read is drawn as a plain bar. It is not worth a notice: the
        // person did not ask for a waveform, they asked for a timeline.
        SHAPES.set(key, null);
      })
      .finally(() => ASKING.delete(key));
    return () => {
      alive = false;
    };
  }, [key, node, variation, wanted]);

  return shape;
}

/** What the left pane puts on a drag of one of the project's things. */
const ASSET = "text/moonsplice-asset";

const NAME_COL = 176;
const LANE_H = 30;
const ROW_H = 20;
const RULER_H = 26;
const SOUND_H = 18;

export function Timeline() {
  const tab = useStudio((s) => activeTab(s));
  const height = useStudio((s) => s.timelineHeight);
  if (!tab) {
    return (
      <div className="shrink-0 border-t" style={{ height, borderColor: "var(--edge-soft)" }}>
        <Empty title="No composition open" />
      </div>
    );
  }
  return <Lanes tab={tab} height={height} />;
}

/** The top edge of the timeline, which you can pull. Two pixels of hit area either side of the
 *  border, so it is grabbable without being a visible bar taking up room. */
function GrabEdge() {
  const setHeight = useStudio((s) => s.setTimelineHeight);
  const [dragging, setDragging] = useState(false);

  useEffect(() => {
    if (!dragging) return;
    const move = (e: PointerEvent) => setHeight(window.innerHeight - e.clientY);
    const up = () => setDragging(false);
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    document.body.style.cursor = "ns-resize";
    return () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      document.body.style.cursor = "";
    };
  }, [dragging, setHeight]);

  return (
    <div
      className="group absolute -top-[3px] left-0 right-0 z-30 h-[7px] cursor-ns-resize"
      onPointerDown={(e) => {
        e.preventDefault();
        setDragging(true);
      }}
      onDoubleClick={() => setHeight(228)}
      title="Drag to resize; double-click to reset"
    >
      <div
        className={clsx(
          "absolute inset-x-0 top-[3px] h-px transition-colors",
          dragging ? "bg-[var(--move)]" : "bg-transparent group-hover:bg-[var(--move)]",
        )}
      />
    </div>
  );
}

/** One scroller holds both columns.
 *
 *  Names and lanes have to stay level, and two scrollers cannot: the first flick of a trackpad
 *  puts them a row apart. So the whole grid scrolls, the name column sticks to the left edge of
 *  it, and the ruler sticks to the top. */
function Lanes({ tab, height }: { tab: Tab; height: number }) {
  const playhead = useStudio((s) => s.playhead);
  const seek = useStudio((s) => s.seek);
  const selection = useStudio((s) => s.selection);
  const select = useStudio((s) => s.select);
  const say = useStudio((s) => s.say);
  const opened = useStudio((s) => s.openLanes);
  const toggleLane = useStudio((s) => s.toggleLane);
  const zoom = useStudio((s) => s.zoom);
  const setZoom = useStudio((s) => s.setZoom);

  const scroller = useRef<HTMLDivElement>(null);
  const timeArea = useRef<HTMLDivElement>(null);
  const [pane, setPane] = useState(0);
  /** Something from the left pane is over the timeline, waiting to be let go. */
  const [taking, setTaking] = useState(false);
  const all = useMemo(() => lanes(tab.outline), [tab.outline]);
  const duration = tab.meta.duration;

  // How much room the time column has, which is what "fit" means.
  useEffect(() => {
    const el = scroller.current;
    if (!el) return;
    const ro = new ResizeObserver(([e]) =>
      setPane(Math.max(0, Math.floor(e.contentRect.width) - NAME_COL)),
    );
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const fit = fitZoom(duration, pane);
  const pps = zoom ?? fit;
  const contentW = Math.max(pane, duration * pps);

  // Keep the playhead in view while it runs, the way a transport does — but only when there is
  // somewhere to scroll to.
  useLayoutEffect(() => {
    const el = scroller.current;
    if (!el || contentW <= pane) return;
    const x = playhead * pps;
    const left = el.scrollLeft;
    if (x < left + 24) el.scrollLeft = Math.max(0, x - 24);
    else if (x > left + pane - 48) el.scrollLeft = Math.min(contentW - pane, x - pane + 48);
  }, [playhead, pps, pane, contentW]);

  /** The time a pointer is over. Measured off the ruler, whose box *is* the time column, so
   *  scrolling and the sticky name column need no arithmetic of their own. */
  const timeFromClient = useCallback(
    (clientX: number) => {
      const el = timeArea.current;
      if (!el) return 0;
      const r = el.getBoundingClientRect();
      const t = (clientX - r.left) / pps;
      const fps = tab.meta.fps;
      const clamped = Math.max(0, Math.min(t, duration));
      return fps > 0 ? Math.round(clamped * fps) / fps : clamped;
    },
    [duration, pps, tab.meta.fps],
  );

  /** A thing from the left pane, dropped on the timeline at the time it landed on.
   *
   *  This is the gesture an editor is for, and until it existed an asset could be dragged out of
   *  the pane and nothing anywhere would take it. */
  const put = useCallback(
    async (asset: string, t: number) => {
      try {
        await bridge.placeAsset(tab.variation, asset, t);
      } catch (e) {
        say("refused", why(e));
      }
    },
    [say, tab.variation],
  );

  const scrub = useCallback(
    (e: React.PointerEvent) => {
      seek(timeFromClient(e.clientX));
      const move = (ev: PointerEvent) => seek(timeFromClient(ev.clientX));
      const up = () => {
        window.removeEventListener("pointermove", move);
        window.removeEventListener("pointerup", up);
        document.body.style.cursor = "";
      };
      window.addEventListener("pointermove", move);
      window.addEventListener("pointerup", up);
      document.body.style.cursor = "ew-resize";
    },
    [seek, timeFromClient],
  );

  // Zoom on the wheel with a modifier, anchored under the pointer — the gesture every timeline
  // has. A plain wheel still scrolls.
  const onWheel = useCallback(
    (e: React.WheelEvent) => {
      if (!(e.ctrlKey || e.metaKey)) return;
      e.preventDefault();
      const el = scroller.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      const px = Math.max(0, e.clientX - r.left - NAME_COL);
      const anchor = (px + el.scrollLeft) / pps;
      const next = zoomStep(pps, -e.deltaY / 240, anchor, px, fit);
      setZoom(next.pps);
      el.scrollLeft = next.scroll;
    },
    [pps, setZoom, fit],
  );

  const marks = ticks(duration, contentW);
  const pinned = useMemo(() => notes(tab.outline), [tab.outline]);
  const zoomed = zoom != null && Math.abs(zoom - fit) > 0.5;
  const anyOpen = all.some((l) => opened.includes(l.node.id));

  return (
    <div
      className="relative flex shrink-0 flex-col border-t bg-[var(--ink-1)]"
      style={{ height, borderColor: "var(--edge-soft)" }}
    >
      <GrabEdge />

      <div
        ref={scroller}
        className={clsx(
          "scroll relative min-h-0 flex-1 transition-colors",
          taking && "bg-[var(--ink-2)] ring-1 ring-inset ring-[var(--move)]",
        )}
        onWheel={onWheel}
        onDragOver={(e) => {
          if (!e.dataTransfer.types.includes(ASSET)) return;
          e.preventDefault();
          e.dataTransfer.dropEffect = "copy";
          setTaking(true);
        }}
        onDragLeave={() => setTaking(false)}
        onDrop={(e) => {
          setTaking(false);
          const asset = e.dataTransfer.getData(ASSET);
          if (!asset) return;
          e.preventDefault();
          void put(asset, timeFromClient(e.clientX));
        }}
      >
        <div className="relative" style={{ width: NAME_COL + contentW }}>
          {/* the ruler and the scale, which stay where they are */}
          <div className="sticky top-0 z-20 flex" style={{ height: RULER_H }}>
            <div
              className="sticky left-0 z-10 flex shrink-0 items-center gap-1 border-b border-r pl-2 pr-1"
              style={{
                width: NAME_COL,
                background: "var(--ink-1)",
                borderColor: "var(--edge-soft)",
              }}
            >
              <Button
                tone="ghost"
                className="!h-[18px] !px-1.5 !text-[10px]"
                title="Show the whole composition"
                onClick={() => {
                  setZoom(null);
                  if (scroller.current) scroller.current.scrollLeft = 0;
                }}
                disabled={!zoomed}
              >
                Fit
              </Button>
              <div className="flex-1" />
              <Button
                tone="ghost"
                className="!h-[18px] !w-[18px] !px-0"
                title="Less time, in more detail"
                onClick={() => setZoom(zoomStep(pps, 1, playhead, pane / 2, fit).pps)}
              >
                <Icon name="zoom-in" />
              </Button>
              <Button
                tone="ghost"
                className="!h-[18px] !w-[18px] !px-0"
                title="More time"
                onClick={() => setZoom(zoomStep(pps, -1, playhead, pane / 2, fit).pps)}
              >
                <Icon name="zoom-out" />
              </Button>
            </div>
            <div
              ref={timeArea}
              className="relative cursor-ew-resize border-b"
              style={{ width: contentW, background: "var(--ink-1)", borderColor: "var(--edge-soft)" }}
              onPointerDown={scrub}
            >
              {marks.map((t) => (
                <div key={t} className="absolute bottom-0 top-0 flex items-end" style={{ left: t * pps }}>
                  <span className="h-[7px] w-px" style={{ background: "var(--edge)" }} aria-hidden />
                  <span className="tnum pl-1 text-[9.5px] leading-none text-[var(--text-3)]">
                    {fmt.seconds(t)}
                  </span>
                </div>
              ))}

              {/* Notes, where every editor puts them. On the ruler they read as "something
                  happens here" rather than "something is here", which is what they mean. */}
              {pinned.map((note) => (
                <Note
                  key={note.id}
                  note={note}
                  pps={pps}
                  variation={tab.variation}
                  onSeek={seek}
                  onSay={say}
                />
              ))}
            </div>
          </div>

          {all.length === 0 ? (
            <div className="sticky left-0 py-5" style={{ width: NAME_COL + pane }}>
              <Empty
                title="Nothing in this composition yet"
                hint="Ask on the right for what you want, or drop footage in from the left."
              />
            </div>
          ) : null}

          {all.map((lane, i) => (
            <LaneRow
              key={lane.node.id}
              lane={lane}
              soundStarts={lane.group === "sound" && all[i - 1]?.group !== "sound"}
              contentW={contentW}
              pps={pps}
              tab={tab}
              open={opened.includes(lane.node.id)}
              selected={selection.node === lane.node.id}
              selectedProp={selection.node === lane.node.id ? selection.prop : undefined}
              onToggle={() => toggleLane(lane.node.id)}
              onSelect={select}
              onSay={say}
              onScrub={scrub}
              stack={all}
            />
          ))}

          <Playhead t={playhead} pps={pps} grab={scrub} />
        </div>
      </div>

      <Footer
        lanes={all}
        legend={anyOpen}
        stride={tab.outline.comp?.onscreen_stride ?? 1}
        cli={tab.outline.cli_only}
      />
    </div>
  );
}

function Footer({
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
function SoundDivider({ width }: { width: number }) {
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

function Playhead({
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
function Note({
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
function Gap({
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

function LaneRow({
  lane,
  soundStarts,
  contentW,
  pps,
  tab,
  open,
  selected,
  selectedProp,
  onToggle,
  onSelect,
  onSay,
  onScrub,
  stack,
}: {
  lane: Lane;
  soundStarts: boolean;
  contentW: number;
  pps: number;
  tab: Tab;
  open: boolean;
  selected: boolean;
  selectedProp?: string;
  onToggle: () => void;
  onSelect: (s: { node: string; prop?: string; occurrence?: number }) => void;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
  onScrub: (e: React.PointerEvent) => void;
  /** Every lane, which is what one step up or down the stack is measured against. */
  stack: Lane[];
}) {
  const bg = selected ? "var(--ink-2)" : undefined;

  return (
    <>
      {soundStarts ? <SoundDivider width={contentW} /> : null}
      <div
        className={clsx("group flex border-b", !selected && "hover:bg-[var(--ink-2)]/40")}
        style={{ borderColor: "var(--edge-soft)", background: bg }}
      >
        {/* the name, which stays put while time scrolls */}
        <div
          className="sticky left-0 z-10 flex shrink-0 flex-col border-r"
          style={{
            width: NAME_COL,
            background: selected ? "var(--ink-2)" : "var(--ink-1)",
            borderColor: "var(--edge-soft)",
          }}
        >
          <div
            className="relative flex items-center"
            style={{ height: LANE_H, paddingLeft: 6 + lane.depth * 11 }}
          >
            <button
              type="button"
              className="flex h-[16px] w-[14px] shrink-0 items-center justify-center text-[var(--text-3)] hover:text-[var(--text-1)] disabled:opacity-0"
              onClick={onToggle}
              disabled={lane.rows.length === 0}
              aria-expanded={open}
              title={open ? "Hide what changes over time" : "Show what changes over time"}
            >
              <Icon name={open ? "caret-down" : "caret-right"} />
            </button>
            <LaneName
              lane={lane}
              variation={tab.variation}
              onSelect={() => onSelect({ node: lane.node.id })}
              onSay={onSay}
            />
            <Stack
              lane={lane}
              stack={stack}
              variation={tab.variation}
              onSay={onSay}
              background={selected ? "var(--ink-2)" : "var(--ink-1)"}
            />
          </div>
          {open
            ? lane.rows.map((row) => (
                <button
                  key={row.prop}
                  type="button"
                  className={clsx(
                    "flex items-center truncate pr-2 text-left text-[10.5px]",
                    selectedProp === row.prop ? "text-[var(--text-1)]" : "text-[var(--text-2)]",
                  )}
                  style={{ height: ROW_H, paddingLeft: 26 + lane.depth * 11 }}
                  onClick={() => onSelect({ node: lane.node.id, prop: row.prop })}
                >
                  {row.name}
                </button>
              ))
            : null}
        </div>

        {/* the time */}
        <div style={{ width: contentW }}>
          <div
            className="relative"
            style={{ height: LANE_H }}
            onPointerDown={(e) => {
              // The empty part of a lane belongs to the transport, as it does everywhere else.
              if (e.currentTarget === e.target) onScrub(e);
            }}
          >
            {lane.clips.length === 0 ? (
              <span className="absolute left-2 top-1/2 -translate-y-1/2 text-[10px] text-[var(--text-3)]">
                never on screen
              </span>
            ) : null}

            {lane.clips.map((clip, i) => (
              <ClipBar
                key={i}
                clip={clip}
                pps={pps}
                lane={lane}
                open={open}
                selected={selected}
                variation={tab.variation}
                onSelect={() => onSelect({ node: lane.node.id })}
                onSay={onSay}
                stack={stack}
                duration={tab.meta.duration}
              />
            ))}

            {/* The hole after it, and the one way to close it that you can see. Only on the
                thing you have picked: a timeline that drew every gap in the composition at once
                would be a timeline of holes. */}
            {selected ? (
              <Gap lane={lane} stack={stack} pps={pps} tab={tab} onSay={onSay} />
            ) : null}

            {/* a spoken line is part of the clip, because it is what the clip is made of */}
            {lane.cues.map((c) => (
              <div
                key={`${c.node}-${c.index}`}
                className="absolute top-1/2 flex h-[18px] -translate-y-1/2 items-center overflow-hidden rounded-[3px] px-1.5"
                style={{
                  left: c.t0 * pps,
                  width: Math.max(3, (c.t1 - c.t0) * pps),
                  background: "color-mix(in oklab, var(--said) 22%, var(--ink-2))",
                  boxShadow: "inset 1.5px 0 0 var(--said)",
                }}
                title={`“${c.text}” — ${fmt.seconds(c.t0)} to ${fmt.seconds(c.t1)}`}
                onPointerDown={(e) => {
                  e.stopPropagation();
                  onSelect({ node: c.node });
                }}
              >
                <span className="truncate text-[10.5px] text-[var(--text-1)]">{c.text}</span>
              </div>
            ))}

            {/* Said on the lane as well as on the clip: a clip twelve seconds into a ten minute
                edit is off the side of the pane, and "why is this grey" is a question you ask
                while looking at the picture, not while looking at four minutes in. */}
            {lane.offline ? (
              <span
                className="pointer-events-none absolute left-2 top-1/2 z-[2] -translate-y-1/2 rounded px-1 text-[9.5px]"
                style={{ background: "var(--ink-3)", color: "var(--warn)" }}
              >
                offline
              </span>
            ) : null}

            {lane.unpaintable ? (
              <span
                className="absolute left-2 top-1/2 -translate-y-1/2 rounded px-1 text-[9.5px]"
                style={{ background: "var(--ink-3)", color: "var(--warn)" }}
                title={`${lane.unpaintable} — this renders from the command line only`}
              >
                command line only
              </span>
            ) : null}
          </div>

          {open
            ? lane.rows.map((row) => (
                <PropRow
                  key={row.prop}
                  row={row}
                  pps={pps}
                  tab={tab}
                  node={lane.node.id}
                  selected={selectedProp === row.prop}
                  onSelect={onSelect}
                  onSay={onSay}
                  onScrub={onScrub}
                />
              ))
            : null}
        </div>
      </div>
    </>
  );
}

/** A hint of kind, on the clip. Sound and spoken lines already have their own colours elsewhere
 *  in the app; these are the same ones, so nothing has to be learned twice. */
const TINT: Record<string, string> = {
  sound: "var(--sound)",
  text: "var(--said)",
  video: "var(--move)",
  image: "var(--move)",
};

function iconFor(lane: Lane): "audio" | "words" | "footage" | "image" | "shape" {
  if (lane.group === "sound") return "audio";
  if (lane.node.kind === "text") return "words";
  if (lane.node.kind === "video") return "footage";
  if (lane.node.kind === "image") return "image";
  return "shape";
}

/** One stretch of time a thing is on screen.
 *
 *  While the lane is closed, the keyframes inside that stretch are drawn along its lower edge:
 *  present and countable, without pretending to be legible at two pixels. Open the lane to work
 *  on them. */
function ClipBar({
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
function LaneName({
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

/** Up and down the stack, on the lane itself.
 *
 *  What paints over what is the one thing a layer list is *for*, and it had no handle at all —
 *  only the bracket keys, which is a feature nobody can see. Two arrows, on the row, where the
 *  thing they move is. They are there only when there is somewhere to go, so an arrow that does
 *  nothing is never offered. */
function Stack({
  lane,
  stack,
  variation,
  onSay,
  background,
}: {
  lane: Lane;
  stack: Lane[];
  variation: string;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
  /** What the row is, so the arrows can sit over the end of a long name instead of shortening
   *  the column every time the pointer crosses it. */
  background: string;
}) {
  const up = restep(stack, lane.node.id, "forward");
  const down = restep(stack, lane.node.id, "back");
  if (!up && !down) return null;

  const go = async (step: { node: string; over: string | null }) => {
    try {
      const moved = await bridge.gesture(variation, { gesture: "restack", ...step });
      if (moved.what[0]) onSay("said", moved.what[0]);
    } catch (err) {
      onSay("refused", why(err));
    }
  };

  return (
    <span
      className="absolute right-0 top-1/2 flex -translate-y-1/2 pl-2 pr-1 opacity-0 transition-opacity focus-within:opacity-100 group-hover:opacity-100"
      style={{ background: `linear-gradient(to right, transparent, ${background} 8px)` }}
    >
      {([["forward", up, "Bring it forward"], ["back", down, "Send it back"]] as const).map(
        ([dir, step, title]) =>
          step ? (
            <button
              key={dir}
              type="button"
              title={title}
              aria-label={title}
              className="flex h-[16px] w-[13px] items-center justify-center text-[var(--text-3)] hover:text-[var(--text-1)]"
              onClick={(e) => {
                e.stopPropagation();
                void go(step);
              }}
            >
              <Icon
                name={dir === "forward" ? "caret-up-small" : "caret-down-small"}
                className="h-[9px] w-[9px]"
              />
            </button>
          ) : (
            <span key={dir} className="h-[16px] w-[13px]" />
          ),
      )}
    </span>
  );
}

/** One property of one thing, over time: its movements and its pins. */
function PropRow({
  row,
  pps,
  tab,
  node,
  selected,
  onSelect,
  onSay,
  onScrub,
}: {
  row: Row;
  pps: number;
  tab: Tab;
  node: string;
  selected: boolean;
  onSelect: (s: { node: string; prop?: string; occurrence?: number }) => void;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
  onScrub: (e: React.PointerEvent) => void;
}) {
  return (
    <div
      className="relative"
      data-band
      style={{ height: ROW_H }}
      onPointerDown={(e) => {
        if (e.currentTarget === e.target) onScrub(e);
      }}
    >
      <div
        className="pointer-events-none absolute left-0 right-0 top-1/2 h-px -translate-y-1/2"
        style={{ background: "var(--edge-soft)" }}
        aria-hidden
      />
      {row.bars.map((bar) => (
        <Movement
          key={`${bar.prop}-${bar.occurrence}-${bar.t0}`}
          bar={bar}
          pps={pps}
          tab={tab}
          node={node}
          selected={selected}
          onSelect={() => onSelect({ node, prop: bar.prop, occurrence: bar.occurrence })}
          onSay={onSay}
        />
      ))}
      {row.marks.map((m) => (
        <div
          key={`${m.prop}-${m.t}`}
          role="button"
          tabIndex={0}
          aria-label={`${row.name} set by hand at ${fmt.seconds(m.t)}`}
          title={`${row.name} set by hand at ${fmt.seconds(m.t)} — ${fmt.value(m.segment.to)}`}
          className="absolute top-1/2 h-[9px] w-[9px] -translate-x-1/2 -translate-y-1/2 rotate-45 rounded-[1.5px] transition-transform hover:scale-125"
          style={{
            left: m.t * pps,
            background: "var(--pin)",
            boxShadow: "0 0 0 2px var(--ink-1)",
          }}
          onPointerDown={(e) => {
            e.stopPropagation();
            onSelect({ node, prop: m.prop });
          }}
        />
      ))}
    </div>
  );
}

function Movement({
  bar,
  pps,
  tab,
  node,
  selected,
  onSelect,
  onSay,
}: {
  bar: Bar;
  pps: number;
  tab: Tab;
  node: string;
  selected: boolean;
  onSelect: () => void;
  onSay: (tone: "said" | "refused" | "working", text: string) => void;
}) {
  const [ghost, setGhost] = useState<number | null>(null);
  /** Where the left edge is being dragged to, while it is being dragged. */
  const [ghostStart, setGhostStart] = useState<number | null>(null);
  const shown = ghost ?? bar.t1;
  const begins = ghostStart ?? bar.t0;

  /** A drag along this band, in seconds on the grid. Shared by both edges: the band's own left
   *  edge is time zero and one second is `pps` pixels of it, at whatever scale is showing. */
  const dragging = (
    e: React.PointerEvent,
    floor: number,
    show: (t: number) => void,
    land: (t: number) => Promise<void>,
  ) => {
    const band = (e.currentTarget as HTMLElement).closest("[data-band]") as HTMLElement | null;
    if (!band) return;
    const rect = band.getBoundingClientRect();
    const fps = tab.meta.fps;
    const at = (clientX: number) => {
      const t = (clientX - rect.left) / pps;
      const snapped = fps > 0 ? Math.round(t * fps) / fps : t;
      return Math.max(floor, snapped);
    };
    const move = (ev: PointerEvent) => show(at(ev.clientX));
    const up = async (ev: PointerEvent) => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      const t = at(ev.clientX);
      show(NaN); // clears the ghost; the real answer arrives as a new outline
      await land(t);
    };
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };
  const curve = easeShape(bar.segment.ease);
  const path = curve.map((v, i) => `${(i / (curve.length - 1)) * 100},${(1 - v) * 100}`).join(" ");

  return (
    <div
      role="button"
      tabIndex={0}
      aria-label={`${fmt.property(bar.prop)} moves, ${fmt.curve(bar.segment.ease)}`}
      title={`${fmt.property(bar.prop)}: ${fmt.value(bar.segment.from)} → ${fmt.value(
        bar.segment.to,
      )} over ${fmt.seconds(bar.t1 - bar.t0)}, ${fmt.curve(bar.segment.ease)}`}
      className={clsx(
        "absolute top-1/2 flex h-[14px] -translate-y-1/2 items-stretch overflow-hidden rounded-[3px]",
        selected && "ring-[1.5px] ring-[var(--text-1)]",
      )}
      style={{
        left: begins * pps,
        width: Math.max(3, (shown - begins) * pps),
        background: "color-mix(in oklab, var(--move) 26%, transparent)",
        boxShadow: "inset 1.5px 0 0 var(--move)",
      }}
      onPointerDown={(e) => {
        e.stopPropagation();
        onSelect();
      }}
    >
      <svg
        viewBox="0 0 100 100"
        preserveAspectRatio="none"
        className="pointer-events-none h-full w-full"
        aria-hidden
      >
        <polyline
          points={path}
          fill="none"
          stroke="var(--move)"
          strokeWidth="6"
          vectorEffect="non-scaling-stroke"
          strokeLinecap="round"
        />
      </svg>

      {/* Both edges move it now. The left one moves when it begins, which in a script is the
          wait in front of it -- so what comes after in the same run moves with it, the same way
          it does when a movement is made longer. */}
      <span
        role="button"
        tabIndex={-1}
        aria-label="Move when this starts"
        title="Drag to move when this starts — what follows it moves with it"
        className="absolute inset-y-0 left-0 z-[1] w-[5px] cursor-ew-resize"
        onPointerDown={(e) => {
          e.stopPropagation();
          onSelect();
          dragging(
            e,
            0,
            (t) => setGhostStart(Number.isNaN(t) ? null : Math.min(t, bar.t1 - 0.01)),
            async (t) => {
              if (Math.abs(t - bar.t0) < 0.005) return;
              try {
                await bridge.gesture(tab.variation, {
                  gesture: "move_start",
                  node,
                  t,
                  occurrence: bar.occurrence,
                });
              } catch (err) {
                onSay("refused", why(err));
              }
            },
          );
        }}
      />
      <span
        role="button"
        tabIndex={-1}
        aria-label="Make this movement longer or shorter"
        className="absolute inset-y-0 right-0 w-[6px] cursor-ew-resize"
        onPointerDown={(e) => {
          e.stopPropagation();
          dragging(
            e,
            bar.t0 + (tab.meta.fps > 0 ? 1 / tab.meta.fps : 0.01),
            (t) => setGhost(Number.isNaN(t) ? null : t),
            async (t) => {
              const seconds = Math.round((t - bar.t0) * 100) / 100;
              if (Math.abs(seconds - (bar.t1 - bar.t0)) < 0.005) return;
              try {
                await bridge.gesture(tab.variation, {
                  gesture: "lengthen",
                  node,
                  seconds,
                  occurrence: bar.occurrence,
                });
              } catch (err) {
                onSay("refused", why(err));
              }
            },
          );
        }}
      />
    </div>
  );
}
/** The bar under the timeline that says what is selected and lets it be changed. */

