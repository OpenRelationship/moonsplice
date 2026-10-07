import clsx from "clsx";
import * as fmt from "../format";
import { type Tab } from "../state";
import { Icon } from "../ui/bits";
import { type Lane } from "./lanes";
import { ClipBar, LaneName } from "./ClipBar";
import { Gap, SoundDivider } from "./marks";
import { PropRow, Stack } from "./props";
import { LANE_H, NAME_COL, ROW_H } from "./sizes";

export function LaneRow({
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
export const TINT: Record<string, string> = {
  sound: "var(--sound)",
  text: "var(--said)",
  video: "var(--move)",
  image: "var(--move)",
};

export function iconFor(lane: Lane): "audio" | "words" | "footage" | "image" | "shape" {
  if (lane.group === "sound") return "audio";
  if (lane.node.kind === "text") return "words";
  if (lane.node.kind === "video") return "footage";
  if (lane.node.kind === "image") return "image";
  return "shape";
}
