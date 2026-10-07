// The small pieces. Few, plain, and none of them a framework.

import clsx from "clsx";
import type { ReactNode } from "react";

export function Button({
  children,
  onClick,
  tone = "quiet",
  title,
  disabled,
  className,
}: {
  children: ReactNode;
  onClick?: () => void;
  tone?: "quiet" | "solid" | "ghost" | "danger";
  title?: string;
  disabled?: boolean;
  className?: string;
}) {
  return (
    <button
      type="button"
      title={title}
      aria-label={title}
      disabled={disabled}
      onClick={onClick}
      className={clsx(
        "inline-flex select-none items-center gap-1.5 rounded-[var(--radius-sm)] px-2.5 py-1.5",
        "text-[12.5px] font-medium transition-colors duration-100 disabled:opacity-40",
        tone === "solid" &&
          "bg-[var(--move)] text-[var(--ink-0)] hover:brightness-110 disabled:hover:brightness-100",
        tone === "quiet" &&
          "bg-[var(--ink-3)] text-[var(--text-1)] hover:bg-[var(--ink-4)] disabled:hover:bg-[var(--ink-3)]",
        tone === "ghost" && "text-[var(--text-2)] hover:bg-[var(--ink-3)] hover:text-[var(--text-1)]",
        tone === "danger" && "text-[var(--warn)] hover:bg-[var(--ink-3)]",
        className,
      )}
    >
      {children}
    </button>
  );
}

/** A heading for a group in a pane. Quiet: the content is the thing, not the label. */
export function GroupLabel({ children, right }: { children: ReactNode; right?: ReactNode }) {
  return (
    <div className="flex items-center justify-between px-3 pb-1 pt-3">
      <span className="text-[10.5px] font-semibold uppercase tracking-[0.09em] text-[var(--text-3)]">
        {children}
      </span>
      {right}
    </div>
  );
}

/** What a pane says when there is nothing in it. Never blank, never an error. */
export function Empty({
  title,
  hint,
  action,
}: {
  title: string;
  hint?: string;
  action?: ReactNode;
}) {
  return (
    <div className="flex h-full flex-col items-center justify-center gap-2 px-6 text-center">
      <p className="text-[13px] font-medium text-[var(--text-2)]">{title}</p>
      {hint ? <p className="max-w-[34ch] text-[12px] text-[var(--text-3)]">{hint}</p> : null}
      {action ? <div className="pt-1.5">{action}</div> : null}
    </div>
  );
}

/** What there is to draw. A name, so a row can be handed one. */
export type IconName =
  | "play"
  | "pause"
  | "undo"
  | "redo"
  | "plus"
  | "close"
  | "chevron"
  | "footage"
  | "image"
  | "audio"
  | "font"
  | "data"
  | "other"
  | "words"
  | "shape"
  | "spark"
  | "stop"
  | "send"
  | "sun"
  | "panel-left"
  | "panel-right"
  | "step-back"
  | "step-on"
  | "caret-right"
  | "caret-down"
  | "zoom-in"
  | "zoom-out"
  | "folder"
  | "folder-plus"
  | "comp";

/** The icon set, drawn rather than imported: a handful of glyphs is not a dependency. */
export function Icon({
  name,
  className,
}: {
  name:
    | "play"
    | "pause"
    | "undo"
    | "redo"
    | "plus"
    | "close"
    | "chevron"
    | "footage"
    | "image"
    | "audio"
    | "font"
    | "data"
    | "other"
    | "words"
    | "shape"
    | "spark"
    | "stop"
    | "send"
    | "sun"
    | "panel-left"
    | "panel-right"
    | "step-back"
    | "step-on"
    | "caret-right"
    | "caret-down"
    | "zoom-in"
    | "zoom-out"
    | "folder"
    | "folder-plus"
    | "razor"
    | "sound-off"
    | "sound-low"
    | "sound-high"
    | "caret-up-small"
    | "caret-down-small"
    | "comp";
  className?: string;
}) {
  const cn = clsx("h-[14px] w-[14px] shrink-0", className);
  const stroke = {
    fill: "none",
    stroke: "currentColor",
    strokeWidth: 1.6,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
  };
  switch (name) {
    case "folder":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M2.2 5.2A1.5 1.5 0 0 1 3.7 3.7h2.4l1.2 1.5h5A1.5 1.5 0 0 1 13.8 6.7v4.6a1.5 1.5 0 0 1-1.5 1.5H3.7a1.5 1.5 0 0 1-1.5-1.5z" {...stroke} />
        </svg>
      );
    case "folder-plus":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M2.2 5.2A1.5 1.5 0 0 1 3.7 3.7h2.4l1.2 1.5h5A1.5 1.5 0 0 1 13.8 6.7v4.6a1.5 1.5 0 0 1-1.5 1.5H3.7a1.5 1.5 0 0 1-1.5-1.5z" {...stroke} />
          <path d="M8 7.6v3.2M6.4 9.2h3.2" {...stroke} />
        </svg>
      );
    case "caret-up-small":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M4.4 10 8 6.2 11.6 10" {...stroke} />
        </svg>
      );
    case "caret-down-small":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M4.4 6.2 8 10l3.6-3.8" {...stroke} />
        </svg>
      );
    case "razor":
      // Two blades meeting on a line: the cut, drawn as the thing that makes it.
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M4.6 3.2 11 10.4M11.4 3.2 5 10.4" {...stroke} />
          <circle cx="4.6" cy="12.2" r="1.5" {...stroke} />
          <circle cx="11.4" cy="12.2" r="1.5" {...stroke} />
        </svg>
      );
    case "comp":
      // A frame with a line through it: a composition is a picture that moves.
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="2.4" y="3.6" width="11.2" height="8.8" rx="1.6" {...stroke} />
          <path d="M2.4 9.6h11.2" {...stroke} />
        </svg>
      );
    case "play":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M5 3.4v9.2L12.5 8z" fill="currentColor" />
        </svg>
      );
    case "pause":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M5 3.5h2.2v9H5zM8.8 3.5H11v9H8.8z" fill="currentColor" />
        </svg>
      );
    case "stop":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="4.5" y="4.5" width="7" height="7" rx="1.4" fill="currentColor" />
        </svg>
      );
    case "step-back":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M10.5 3.6v8.8L4.8 8z" fill="currentColor" />
          <path d="M3.4 3.4v9.2" {...stroke} />
        </svg>
      );
    case "step-on":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M5.5 3.6v8.8L11.2 8z" fill="currentColor" />
          <path d="M12.6 3.4v9.2" {...stroke} />
        </svg>
      );
    case "panel-left":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="2.2" y="3" width="11.6" height="10" rx="2" {...stroke} />
          <path d="M6.4 3v10" {...stroke} />
        </svg>
      );
    case "panel-right":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="2.2" y="3" width="11.6" height="10" rx="2" {...stroke} />
          <path d="M9.6 3v10" {...stroke} />
        </svg>
      );
    case "undo":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M3 7h6.2a3.3 3.3 0 1 1 0 6.6H6" {...stroke} />
          <path d="M5.6 4.2 2.9 7l2.7 2.8" {...stroke} />
        </svg>
      );
    case "redo":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M13 7H6.8a3.3 3.3 0 1 0 0 6.6H10" {...stroke} />
          <path d="M10.4 4.2 13.1 7l-2.7 2.8" {...stroke} />
        </svg>
      );
    case "plus":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M8 3.6v8.8M3.6 8h8.8" {...stroke} />
        </svg>
      );
    case "close":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M4.6 4.6l6.8 6.8M11.4 4.6l-6.8 6.8" {...stroke} />
        </svg>
      );
    case "chevron":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M6 4l4 4-4 4" {...stroke} />
        </svg>
      );
    case "send":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M3 8h9M8.6 4.2 12.4 8l-3.8 3.8" {...stroke} />
        </svg>
      );
    case "spark":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path
            d="M8 2.2l1.15 3.3 3.3 1.15-3.3 1.15L8 11.1 6.85 7.8 3.55 6.65l3.3-1.15z"
            fill="currentColor"
          />
          <circle cx="12.3" cy="11.8" r="1.25" fill="currentColor" opacity=".7" />
        </svg>
      );
    case "sun":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <circle cx="8" cy="8" r="2.9" {...stroke} />
          <path d="M8 1.6v1.4M8 13v1.4M1.6 8h1.4M13 8h1.4M3.6 3.6l1 1M11.4 11.4l1 1M12.4 3.6l-1 1M4.6 11.4l-1 1" {...stroke} />
        </svg>
      );
    case "caret-right":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M6.4 4.2l4 3.8-4 3.8z" fill="currentColor" />
        </svg>
      );
    case "caret-down":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M4.2 6.4l3.8 4 3.8-4z" fill="currentColor" />
        </svg>
      );
    case "zoom-in":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <circle cx="7" cy="7" r="4.2" {...stroke} />
          <path d="M10.2 10.2l3.4 3.4M5.1 7h3.8M7 5.1v3.8" {...stroke} />
        </svg>
      );
    case "zoom-out":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <circle cx="7" cy="7" r="4.2" {...stroke} />
          <path d="M10.2 10.2l3.4 3.4M5.1 7h3.8" {...stroke} />
        </svg>
      );
    case "footage":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="2.2" y="4" width="8.2" height="8" rx="1.6" {...stroke} />
          <path d="M10.4 8l3.4-2.1v4.2z" {...stroke} />
        </svg>
      );
    case "image":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="2.2" y="3.2" width="11.6" height="9.6" rx="1.8" {...stroke} />
          <path d="M3 11l3.2-3.2 2.4 2.4 2-2L13 11" {...stroke} />
          <circle cx="6" cy="6.1" r="1" fill="currentColor" />
        </svg>
      );
    // Three states of one glyph. The cone is the same in all of them and only the arcs change,
    // so a glance reads the level without reading the number beside it.
    case "sound-off":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M3 6.2h2.2L8.4 3.6v8.8L5.2 9.8H3z" {...stroke} />
          <path d="M10.8 6.4l3 3.2M13.8 6.4l-3 3.2" {...stroke} />
        </svg>
      );
    case "sound-low":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M3 6.2h2.2L8.4 3.6v8.8L5.2 9.8H3z" {...stroke} />
          <path d="M10.6 6.6a2.4 2.4 0 0 1 0 2.8" {...stroke} />
        </svg>
      );
    case "sound-high":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M3 6.2h2.2L8.4 3.6v8.8L5.2 9.8H3z" {...stroke} />
          <path d="M10.6 6.6a2.4 2.4 0 0 1 0 2.8" {...stroke} />
          <path d="M12.6 4.8a5 5 0 0 1 0 6.4" {...stroke} />
        </svg>
      );
    case "audio":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M3 9.6V6.4M5.6 11.4V4.6M8.2 10V6M10.8 12.2V3.8M13.4 9.4V6.6" {...stroke} />
        </svg>
      );
    case "font":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M4 4h8M8 4v8M6.4 12h3.2" {...stroke} />
        </svg>
      );
    case "data":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="2.6" y="2.6" width="10.8" height="10.8" rx="2" {...stroke} />
          <path d="M5.4 6.4h5.2M5.4 9.4h3.2" {...stroke} />
        </svg>
      );
    case "words":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <path d="M3 4.6h10M3 8h7.4M3 11.4h5" {...stroke} />
        </svg>
      );
    case "shape":
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <rect x="2.6" y="2.6" width="6.4" height="6.4" rx="1.4" {...stroke} />
          <circle cx="10.4" cy="10.4" r="2.9" {...stroke} />
        </svg>
      );
    default:
      return (
        <svg viewBox="0 0 16 16" className={cn} aria-hidden>
          <circle cx="8" cy="8" r="5.2" {...stroke} />
        </svg>
      );
  }
}

/** The legend, said once, where it is needed: a movement is a relation, a pin is a decision. */
export function Distinction({ moves = true, pins = true }: { moves?: boolean; pins?: boolean }) {
  // A key for something that is not on screen teaches nothing and costs a line of attention.
  if (!moves && !pins) return <span />;
  return (
    <div className="flex items-center gap-3 text-[10.5px] text-[var(--text-3)]">
      {moves ? (
        <span className="inline-flex items-center gap-1.5">
          <span
            className="h-[7px] w-[16px] rounded-full"
            style={{ background: "var(--move)" }}
            aria-hidden
          />
          moves
        </span>
      ) : null}
      {pins ? (
        <span className="inline-flex items-center gap-1.5">
          <span
            className="h-[9px] w-[9px] rotate-45 rounded-[1.5px]"
            style={{ background: "var(--pin)" }}
            aria-hidden
          />
          set by hand
        </span>
      ) : null}
    </div>
  );
}
