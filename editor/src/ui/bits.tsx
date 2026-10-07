// The small pieces. Few, plain, and none of them a framework.

import clsx from "clsx";
import type { ReactNode } from "react";

// The icon set lives in icons.tsx; Icon and IconName stay importable from here.
export { Icon, type IconName } from "./icons";

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
