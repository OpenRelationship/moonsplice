// The left side: the project, or what the selected thing can do. Two tabs, because they answer
// two different questions and a person is only ever asking one of them.

import clsx from "clsx";

import { Effects } from "./effects/Effects";
import { Library } from "./library/Library";
import { useStudio } from "./state";

export function Sidebar({ onOpen }: { onOpen: (variation: string) => void }) {
  const which = useStudio((s) => s.sidebar);
  const show = useStudio((s) => s.setSidebar);
  const selected = useStudio((s) => s.selection.node);

  return (
    <aside className="flex w-[244px] shrink-0 flex-col border-r bg-[var(--ink-1)]">
      <div
        className="flex h-[30px] shrink-0 items-stretch gap-0.5 border-b px-1.5"
        style={{ borderColor: "var(--edge-soft)" }}
      >
        {(["project", "effects"] as const).map((t) => (
          <button
            key={t}
            type="button"
            onClick={() => show(t)}
            className={clsx(
              "relative flex flex-1 items-center justify-center gap-1.5 rounded-t-[var(--radius-sm)] text-[11.5px] transition-colors",
              which === t
                ? "text-[var(--text-1)]"
                : "text-[var(--text-3)] hover:text-[var(--text-2)]",
            )}
          >
            {which === t ? (
              <span
                className="absolute inset-x-1 bottom-0 h-[2px] rounded-full"
                style={{ background: "var(--move)" }}
                aria-hidden
              />
            ) : null}
            <span>{t === "project" ? "Project" : "Effects"}</span>
            {/* A quiet dot when something is selected and you are not looking at it: the panel
                has something to say and the tab is the only place to say so. */}
            {t === "effects" && which !== "effects" && selected ? (
              <span
                className="h-[5px] w-[5px] rounded-full"
                style={{ background: "var(--move)" }}
                aria-label="something is selected"
              />
            ) : null}
          </button>
        ))}
      </div>

      {which === "project" ? <Library onOpen={onOpen} /> : <Effects />}
    </aside>
  );
}
