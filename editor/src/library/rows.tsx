import { useEffect, useRef, useState } from "react";
import clsx from "clsx";
import * as fmt from "../format";
import type { AssetView, TreeItem } from "../types";
import { Button, Icon, type IconName } from "../ui/bits";
import { ASSET, KIND_ICON, MOVE } from "./Library";

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

export function Rows(props: RowsProps) {
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
export function NameIt({ was, onDone }: { was?: string; onDone: (name: string) => void }) {
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
