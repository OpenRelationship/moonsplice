import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import clsx from "clsx";
import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { useStudio, type Tab } from "../state";
import { Button, Empty, Icon } from "../ui/bits";
import { fitZoom, lanes, notes, ticks, zoomStep } from "./lanes";
import { LaneRow } from "./LaneRow";
import { Footer, Note, Playhead } from "./marks";
import { ASSET, NAME_COL, RULER_H } from "./sizes";

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
export function Lanes({ tab, height }: { tab: Tab; height: number }) {
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
