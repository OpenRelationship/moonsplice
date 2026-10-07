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

import { useCallback, useEffect, useMemo, useRef, useState, type CSSProperties } from "react";
import clsx from "clsx";

import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { useInstant } from "../instant";
import { Mix } from "../mix";
import { saidRate, useClock, useFrame } from "../player";
import { activeTab, useStudio, type Tab } from "../state";
import type { SourceView, VariationView } from "../types";
import { Button, Empty, Icon } from "../ui/bits";

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

/** What the left pane puts on a drag of one of the project's things. */
const ASSET = "text/moonsplice-asset";

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

/** The composition, heard.
 *
 *  The preview used to be silent, because a composition's mix is made by ffmpeg at encode — so
 *  the only way to hear your own narration was to render the whole thing, which for an edit with
 *  sixty spoken lines in it is not an editor. The mix follows the transport: it starts where the
 *  playhead is, stops when it stops, and starts again somewhere else when it is dragged.
 *
 *  The playhead is *not* a dependency of the effect that plays. If it were, every frame of
 *  playback would tear the mix down and start it again. What it watches is whether playback is
 *  running, and it reads the playhead once at that moment. */
function useHeard(tab: Tab, playing: boolean, playhead: number) {
  const assetBase = useStudio((s) => s.assetBase);
  const listening = useStudio((s) => s.listening);
  const mix = useRef<Mix | null>(null);
  /** Where the mix was started from, so a drag of the playhead is told apart from its running. */
  const startedAt = useRef(0);

  useEffect(() => {
    const it = new Mix(tab.variation, assetBase);
    it.setLevel(useStudio.getState().listening);
    mix.current = it;
    return () => {
      it.close();
      mix.current = null;
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the level is read once, then watched
  }, [tab.variation, assetBase]);

  // Loudness, the moment it is asked for. It is a gain on the way out, so it takes hold on what
  // is already sounding rather than on the next thing to start.
  useEffect(() => {
    mix.current?.setLevel(listening);
  }, [listening]);

  // The mix, whenever the composition changes. A sound moved on the timeline is heard in its new
  // place the moment the outline says so.
  useEffect(() => {
    mix.current?.holds(tab.outline.audio ?? [], tab.meta.duration);
  }, [tab.outline.audio, tab.meta.duration]);

  useEffect(() => {
    const it = mix.current;
    if (!it) return;
    if (!playing) {
      it.stop();
      return;
    }
    startedAt.current = useStudio.getState().playhead;
    void it.play(startedAt.current);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- the playhead is read, not watched
  }, [playing, tab.variation, tab.hash]);

  // A seek while playing: the playhead moved somewhere the mix was not going. Told apart from
  // the playhead simply advancing by how far it jumped -- a second is further than a frame.
  useEffect(() => {
    const it = mix.current;
    if (!it || !playing) return;
    if (Math.abs(playhead - startedAt.current) > 1.0) {
      startedAt.current = playhead;
      void it.play(playhead);
    }
  }, [playhead, playing]);
}

function Preview({ tab }: { tab: Tab }) {
  const playhead = useStudio((s) => s.playhead);
  const playing = useStudio((s) => s.playing);
  const rate = useStudio((s) => s.rate);
  const setPlaying = useStudio((s) => s.setPlaying);
  const seek = useStudio((s) => s.seek);
  const frameBase = useStudio((s) => s.frameBase);
  const selection = useStudio((s) => s.selection);
  const select = useStudio((s) => s.select);
  const say = useStudio((s) => s.say);

  const box = useRef<HTMLDivElement>(null);
  const [size, setSize] = useState({ w: 0, h: 0 });
  const [drag, setDrag] = useState<{ node: string; dx: number; dy: number } | null>(null);
  /** Something from the left pane is over the picture. */
  const [taking, setTaking] = useState(false);

  // The frame's own pixel box inside the pane, so handles land where the picture is.
  const fit = useMemo(() => {
    const { width, height } = tab.meta;
    if (!size.w || !size.h || !width || !height) return { w: 0, h: 0, scale: 1 };
    const scale = Math.min(size.w / width, size.h / height);
    return { w: Math.round(width * scale), h: Math.round(height * scale), scale };
  }, [size, tab.meta]);

  useEffect(() => {
    const el = box.current;
    if (!el) return;
    const ro = new ResizeObserver(([entry]) => {
      const r = entry.contentRect;
      setSize({ w: Math.floor(r.width), h: Math.floor(r.height) });
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  useClock(
    playing,
    tab.meta.duration,
    () => useStudio.getState().playhead,
    (t) => useStudio.getState().seek(t),
    rate,
    () => useStudio.getState().setRate(0),
  );

  useHeard(tab, playing && rate === 1, playhead);

  const instant = useInstant(tab.variation, tab.hash, playhead, !playing);

  const picture = useRef<HTMLCanvasElement>(null);
  const { painted, behind, scale } = useFrame(
    picture,
    tab.variation,
    tab.hash,
    playhead,
    fit.w,
    fit.h,
    frameBase,
    { playing, fps: tab.meta.fps, duration: tab.meta.duration },
  );

  const named = useMemo(() => fmt.names(tab.outline.nodes ?? []), [tab.outline.nodes]);

  const handles = useMemo(() => {
    // The instant comes from another process. A field that is not the shape this expects is a
    // blank window if it reaches `.map`, so it is checked rather than trusted -- an empty
    // composition is exactly that case, and it is a normal thing to open.
    if (!instant || fit.scale === 0 || !Array.isArray(instant.nodes)) return [];
    return instant.nodes
      .map((n) => {
        const p = n.props ?? {};
        const x = num(p.x);
        const y = num(p.y);
        if (x == null || y == null) return null;
        const w = num(p.w) ?? num(p.r) != null ? (num(p.w) ?? num(p.r)! * 2) : null;
        const h = num(p.h) ?? (num(p.r) != null ? num(p.r)! * 2 : null);
        const opacity = num(p.opacity);
        if (opacity != null && opacity <= 0.02) return null;
        return {
          id: n.id,
          kind: n.kind,
          label: n.label ?? null,
          x,
          y,
          w,
          h,
        };
      })
      .filter((v): v is NonNullable<typeof v> => v != null);
  }, [instant, fit.scale]);

  const onMove = useCallback(
    async (node: string, x: number, y: number) => {
      try {
        await bridge.gesture(tab.variation, { gesture: "move", node, x, y });
      } catch (e) {
        say("refused", why(e));
      }
    },
    [say, tab.variation],
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div
        ref={box}
        className={clsx(
          "relative flex min-h-0 flex-1 items-center justify-center overflow-hidden p-5 transition-colors",
          taking && "bg-[var(--ink-1)]",
        )}
        onPointerDown={(e) => {
          if (e.target === e.currentTarget) select({ node: null });
        }}
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
          // On the picture, a thing arrives at the moment you are looking at.
          void (async () => {
            try {
              await bridge.placeAsset(tab.variation, asset, playhead);
            } catch (err) {
              say("refused", why(err));
            }
          })();
        }}
      >
        {fit.w > 0 ? (
          <div
            className="relative"
            style={{ width: fit.w, height: fit.h }}
            onPointerMove={(e) => {
              if (!drag) return;
              e.preventDefault();
            }}
          >
            {/* The pixels the renderer made, painted straight onto a canvas: no codec on
                either side of the boundary, so a frame costs a copy instead of an encode and a
                decode. It is sized in layout pixels and holds device pixels, which is what makes
                it sharp on a retina screen. */}
            <canvas
              ref={picture}
              aria-label={`${tab.title} at ${fmt.timecode(playhead)}`}
              role="img"
              className="absolute inset-0 rounded-[var(--radius)]"
              style={{ width: fit.w, height: fit.h, boxShadow: "var(--shadow-lift)" }}
            />
            {painted ? null : (
              <div className="holding absolute inset-0 rounded-[var(--radius)]" aria-hidden />
            )}

            {/* What is on the disk stopped loading, and this is the last version that did.
                On the picture rather than in a notice, because a notice is dismissed and this
                is true until it stops being true -- every frame under it is out of date, and
                nothing else on screen would say so. */}
            {tab.trouble ? (
              <div
                className="absolute inset-x-0 top-0 rounded-t-[var(--radius)] px-3 py-1.5 text-[11px] leading-snug"
                style={{
                  background: "color-mix(in oklab, var(--warn) 24%, var(--ink-0))",
                  color: "var(--text-1)",
                  boxShadow: "inset 0 -1px 0 color-mix(in oklab, var(--warn) 45%, transparent)",
                }}
              >
                <span style={{ color: "var(--warn)" }}>Showing the last version that worked</span>
                {" — "}
                {tab.trouble}
              </div>
            ) : null}

            {/* Handles: one per thing the renderer placed. */}
            {handles.map((n) => {
              const selected = selection.node === n.id;
              const left = n.x * fit.scale;
              const top = n.y * fit.scale;
              const w = n.w != null ? Math.max(8, n.w * fit.scale) : null;
              const h = n.h != null ? Math.max(8, n.h * fit.scale) : null;
              return (
                <div
                  key={n.id}
                  role="button"
                  tabIndex={0}
                  aria-label={n.label ?? fmt.kind(n.kind)}
                  className={clsx(
                    "absolute cursor-move rounded-[3px] transition-colors",
                    selected
                      ? "ring-[1.5px] ring-[var(--move)]"
                      : "ring-1 ring-transparent hover:ring-[var(--text-3)]",
                  )}
                  style={
                    w != null && h != null
                      ? { left, top, width: w, height: h }
                      : { left: left - 7, top: top - 7, width: 14, height: 14 }
                  }
                  onPointerDown={(e) => {
                    e.stopPropagation();
                    select({ node: n.id });
                    const startX = e.clientX;
                    const startY = e.clientY;
                    setDrag({ node: n.id, dx: 0, dy: 0 });
                    const el = e.currentTarget;
                    el.setPointerCapture(e.pointerId);
                    const move = (ev: PointerEvent) => {
                      setDrag({
                        node: n.id,
                        dx: (ev.clientX - startX) / fit.scale,
                        dy: (ev.clientY - startY) / fit.scale,
                      });
                    };
                    const up = (ev: PointerEvent) => {
                      el.removeEventListener("pointermove", move);
                      el.removeEventListener("pointerup", up);
                      const dx = (ev.clientX - startX) / fit.scale;
                      const dy = (ev.clientY - startY) / fit.scale;
                      setDrag(null);
                      if (Math.abs(dx) > 0.5 || Math.abs(dy) > 0.5) {
                        void onMove(n.id, n.x + dx, n.y + dy);
                      }
                    };
                    el.addEventListener("pointermove", move);
                    el.addEventListener("pointerup", up);
                  }}
                  onKeyDown={(e) => {
                    const step = e.shiftKey ? 10 : 1;
                    if (e.key === "ArrowLeft") void onMove(n.id, n.x - step, n.y);
                    if (e.key === "ArrowRight") void onMove(n.id, n.x + step, n.y);
                    if (e.key === "ArrowUp") void onMove(n.id, n.x, n.y - step);
                    if (e.key === "ArrowDown") void onMove(n.id, n.x, n.y + step);
                  }}
                >
                  {selected ? (
                    <span
                      // Quiet on purpose. The brightest thing on this screen is the picture,
                      // and a solid teal pill sitting on top of the frame is not the picture.
                      className="pointer-events-none absolute -top-[19px] left-0 whitespace-nowrap rounded-[4px] border px-1.5 py-px text-[10.5px] font-medium backdrop-blur-sm"
                      style={{
                        background: "color-mix(in oklab, var(--ink-0) 78%, transparent)",
                        borderColor: "var(--move-dim)",
                        color: "var(--move)",
                      }}
                    >
                      {named.get(n.id) ?? n.label ?? fmt.kind(n.kind)}
                    </span>
                  ) : null}
                  {drag?.node === n.id ? (
                    <span
                      className="tnum pointer-events-none absolute -bottom-[19px] left-0 whitespace-nowrap rounded-[4px] bg-[var(--ink-3)] px-1.5 py-px text-[10.5px]"
                      style={{ color: "var(--text-1)" }}
                    >
                      {Math.round(n.x + drag.dx)}, {Math.round(n.y + drag.dy)}
                    </span>
                  ) : null}
                </div>
              );
            })}
          </div>
        ) : null}
      </div>

      <Transport
        tab={tab}
        playing={playing}
        playhead={playhead}
        behind={behind}
        scale={scale}
        rate={rate}
        onPlay={() => setPlaying(!playing)}
        onSeek={seek}
      />
    </div>
  );
}

/** Why the preview is behind, in one sentence, only while it is. Asked for once a second and
 *  only while playing: a measurement that costs something to look at is one nobody looks at. */
function useWhyBehind(behind: boolean, playing: boolean, fps: number): string | null {
  const [why, setWhy] = useState<string | null>(null);
  useEffect(() => {
    if (!playing) {
      setWhy(null);
      return;
    }
    let alive = true;
    const budget = fps > 0 ? 1000 / fps : 1000 / 30;
    const ask = async () => {
      try {
        const report = await bridge.playback(budget);
        if (alive) setWhy(report.why);
      } catch {
        // Nothing to say is the right answer when the question cannot be asked.
      }
    };
    void ask();
    const every = window.setInterval(ask, 1000);
    return () => {
      alive = false;
      window.clearInterval(every);
    };
  }, [playing, fps]);
  return behind ? why : null;
}

/**
 * How loud the preview is.
 *
 * The only control in the app that is not an edit: it changes nothing that is written down and
 * nothing that comes out of a render, which is why it sits next to the clock rather than
 * anywhere near the timeline. The speaker puts it to silence and back to where it was, the way
 * every other player does it -- so the quick thing is one click and the exact thing is a drag.
 */
function Listening() {
  const listening = useStudio((s) => s.listening);
  const setListening = useStudio((s) => s.setListening);
  /** Where it was before it was silenced, so clicking again puts it back rather than guessing. */
  const wasAt = useRef(0.8);

  const pct = Math.round(listening * 100);
  const glyph = listening === 0 ? "sound-off" : listening < 0.34 ? "sound-low" : "sound-high";

  return (
    <div
      className="flex items-center gap-1.5"
      title={listening === 0 ? "Silent" : `Listening at ${pct}%`}
    >
      <Button
        tone="ghost"
        title={listening === 0 ? "Hear it again" : "Silence the preview"}
        className="!px-1.5"
        onClick={() => {
          if (listening === 0) {
            setListening(wasAt.current || 0.8);
          } else {
            wasAt.current = listening;
            setListening(0);
          }
        }}
      >
        <Icon name={glyph} />
      </Button>
      <input
        type="range"
        className="fader"
        min={0}
        max={100}
        step={1}
        value={pct}
        aria-label="How loud the preview is"
        style={{ "--at": `${pct}%` } as CSSProperties}
        onChange={(e) => {
          const v = Number(e.target.value) / 100;
          if (v > 0) wasAt.current = v;
          setListening(v);
        }}
      />
    </div>
  );
}

function Transport({
  tab,
  playing,
  playhead,
  behind,
  scale,
  rate,
  onPlay,
  onSeek,
}: {
  tab: Tab;
  playing: boolean;
  playhead: number;
  /** The picture is a frame or two back. Said quietly, by dimming the clock -- the honest
   *  reading is "the time is ahead of the picture", and that is what it looks like. */
  behind: boolean;
  /** How big the moving picture is being drawn, as a fraction of the pane. 1 unless playing
   *  had to give something up to keep time. */
  scale: number;
  /** How fast, and which way. 1 is the speed it was shot at. */
  rate: number;
  onPlay: () => void;
  onSeek: (t: number) => void;
}) {
  const say = useStudio((s) => s.say);
  const slow = useWhyBehind(behind, playing, tab.meta.fps);
  const said = saidRate(rate);
  return (
    <div
      className="flex h-[34px] shrink-0 items-center gap-2 border-t px-2.5"
      style={{ borderColor: "var(--edge-soft)" }}
    >
      <Button tone="ghost" title={playing ? "Pause" : "Play"} onClick={onPlay} className="!px-1.5">
        <Icon name={playing ? "pause" : "play"} />
      </Button>
      <span
        className={clsx(
          "tnum text-[11.5px] transition-colors",
          behind ? "text-[var(--text-3)]" : "text-[var(--text-2)]",
        )}
        title={behind ? "the picture is catching up" : undefined}
      >
        {fmt.timecode(playhead)}
      </span>
      <span className="text-[11px] text-[var(--text-3)]">/ {fmt.seconds(tab.meta.duration)}</span>

      {/* The shuttle speed, whenever it is not the speed the thing was shot at. A preview
          running backwards at four times with nothing said about it looks like a fault, and
          the sound going quiet looks like a second one -- so both are said, in three words. */}
      {playing && said ? (
        <span
          className="tnum rounded px-1 text-[10px]"
          style={{ background: "var(--ink-3)", color: "var(--text-2)" }}
          title="Sound plays at the speed it was recorded and nowhere else, so it is silent while you shuttle"
        >
          {said}
        </span>
      ) : null}

      {/* What playing gave up to keep time. Every editor does this and every editor says so,
          because a person who is not told will think the composition looks like that. It is
          one word, it is gone the moment they stop, and it is not a control: there is nothing
          to decide here, the player already decided. */}
      {playing && scale < 1 ? (
        <span
          className="rounded px-1 text-[10px] text-[var(--text-3)]"
          style={{ border: "1px solid var(--edge-soft)" }}
          title="The preview is drawn smaller while it plays, so it can keep time. It is full size again the moment you stop."
        >
          {scale >= 0.7 ? "¾ size" : scale >= 0.45 ? "half size" : scale >= 0.3 ? "⅓ size" : "¼ size"}
        </span>
      ) : null}

      {/* When the picture cannot keep up, say which part of it is slow rather than leaving a
          person to guess. It appears only while that is true, and says nothing otherwise. */}
      {slow ? (
        <span className="truncate text-[11px] text-[var(--text-3)]" title={slow}>
          {slow}
        </span>
      ) : null}

      <div className="flex-1" />

      <Listening />
      <span className="mx-1 h-[14px] w-px" style={{ background: "var(--edge-soft)" }} aria-hidden />

      <Button
        tone="ghost"
        title={tab.undoLabel ? `Undo — ${tab.undoLabel}` : "Nothing to undo"}
        disabled={tab.undo === 0}
        className="!px-1.5"
        onClick={async () => {
          try {
            say("said", await bridge.undo(tab.variation));
          } catch (e) {
            say("refused", why(e));
          }
        }}
      >
        <Icon name="undo" />
      </Button>
      <Button
        tone="ghost"
        title={tab.redoLabel ? `Redo — ${tab.redoLabel}` : "Nothing to redo"}
        disabled={tab.redo === 0}
        className="!px-1.5"
        onClick={async () => {
          try {
            say("said", await bridge.redo(tab.variation));
          } catch (e) {
            say("refused", why(e));
          }
        }}
      >
        <Icon name="redo" />
      </Button>

      <span className="tnum pl-1 text-[10.5px] text-[var(--text-3)]">
        {tab.meta.width}×{tab.meta.height}
      </span>
      <Button
        tone="ghost"
        title="Step back one frame"
        className="!px-1"
        onClick={() => onSeek(playhead - 1 / tab.meta.fps)}
      >
        <Icon name="step-back" className="h-[11px] w-[11px]" />
      </Button>
      <Button
        tone="ghost"
        title="Step on one frame"
        className="!px-1"
        onClick={() => onSeek(playhead + 1 / tab.meta.fps)}
      >
        <Icon name="step-on" className="h-[11px] w-[11px]" />
      </Button>
    </div>
  );
}

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
