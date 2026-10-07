// The centre: one tab per composition, one for whatever asset is loaded for a look, and under
// them the picture.
//
// A composition's shape (wide, vertical, square) is not a tab of its own. It is a control beside
// the picture it changes, because that is what it changes -- and because the left pane lists
// compositions, not shapes of compositions.
//
// The picture is the only bright thing in the window. Over it sit handles at the positions the
// renderer actually painted — read from the engine, never guessed — so grabbing a thing on
// screen and moving it is the same gesture as typing a number in the inspector, and goes down
// the same single edit path.

import { useState } from "react";
import clsx from "clsx";
import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { activeTab, useStudio, type Tab } from "../state";
import type { SourceView, VariationView } from "../types";
import { Button, Empty, Icon } from "../ui/bits";
import { ASSET, Preview } from "./Preview";

export function Stage() {
  const tabs = useStudio((s) => s.tabs);
  const tab = useStudio((s) => activeTab(s));
  const activate = useStudio((s) => s.activate);
  const closeTab = useStudio((s) => s.closeTab);
  const source = useStudio((s) => s.source);
  const viewing = useStudio((s) => s.viewing);
  const showSource = useStudio((s) => s.showSource);
  const closeSource = useStudio((s) => s.closeSource);

  return (
    <section className="flex min-h-0 min-w-0 flex-1 flex-col bg-[var(--ink-0)]">
      <div
        className="flex h-[36px] shrink-0 items-stretch gap-0.5 border-b px-1.5"
        style={{ borderColor: "var(--edge-soft)" }}
      >
      <div className="flex min-w-0 flex-1 items-stretch gap-0.5 overflow-x-auto">
        {tabs.map((t) => (
          <button
            key={t.variation}
            type="button"
            onClick={() => activate(t.variation)}
            className={clsx(
              "group relative flex shrink-0 items-center gap-2 rounded-t-[var(--radius-sm)] px-3 text-[12.5px] transition-colors",
              t.variation === tab?.variation
                ? "bg-[var(--ink-2)] text-[var(--text-1)]"
                : "text-[var(--text-3)] hover:bg-[var(--ink-1)] hover:text-[var(--text-2)]",
            )}
          >
            {t.variation === tab?.variation ? (
              <span
                className="absolute inset-x-0 top-0 h-[2px] rounded-full"
                style={{ background: "var(--move)" }}
                aria-hidden
              />
            ) : null}
            <span>{t.title}</span>
            <span
              role="button"
              tabIndex={-1}
              aria-label={`Close ${t.title}`}
              className="-mr-1 rounded p-0.5 opacity-0 transition-opacity hover:bg-[var(--ink-4)] group-hover:opacity-100"
              onClick={(e) => {
                e.stopPropagation();
                void bridge.closeVariation(t.variation);
                closeTab(t.variation);
              }}
            >
              <Icon name="close" className="h-3 w-3" />
            </span>
          </button>
        ))}

        {/* Whatever is loaded for a look. It sits after the compositions, the way a source
            viewer sits beside the one you are cutting. */}
        {source ? (
          <button
            type="button"
            onClick={() => showSource(source)}
            className={clsx(
              "group relative flex shrink-0 items-center gap-2 rounded-t-[var(--radius-sm)] px-3 text-[12.5px] transition-colors",
              viewing === "source"
                ? "bg-[var(--ink-2)] text-[var(--text-1)]"
                : "text-[var(--text-3)] hover:bg-[var(--ink-1)] hover:text-[var(--text-2)]",
            )}
          >
            {viewing === "source" ? (
              <span
                className="absolute inset-x-0 top-0 h-[2px] rounded-full"
                style={{ background: "var(--said)" }}
                aria-hidden
              />
            ) : null}
            <Icon name={source.kind === "audio" ? "audio" : source.kind === "image" ? "image" : "footage"} className="h-3 w-3" />
            <span className="max-w-[160px] truncate">{source.name}</span>
            <span
              role="button"
              tabIndex={-1}
              aria-label={`Close ${source.name}`}
              className="-mr-1 rounded p-0.5 opacity-0 transition-opacity hover:bg-[var(--ink-4)] group-hover:opacity-100"
              onClick={(e) => {
                e.stopPropagation();
                closeSource();
              }}
            >
              <Icon name="close" className="h-3 w-3" />
            </span>
          </button>
        ) : null}
      </div>

        {/* The shape of the composition in front. Not a tab: a property of the thing in the
            tab, next to the picture whose proportions it changes. */}
        {tab ? <Shapes tab={tab} /> : null}
      </div>

      {viewing === "source" && source ? (
        <Source source={source} />
      ) : tab ? (
        <Preview tab={tab} />
      ) : (
        <NothingOpen />
      )}
    </section>
  );
}

/** Every shape this composition has, and the ones it could have. */
function Shapes({ tab }: { tab: Tab }) {
  const project = useStudio((s) => s.project);
  const setProject = useStudio((s) => s.setProject);
  const say = useStudio((s) => s.say);
  const activate = useStudio((s) => s.activate);
  const [busy, setBusy] = useState(false);

  const comp = project?.compositions.find((c) => c.id === tab.composition);
  const shapes: VariationView[] = comp?.variations ?? [];
  const missing = SHAPES.filter((s) => !shapes.some((v) => v.aspect === s.aspect));
  if (!comp) return null;

  return (
    <div className="flex shrink-0 items-center gap-1 self-center pl-2">
      {shapes.length > 1
        ? shapes.map((v) => (
            <button
              key={v.id}
              type="button"
              title={`${comp.title} — ${v.title}`}
              onClick={() => void openShape(v.id)}
              className={clsx(
                "rounded-[var(--radius-sm)] px-2 py-[3px] text-[11px] transition-colors",
                v.id === tab.variation
                  ? "bg-[var(--ink-3)] text-[var(--text-1)]"
                  : "text-[var(--text-3)] hover:bg-[var(--ink-2)] hover:text-[var(--text-2)]",
              )}
            >
              {v.title}
            </button>
          ))
        : null}
      {missing.length > 0 ? (
        <Button
          tone="ghost"
          className="!px-1 !py-0.5"
          disabled={busy}
          title={`Add a ${missing[0].title.toLowerCase()} shape of ${comp.title}`}
          onClick={async () => {
            setBusy(true);
            try {
              setProject(await bridge.addVariation(comp.id, missing[0].w, missing[0].h));
            } catch (e) {
              say("refused", why(e));
            } finally {
              setBusy(false);
            }
          }}
        >
          <Icon name="plus" className="h-3 w-3" />
        </Button>
      ) : null}
    </div>
  );

  async function openShape(variation: string) {
    if (variation === tab.variation) return;
    try {
      const opened = await bridge.openVariation(variation);
      const v = shapes.find((x) => x.id === variation);
      useStudio.getState().addTab({
        variation,
        composition: comp!.id,
        title: comp!.title,
        aspect: v?.aspect ?? tab.aspect,
        meta: opened.meta,
        hash: opened.hash,
        outline: opened.outline,
        undo: 0,
        redo: 0,
        undoLabel: null,
        redoLabel: null,
      });
      activate(variation);
    } catch (e) {
      say("refused", why(e));
    }
  }
}

/** The three shapes this app offers to make. The same list the new-composition menu uses. */
const SHAPES = [
  { title: "Wide", aspect: "16:9", w: 1920, h: 1080 },
  { title: "Vertical", aspect: "9:16", w: 1080, h: 1920 },
  { title: "Square", aspect: "1:1", w: 1080, h: 1080 },
];

/** An asset, looked at. Footage plays, a picture shows, and anything else says so plainly rather
 *  than pretending to be a viewer for it. */
function Source({ source }: { source: SourceView }) {
  // Draggable, because the footer says so: the thing you are looking at is the thing you drag
  // into a composition.
  const hand = {
    draggable: true,
    onDragStart: (e: React.DragEvent) => {
      e.dataTransfer.setData(ASSET, source.id);
      e.dataTransfer.effectAllowed = "copy";
    },
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="relative flex min-h-0 flex-1 items-center justify-center overflow-hidden p-5">
        {source.kind === "footage" ? (
          <video
            key={source.url}
            src={source.url}
            controls
            {...hand}
            className="max-h-full max-w-full rounded-[var(--radius)]"
            style={{ boxShadow: "var(--shadow-lift)" }}
          />
        ) : source.kind === "image" ? (
          <img
            key={source.url}
            src={source.url}
            alt={source.name}
            {...hand}
            className="max-h-full max-w-full rounded-[var(--radius)]"
            style={{ boxShadow: "var(--shadow-lift)" }}
          />
        ) : source.kind === "audio" ? (
          <div className="flex w-full max-w-[520px] flex-col items-center gap-3" {...hand}>
            <Icon name="audio" className="h-6 w-6 text-[var(--sound)]" />
            <span className="text-[12.5px] text-[var(--text-2)]">{source.name}</span>
            <audio key={source.url} src={source.url} controls className="w-full" />
          </div>
        ) : (
          <Empty
            title={source.name}
            hint={`${fmt.assetKind(source.kind)} is in your project, and there is nothing to watch or listen to in it.`}
          />
        )}
      </div>
      <div
        className="flex h-[34px] shrink-0 items-center gap-2 border-t px-2.5"
        style={{ borderColor: "var(--edge-soft)" }}
      >
        <span className="text-[11.5px] text-[var(--text-2)]">{source.name}</span>
        <span className="text-[10.5px] text-[var(--text-3)]">{fmt.assetKind(source.kind)}</span>
        <div className="flex-1" />
        <span className="text-[10.5px] text-[var(--text-3)]">
          Drag it onto a composition to use it
        </span>
      </div>
    </div>
  );
}

function NothingOpen() {
  const project = useStudio((s) => s.project);
  return (
    <div className="flex-1">
      <Empty
        title={project ? "Pick a composition on the left" : "Open a folder to begin"}
        hint={
          project
            ? "Every composition can hold several shapes — wide, vertical, square — and you pick which one you are looking at above the picture."
            : "Moonsplice Studio works on a folder of compositions and the footage they use."
        }
      />
    </div>
  );
}
