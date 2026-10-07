// What the selected thing is, and what can be done to it.
//
// This used to be a strip across the top of the timeline: one row, every property in it, scrolling
// sideways. A row is the wrong shape for this — it has no room to group anything, so "Across" sat
// next to "Blur" as if they were the same kind of thing, and it took height from the timeline and
// the picture, which are what a person is actually looking at.
//
// So it is a panel beside the project, and it follows whatever is selected — in the picture or in
// the timeline, they are the same selection. Nothing selected is not an empty panel: it is every
// effect this app knows, collapsed, with a search over them, so "what can this do?" has an answer
// that does not require picking something first.

import { useMemo, useState, type ReactNode } from "react";
import clsx from "clsx";

import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { useInstant, valueNow } from "../instant";
import { activeTab, useStudio } from "../state";
import { easeShape } from "../timeline/lanes";
import { Empty, Icon } from "../ui/bits";
import { DOES, effectsOn, matching, sections } from "./what";

export function Effects() {
  const tab = useStudio((s) => activeTab(s));
  const selection = useStudio((s) => s.selection);
  const playhead = useStudio((s) => s.playhead);
  const playing = useStudio((s) => s.playing);
  const say = useStudio((s) => s.say);
  const instant = useInstant(tab?.variation ?? null, tab?.hash ?? null, playhead, !playing);
  const [shut, setShut] = useState<string[]>(["Effects"]);
  const [find, setFind] = useState("");

  const node = tab?.outline.nodes.find((n) => n.id === selection.node) ?? null;

  const tracks = useMemo(
    () => (tab && node ? tab.outline.tracks.filter((t) => t.node === node.id) : []),
    [tab, node],
  );

  if (!tab || !node) return <Catalogue find={find} setFind={setFind} />;

  const name = fmt.names(tab.outline.nodes).get(node.id) ?? fmt.nodeName(node);
  const movement = selection.prop
    ? tracks.find((t) => t.prop === selection.prop)
    : tracks.find((t) => t.segments.some((s) => !s.manual));
  const segment = movement?.segments[selection.occurrence ?? 0] ?? movement?.segments[0];

  // Which properties a movement decides. Those are not yours to type over: the number in the
  // constructor is where the movement *starts*, and typing the value you can see into it would
  // move the start instead. So they read what they are now, and the way to change them is the
  // movement itself — its curve, its length, or a pin.
  const driven = new Set(tracks.map((t) => t.prop));
  const effects = effectsOn(node.props);

  const set = async (key: string, value: number | string | boolean) => {
    try {
      await bridge.gesture(tab.variation, { gesture: "set_value", node: node.id, key, value });
    } catch (e) {
      say("refused", why(e));
    }
  };

  const pin = async (key: string, value: number) => {
    try {
      await bridge.gesture(tab.variation, { gesture: "pin", node: node.id, t: playhead, key, value });
      say("said", `Pinned ${fmt.property(key).toLowerCase()} at ${fmt.timecode(playhead)}`);
    } catch (e) {
      say("refused", why(e));
    }
  };

  const field = (key: string) => {
    const written = node.props?.[key];
    const moves = driven.has(key);
    const now = moves ? valueNow(instant, node.id, key) : undefined;
    const v = moves && now !== undefined ? now : written;
    return (
      <Field
        key={key}
        label={fmt.property(key)}
        value={v}
        moved={moves}
        onCommit={(next) => void set(key, next)}
        onPin={typeof v === "number" ? () => void pin(key, Number(v)) : undefined}
      />
    );
  };

  const toggle = (title: string) =>
    setShut((s) => (s.includes(title) ? s.filter((x) => x !== title) : [...s, title]));

  return (
    <div className="scroll min-h-0 flex-1">
      <div className="flex items-baseline gap-2 px-3 pb-2 pt-2.5">
        <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium text-[var(--text-1)]">
          {name}
        </span>
        {/* "Block 1  Block" says one thing twice. The kind is only worth saying when the name
            came from somewhere else. */}
        {name.startsWith(fmt.kind(node.kind)) ? null : (
          <span className="shrink-0 text-[10.5px] text-[var(--text-3)]">{fmt.kind(node.kind)}</span>
        )}
      </div>

      {sections(node.props).map((g) => (
        <Section
          key={g.title}
          title={g.title}
          shut={shut.includes(g.title)}
          onToggle={() => toggle(g.title)}
        >
          {g.keys.map(field)}
        </Section>
      ))}

      {segment && movement && !segment.manual ? (
        <Section
          title="Movement"
          note={fmt.curve(segment.ease)}
          shut={shut.includes("Movement")}
          onToggle={() => toggle("Movement")}
        >
          <Curves
            ease={segment.ease ?? "linear"}
            onPick={async (c) => {
              try {
                await bridge.gesture(tab.variation, {
                  gesture: "curve",
                  node: node.id,
                  ease: c,
                  occurrence: selection.occurrence ?? 0,
                });
              } catch (e) {
                say("refused", why(e));
              }
            }}
          />
          <p className="px-1 pt-1 text-[10.5px] text-[var(--text-3)]">
            {fmt.property(movement.prop).toLowerCase()}, {fmt.seconds(segment.t1 - segment.t0)}{" "}
            from {fmt.seconds(segment.t0)}
          </p>
        </Section>
      ) : null}

      <Section
        title="Effects"
        note={effects.busy > 0 ? `${effects.busy} on` : undefined}
        shut={shut.includes("Effects")}
        onToggle={() => toggle("Effects")}
      >
        {effects.keys.map(field)}
        {effects.keys.length === 0 ? (
          <p className="px-1 text-[11px] text-[var(--text-3)]">
            Nothing on this one takes an effect.
          </p>
        ) : null}
      </Section>
    </div>
  );
}

/** Nothing is selected: every effect there is, collapsed, and a way to find one. */
function Catalogue({ find, setFind }: { find: string; setFind: (s: string) => void }) {
  const project = useStudio((s) => s.project);
  const shown = matching(find);

  return (
    <div className="scroll min-h-0 flex-1">
      {project ? (
        <>
          <div className="px-2 pb-1 pt-2">
            <input
              value={find}
              onChange={(e) => setFind(e.target.value)}
              placeholder="Search effects"
              className="w-full rounded-[var(--radius-sm)] border px-2 py-1 text-[12px] outline-none"
              style={{
                background: "var(--ink-0)",
                borderColor: "var(--edge)",
                color: "var(--text-1)",
              }}
            />
          </div>
          <p className="px-3 pb-2 text-[11px] text-[var(--text-3)]">
            Pick something in the picture or the timeline to change it.
          </p>
          <ul className="px-1.5 pb-4">
            {shown.map((k) => (
              <CatalogueRow key={k} effect={k} />
            ))}
            {shown.length === 0 ? (
              <li className="px-2 py-1 text-[12px] text-[var(--text-3)]">
                Nothing by that name.
              </li>
            ) : null}
          </ul>
        </>
      ) : (
        <Empty title="No project open" hint="Open a folder to start." />
      )}
    </div>
  );
}

/** One effect in the catalogue: shut, and it opens onto what it does. */
function CatalogueRow({ effect }: { effect: string }) {
  const [open, setOpen] = useState(false);
  return (
    <li>
      <button
        type="button"
        onClick={() => setOpen((o) => !o)}
        aria-expanded={open}
        className="flex w-full items-center gap-1.5 rounded-[var(--radius-sm)] px-2 py-[5px] text-left text-[12.5px] text-[var(--text-2)] hover:bg-[var(--ink-2)]"
      >
        <Icon
          name={open ? "caret-down" : "caret-right"}
          className="h-3 w-3 shrink-0 text-[var(--text-3)]"
        />
        <span className="min-w-0 flex-1 truncate">{fmt.property(effect)}</span>
      </button>
      {open ? (
        <p className="pb-1.5 pl-[30px] pr-2 text-[11px] leading-[1.45] text-[var(--text-3)]">
          {DOES[effect] ?? "No description yet."}
        </p>
      ) : null}
    </li>
  );
}

function Section({
  title,
  note,
  shut,
  onToggle,
  children,
}: {
  title: string;
  note?: string;
  shut: boolean;
  onToggle: () => void;
  children: ReactNode;
}) {
  return (
    <div className="border-t" style={{ borderColor: "var(--edge-soft)" }}>
      <button
        type="button"
        onClick={onToggle}
        className="flex w-full items-center gap-1.5 px-2 py-[6px] text-left hover:bg-[var(--ink-2)]"
      >
        <Icon
          name={shut ? "caret-right" : "caret-down"}
          className="h-3 w-3 shrink-0 text-[var(--text-3)]"
        />
        <span className="min-w-0 flex-1 truncate text-[11px] font-medium uppercase tracking-[0.06em] text-[var(--text-3)]">
          {title}
        </span>
        {note ? <span className="shrink-0 text-[10.5px] text-[var(--text-3)]">{note}</span> : null}
      </button>
      {shut ? null : <div className="flex flex-col gap-1 px-2 pb-2">{children}</div>}
    </div>
  );
}

function Curves({ ease, onPick }: { ease: string; onPick: (c: string) => void }) {
  return (
    <div className="flex flex-col">
      {fmt.CURVES.map((c) => (
        <button
          key={c}
          type="button"
          className={clsx(
            "flex w-full items-center justify-between rounded-[var(--radius-sm)] px-1.5 py-1 text-left text-[12px] hover:bg-[var(--ink-3)]",
            ease === c ? "text-[var(--move)]" : "text-[var(--text-2)]",
          )}
          onClick={() => onPick(c)}
        >
          <span>{fmt.curve(c)}</span>
          <Sparkline ease={c} />
        </button>
      ))}
    </div>
  );
}

function Sparkline({ ease }: { ease: string }) {
  const pts = easeShape(ease)
    .map((v, i, a) => `${(i / (a.length - 1)) * 28},${14 - v * 12}`)
    .join(" ");
  return (
    <svg width="28" height="14" viewBox="0 0 28 14" aria-hidden className="shrink-0">
      <polyline points={pts} fill="none" stroke="var(--move)" strokeWidth="1.4" />
    </svg>
  );
}

/** One property: what it is, and the two things you can do to it. */
function Field({
  label,
  value,
  moved,
  onCommit,
  onPin,
}: {
  label: string;
  value: unknown;
  /** A movement decides this one, so it shows what it is now and cannot be typed into. */
  moved?: boolean;
  onCommit: (v: number | string | boolean) => void;
  onPin?: () => void;
}) {
  const [draft, setDraft] = useState<string | null>(null);
  const shown = draft ?? fmt.value(value);
  const colour = fmt.swatch(value);

  return (
    <span
      className="flex items-center gap-1 rounded-[var(--radius-sm)] bg-[var(--ink-3)] pl-2 pr-1"
      title={moved ? `${label} is decided by a movement here` : undefined}
    >
      {moved ? (
        <span
          className="h-[5px] w-[5px] shrink-0 rounded-full bg-[var(--move)]"
          aria-label="a movement decides this"
        />
      ) : null}
      <span className="min-w-0 flex-1 truncate text-[10.5px] text-[var(--text-3)]">{label}</span>
      {colour ? (
        <span
          className="h-[13px] w-[13px] shrink-0 rounded-[3px] ring-1 ring-inset ring-black/25"
          style={{ background: colour }}
        />
      ) : (
        <input
          readOnly={moved}
          className={clsx(
            "tnum w-[60px] shrink-0 bg-transparent py-1 text-right text-[12px] outline-none",
            moved ? "cursor-default text-[var(--move)]" : "text-[var(--text-1)]",
          )}
          value={shown}
          onChange={(e) => setDraft(e.target.value)}
          onBlur={() => {
            if (draft == null) return;
            const n = Number(draft);
            onCommit(Number.isFinite(n) && draft.trim() !== "" ? n : draft);
            setDraft(null);
          }}
          onKeyDown={(e) => {
            if (e.key === "Enter") e.currentTarget.blur();
            if (e.key === "Escape") {
              setDraft(null);
              e.currentTarget.blur();
            }
          }}
        />
      )}
      {onPin ? (
        <button
          type="button"
          title={`Set ${label} by hand at the playhead`}
          aria-label={`Set ${label} by hand at the playhead`}
          className="shrink-0 rounded p-1 text-[var(--text-3)] transition-colors hover:text-[var(--pin)]"
          onClick={onPin}
        >
          <span className="block h-[7px] w-[7px] rotate-45 rounded-[1px] bg-current" />
        </button>
      ) : null}
    </span>
  );
}
