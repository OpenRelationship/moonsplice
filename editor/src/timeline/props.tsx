import { useState } from "react";
import clsx from "clsx";
import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { type Tab } from "../state";
import { Icon } from "../ui/bits";
import { easeShape, restep, type Bar, type Lane, type Row } from "./lanes";
import { ROW_H } from "./sizes";

/** Up and down the stack, on the lane itself.
 *
 *  What paints over what is the one thing a layer list is *for*, and it had no handle at all —
 *  only the bracket keys, which is a feature nobody can see. Two arrows, on the row, where the
 *  thing they move is. They are there only when there is somewhere to go, so an arrow that does
 *  nothing is never offered. */
export function Stack({
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
export function PropRow({
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
