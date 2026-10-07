import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import clsx from "clsx";
import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { useInstant } from "../instant";
import { Mix } from "../mix";
import { useClock, useFrame } from "../player";
import { useStudio, type Tab } from "../state";
import { Transport } from "./Transport";

/** What the left pane puts on a drag of one of the project's things. */
export const ASSET = "text/moonsplice-asset";

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

export function Preview({ tab }: { tab: Tab }) {
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

function num(v: unknown): number | null {
  return typeof v === "number" && Number.isFinite(v) ? v : null;
}
