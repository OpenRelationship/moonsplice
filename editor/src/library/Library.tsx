// The left pane: the project's own folders, and what is in them.
//
// It reads like an editor's project panel, and for the same reasons every editor landed there:
//
//   * **one row per thing you can open.** A composition is one row whether it has a wide cut, a
//     vertical one, or both; which shape you are looking at is chosen above the picture, beside
//     the proportions it changes, not by nesting a second list under every row.
//   * **the folders are yours.** Nothing is grouped by kind. A folder here is a real directory in
//     the project, so making one makes one, renaming one renames it, and dragging a thing into one
//     moves the file. An automatic grouping is somebody else's idea of your project.
//   * **double-click to look.** Footage, a picture or a sound opens in the viewer, the way
//     double-clicking in Premiere or After Effects loads it.
//
// Never a file name, never an extension, never a path. An empty composition is listed like any
// other (`app-shell` scenario 2) — it is a real thing in this app, not a file you have to make
// first. Anything at all can be dropped in (scenario 3); a kind the app does not recognise is
// still an asset, never a refusal.

import { useCallback, useEffect, useRef, useState } from "react";
import clsx from "clsx";
import { getCurrentWebview } from "@tauri-apps/api/webview";

import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { useStudio } from "../state";
import type { AssetKind, AssetView, TreeItem } from "../types";
import { Button, Empty, GroupLabel, Icon, type IconName } from "../ui/bits";

const KIND_ICON: Record<AssetKind, "footage" | "image" | "audio" | "font" | "data" | "other"> = {
  footage: "footage",
  image: "image",
  audio: "audio",
  font: "font",
  data: "data",
  other: "other",
};

const SHAPES: { title: string; w: number; h: number }[] = [
  { title: "Wide", w: 1920, h: 1080 },
  { title: "Vertical", w: 1080, h: 1920 },
  { title: "Square", w: 1080, h: 1080 },
];

/** One thing being dragged inside the pane. */
const MOVE = "text/moonsplice-item";
/** What the timeline listens for. Unchanged, so dropping footage on a lane still works. */
const ASSET = "text/moonsplice-asset";

/** What the window's drag and drop means.
 *
 *  Out here as a function because the gesture is the one part of the app a test cannot perform:
 *  a real drag from the Finder is macOS handing paths to Tauri. Everything after that hand-off
 *  is this, and it is checked — the highlight follows the folder under the cursor, a drop of
 *  nothing does nothing, and a drop of paths adds exactly those, to the folder it landed on.
 *
 *  `folderAt` answers "which folder is under this point", because Tauri's drop carries a position
 *  and not an element. Nothing under it means the pane itself, which is the top of the project. */
export function dragDrop(
  payload: { type: string; paths?: string[]; position?: { x: number; y: number } },
  setOver: (over: string | null) => void,
  drop: (paths: string[], into: string) => void | Promise<void>,
  folderAt?: (p: { x: number; y: number }) => string | null,
): void {
  const where = () => (payload.position && folderAt ? folderAt(payload.position) : null);
  if (payload.type === "over") setOver(where() ?? "");
  else if (payload.type === "leave") setOver(null);
  else if (payload.type === "drop") {
    const into = where() ?? "";
    setOver(null);
    void drop(payload.paths ?? [], into);
  }
}

/** Which folder row is under a point, in the physical pixels Tauri reports. */
export function folderUnder(p: { x: number; y: number }): string | null {
  if (typeof document === "undefined") return null;
  const ratio = typeof window === "undefined" ? 1 : window.devicePixelRatio || 1;
  const el = document.elementFromPoint(p.x / ratio, p.y / ratio);
  const row = (el as Element | null)?.closest("[data-folder]") as HTMLElement | null;
  return row?.dataset.folder ?? null;
}

export function Library({ onOpen }: { onOpen: (variation: string) => void }) {
  const project = useStudio((s) => s.project);
  const active = useStudio((s) => s.active);
  const setProject = useStudio((s) => s.setProject);
  const showSource = useStudio((s) => s.showSource);
  const source = useStudio((s) => s.source);
  const say = useStudio((s) => s.say);
  const [over, setOver] = useState<string | null>(null);
  const [adding, setAdding] = useState(false);
  const [naming, setNaming] = useState<string | null>(null);
  const [closed, setClosed] = useState<string[]>([]);
  /** Which project the folders were last decided for, so opening another one decides again. */
  const decided = useRef<string | null>(null);

  // A folder that would fill the pane starts shut.
  //
  // Everything was open, which is right for the project with six things in it and wrong for the
  // one that has seventy sounds in a folder called Sound: the pane was a list of narration lines
  // and nothing else -- no footage, no compositions, not even the folders they were in, because
  // all of that had been pushed past the bottom of a window. A small project still opens showing
  // everything, which is the whole reason it was open by default; a big one opens showing what
  // it is made of.
  useEffect(() => {
    if (!project || decided.current === project.name) return;
    decided.current = project.name;
    setClosed(crowded(project.tree));
  }, [project]);

  const drop = useCallback(
    async (paths: string[], into: string) => {
      if (paths.length === 0) return;
      try {
        const added = await bridge.dropPaths(paths, into);
        setProject(await bridge.project());
        say(
          "said",
          added.length === 1
            ? `Added ${added[0].name}`
            : `Added ${added.length} things to the project`,
        );
      } catch (e) {
        say("refused", why(e));
      }
    },
    [say, setProject],
  );

  // Tauri intercepts the webview's own drag and drop, and it is the only side that knows where a
  // dropped file actually is — a browser `File` has no path. So the whole gesture lives here.
  useEffect(() => {
    let stop: (() => void) | null = null;
    void getCurrentWebview()
      .onDragDropEvent((e) => dragDrop(e.payload, setOver, drop, folderUnder))
      .then((un) => {
        stop = un;
      });
    return () => stop?.();
  }, [drop]);

  const move = useCallback(
    async (id: string, into: string) => {
      try {
        setProject(await bridge.moveItem(id, into));
      } catch (e) {
        say("refused", why(e));
      }
    },
    [say, setProject],
  );

  const folder = useCallback(
    async (parent: string, name: string) => {
      setNaming(null);
      if (!name) return;
      try {
        setProject(await bridge.addFolder(parent, name));
      } catch (e) {
        say("refused", why(e));
      }
    },
    [say, setProject],
  );

  if (!project) {
    return <Empty title="No project open" hint="Open a folder to start." />;
  }

  return (
    <>
      <GroupLabel
        right={
          <div className="flex items-center gap-0.5">
            <Button
              tone="ghost"
              title="New folder"
              className="!px-1 !py-0.5"
              onClick={() => setNaming("")}
            >
              <Icon name="folder-plus" />
            </Button>
            <NewComposition
              busy={adding}
              onPick={async (shape) => {
                setAdding(true);
                try {
                  setProject(
                    await bridge.addComposition(
                      untitled(project.compositions),
                      shape.w,
                      shape.h,
                      "",
                    ),
                  );
                } catch (e) {
                  say("refused", why(e));
                } finally {
                  setAdding(false);
                }
              }}
            />
          </div>
        }
      >
        {project.name}
      </GroupLabel>

      {/* The pane itself is the top of the project, so a drop with no folder under it lands
          there — which is why the whole scroller is a target and not only the rows. */}
      <div
        className={clsx(
          "scroll min-h-0 flex-1 px-1.5 pb-4 transition-colors",
          over === "" && "bg-[var(--ink-2)] ring-1 ring-inset ring-[var(--move)]",
        )}
        onDragOver={(e) => {
          if (e.dataTransfer.types.includes(MOVE)) {
            e.preventDefault();
            setOver("");
          }
        }}
        onDragLeave={() => setOver(null)}
        onDrop={(e) => {
          const id = e.dataTransfer.getData(MOVE);
          setOver(null);
          if (id) void move(id, "");
        }}
      >
        {naming === "" ? <NameIt onDone={(name) => void folder("", name)} /> : null}

        {project.tree.length === 0 ? (
          <p className="px-1.5 pt-1 text-[12px] text-[var(--text-3)]">
            Nothing here yet. Make a composition with the plus, or drop footage in.
          </p>
        ) : (
          <Rows
            items={project.tree}
            depth={0}
            active={active}
            sourceId={source?.id ?? null}
            over={over}
            closed={closed}
            naming={naming}
            onOpen={onOpen}
            onLook={async (asset) => {
              try {
                showSource(await bridge.assetSource(asset.id));
              } catch (e) {
                say("refused", why(e));
              }
            }}
            onToggle={(at) =>
              setClosed((c) => (c.includes(at) ? c.filter((x) => x !== at) : [...c, at]))
            }
            onOver={setOver}
            onMove={move}
            onNew={setNaming}
            onName={folder}
            onRename={async (at, name) => {
              try {
                setProject(await bridge.renameFolder(at, name));
              } catch (e) {
                say("refused", why(e));
              }
            }}
          />
        )}
      </div>
    </>
  );
}

interface RowsProps {
  items: TreeItem[];
  depth: number;
  active: string | null;
  sourceId: string | null;
  over: string | null;
  closed: string[];
  naming: string | null;
  onOpen: (variation: string) => void;
  onLook: (asset: AssetView) => void;
  onToggle: (at: string) => void;
  onOver: (at: string | null) => void;
  onMove: (id: string, into: string) => void;
  onNew: (parent: string) => void;
  onName: (parent: string, name: string) => void;
  onRename: (at: string, name: string) => void;
}

function Rows(props: RowsProps) {
  const { items, depth } = props;
  return (
    <ul style={{ paddingLeft: depth === 0 ? 0 : 11 }}>
      {items.map((item) => {
        if (item.what === "folder") {
          const shut = props.closed.includes(item.at);
          return (
            <li key={`f:${item.at}`}>
              <Folder {...props} item={item} shut={shut} />
              {shut ? null : (
                <>
                  {props.naming === item.at ? (
                    <div style={{ paddingLeft: 11 }}>
                      <NameIt onDone={(name) => props.onName(item.at, name)} />
                    </div>
                  ) : null}
                  <Rows {...props} items={item.items} depth={depth + 1} />
                </>
              )}
            </li>
          );
        }
        if (item.what === "composition") {
          const c = item.comp;
          const open = c.variations.find((v) => v.id === props.active) ?? c.variations[0];
          return (
            <li key={`c:${c.id}`}>
              <Row
                icon="comp"
                title={c.title}
                note={c.variations.every((v) => v.empty) ? "empty" : undefined}
                selected={c.variations.some((v) => v.id === props.active)}
                id={c.id}
                onClick={() => {
                  if (open) props.onOpen(open.id);
                }}
              />
            </li>
          );
        }
        const a = item.asset;
        return (
          <li key={`a:${a.id}`}>
            <Row
              icon={KIND_ICON[a.kind]}
              title={a.name}
              hover={`Double-click to look at ${a.name}`}
              note={fmt.size(a.size) ?? undefined}
              quiet
              selected={props.sourceId === a.id}
              id={a.id}
              asset
              onDoubleClick={() => props.onLook(a)}
            />
          </li>
        );
      })}
    </ul>
  );
}

function Folder({
  item,
  shut,
  over,
  onToggle,
  onOver,
  onMove,
  onNew,
  onRename,
}: RowsProps & { item: Extract<TreeItem, { what: "folder" }>; shut: boolean }) {
  const [renaming, setRenaming] = useState(false);

  if (renaming) {
    return (
      <NameIt
        was={item.name}
        onDone={(name) => {
          setRenaming(false);
          if (name && name !== item.name) onRename(item.at, name);
        }}
      />
    );
  }

  return (
    <div
      data-folder={item.at}
      className={clsx(
        "group/row flex items-center gap-1 rounded-[var(--radius-sm)] pr-1 transition-colors",
        over === item.at
          ? "bg-[var(--ink-4)] ring-1 ring-inset ring-[var(--move)]"
          : "hover:bg-[var(--ink-3)]",
      )}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes(MOVE)) {
          e.preventDefault();
          e.stopPropagation();
          onOver(item.at);
        }
      }}
      onDragLeave={() => onOver(null)}
      onDrop={(e) => {
        e.stopPropagation();
        const id = e.dataTransfer.getData(MOVE);
        onOver(null);
        if (id) onMove(id, item.at);
      }}
    >
      <button
        type="button"
        className="flex min-w-0 flex-1 items-center gap-1.5 px-1 py-[5px] text-left"
        onClick={() => onToggle(item.at)}
        onDoubleClick={() => setRenaming(true)}
        title={`${item.name} — double-click to rename`}
      >
        <Icon
          name={shut ? "caret-right" : "caret-down"}
          className="h-3 w-3 shrink-0 text-[var(--text-3)]"
        />
        <Icon name="folder" className="shrink-0 text-[var(--text-3)]" />
        <span className="min-w-0 flex-1 truncate text-[12.5px] font-medium text-[var(--text-1)]">
          {item.name}
        </span>
      </button>
      <span className="opacity-0 transition-opacity group-hover/row:opacity-100">
        <Button
          tone="ghost"
          title={`New folder in ${item.name}`}
          className="!px-1 !py-0.5"
          onClick={() => onNew(item.at)}
        >
          <Icon name="folder-plus" className="h-3 w-3" />
        </Button>
      </span>
    </div>
  );
}

function Row({
  icon,
  title,
  hover,
  note,
  quiet,
  selected,
  id,
  asset,
  onClick,
  onDoubleClick,
}: {
  icon: IconName;
  title: string;
  /** What the row says on hover, when there is more to say than its name. */
  hover?: string;
  note?: string;
  /** A note only worth reading when you are looking for it. */
  quiet?: boolean;
  selected: boolean;
  /** What this row is, for a drag. */
  id: string;
  asset?: boolean;
  onClick?: () => void;
  onDoubleClick?: () => void;
}) {
  return (
    <button
      type="button"
      draggable
      title={hover ?? title}
      onClick={onClick}
      onDoubleClick={onDoubleClick}
      onDragStart={(e) => {
        e.dataTransfer.setData(MOVE, id);
        // The timeline already knows how to take an asset, so the same drag can land on a lane
        // or on a folder.
        if (asset) e.dataTransfer.setData(ASSET, id);
        e.dataTransfer.effectAllowed = "move";
      }}
      className={clsx(
        "group/row flex w-full items-center gap-1.5 rounded-[var(--radius-sm)] px-2 py-[5px] text-left transition-colors",
        selected ? "bg-[var(--ink-4)]" : "hover:bg-[var(--ink-3)]",
      )}
    >
      <span
        className={clsx(
          "h-[13px] w-[2px] shrink-0 rounded-full transition-colors",
          selected ? "bg-[var(--move)]" : "bg-transparent",
        )}
        aria-hidden
      />
      <Icon name={icon} className="shrink-0 text-[var(--text-3)]" />
      <span className="min-w-0 flex-1 truncate text-[12.5px] text-[var(--text-1)]">{title}</span>
      {note ? (
        <span
          className={clsx(
            "tnum shrink-0 text-[10.5px] text-[var(--text-3)]",
            quiet && "opacity-0 transition-opacity group-hover/row:opacity-100",
          )}
        >
          {note}
        </span>
      ) : null}
    </button>
  );
}

/** Typing a name: a new folder, or renaming one. The same gesture either way. */
function NameIt({ was, onDone }: { was?: string; onDone: (name: string) => void }) {
  const [text, setText] = useState(was ?? "");
  const box = useRef<HTMLInputElement>(null);
  useEffect(() => {
    box.current?.focus();
    box.current?.select();
  }, []);
  return (
    <div className="flex items-center gap-1.5 px-2 py-[3px]">
      <Icon name="folder" className="shrink-0 text-[var(--text-3)]" />
      <input
        ref={box}
        value={text}
        onChange={(e) => setText(e.target.value)}
        onBlur={() => onDone(text.trim())}
        onKeyDown={(e) => {
          if (e.key === "Enter") onDone(text.trim());
          if (e.key === "Escape") onDone("");
        }}
        placeholder="Folder name"
        className="min-w-0 flex-1 rounded-[3px] border px-1 py-px text-[12.5px] outline-none"
        style={{ background: "var(--ink-0)", borderColor: "var(--focus)", color: "var(--text-1)" }}
      />
    </div>
  );
}

function NewComposition({
  busy,
  onPick,
}: {
  busy: boolean;
  onPick: (shape: { w: number; h: number }) => void;
}) {
  const [open, setOpen] = useState(false);
  return (
    <div className="relative">
      <Button
        tone="ghost"
        title="New composition"
        disabled={busy}
        className="!px-1 !py-0.5"
        onClick={() => setOpen((o) => !o)}
      >
        <Icon name="plus" />
      </Button>
      {open ? (
        <div
          className="rise absolute right-0 top-full z-30 mt-1 w-[150px] overflow-hidden rounded-[var(--radius)] border bg-[var(--ink-2)] py-1"
          style={{ boxShadow: "var(--shadow-lift)", borderColor: "var(--edge)" }}
        >
          {SHAPES.map((s) => (
            <button
              key={s.title}
              type="button"
              className="flex w-full items-center justify-between px-3 py-1.5 text-left text-[12.5px] hover:bg-[var(--ink-3)]"
              onClick={() => {
                setOpen(false);
                onPick(s);
              }}
            >
              <span>{s.title}</span>
              <span className="tnum text-[10.5px] text-[var(--text-3)]">{aspectOf(s.w, s.h)}</span>
            </button>
          ))}
        </div>
      ) : null}
    </div>
  );
}

export function aspectOf(w: number, h: number): string {
  const r = w / h;
  const named: [number, string][] = [
    [16 / 9, "16:9"],
    [9 / 16, "9:16"],
    [1, "1:1"],
    [4 / 5, "4:5"],
    [4 / 3, "4:3"],
    [21 / 9, "21:9"],
  ];
  return named.reduce((best, x) => (Math.abs(x[0] - r) < Math.abs(best[0] - r) ? x : best))[1];
}

/** Everything in the tree, flat, folders included. What a count or a search reads. */
/** How many rows a folder may show before it starts shut.
 *
 *  A dozen is about what fits beside the rest of a project without pushing it out of sight, and
 *  it is comfortably more than any folder in a small project has. */
export const CROWDED = 12;

/** Every folder, anywhere in the tree, with more in it than the pane can show at once.
 *
 *  Counted on what a folder holds directly, not on everything underneath it: a folder of three
 *  folders is three rows and is perfectly readable, however much is further down. */
export function crowded(items: TreeItem[]): string[] {
  const out: string[] = [];
  const walk = (list: TreeItem[]) => {
    for (const item of list) {
      if (item.what !== "folder") continue;
      if (item.items.length > CROWDED) out.push(item.at);
      walk(item.items);
    }
  };
  walk(items);
  return out;
}

export function flatten(items: TreeItem[]): TreeItem[] {
  const out: TreeItem[] = [];
  for (const i of items) {
    out.push(i);
    if (i.what === "folder") out.push(...flatten(i.items));
  }
  return out;
}

export function untitled(existing: { title: string }[]): string {
  const base = "Untitled";
  if (!existing.some((c) => c.title === base)) return base;
  for (let n = 2; ; n += 1) {
    const candidate = `${base} ${n}`;
    if (!existing.some((c) => c.title === candidate)) return candidate;
  }
}
