import { useEffect, useRef, useState, type RefObject } from "react";
import { frameUrl } from "./bridge";
import {
  FRESH,
  type Pace,
  canvasSurface,
  msOf,
  pace,
  paint,
  pump,
  span,
  warm,
  warmth,
} from "./player";

/** A frame size, snapped even and never zero. An odd width is a scaler's worst case and a
 *  zero-sized frame is a request the renderer refuses. */
export function sized(px: number, scale: number): number {
  return Math.max(2, Math.round((px * scale) / 2) * 2);
}

export interface Showing {
  /** True once any frame has been painted, so the pane can stop showing a holding state. */
  painted: boolean;
  /** True while the frame on screen is not the frame the playhead is asking for. */
  behind: boolean;
  /** What fraction of the pane the moving picture is being drawn at. 1 whenever it is still,
   *  and whenever playing is keeping up -- so the UI can say "half size while playing" only
   *  when that is actually what somebody is looking at. */
  scale: number;
}

/**
 * Keep `canvas` showing the composition at `t`.
 *
 * `ahead` frames past the playhead are warmed while playing, which is what makes the second
 * pass over a scene smooth: they are already in the cache by the time the playhead gets there,
 * and the cache is keyed on the same snapped milliseconds.
 */
export function useFrame(
  canvas: RefObject<HTMLCanvasElement | null>,
  variation: string,
  hash: string,
  t: number,
  w: number,
  h: number,
  base: string,
  opts: { playing: boolean; fps: number; duration: number; ahead?: number } = {
    playing: false,
    fps: 30,
    duration: 0,
  },
): Showing {
  const [painted, setPainted] = useState(false);
  const [showing, setShowing] = useState<string | null>(null);
  const want = useRef<string | null>(null);
  const busy = useRef(false);
  const warmed = useRef(new Set<string>());
  const { playing, fps, duration } = opts;
  const most = opts.ahead ?? 6;

  // Whether the pump should be learning from what it paints. A still frame is asked for at full
  // size and is expected to cost more; letting that teach the player how big to draw a moving
  // one would mean every pause made the next play blurrier.
  const moving = useRef(playing);
  moving.current = playing;

  // How well the picture is keeping up, and therefore how big to ask for it. Held in state
  // rather than a ref because the size is part of the URL: changing it has to re-render.
  const [beat, setBeat] = useState<Pace>(FRESH);
  // One frame's worth of wall clock. What "keeping up" means, and nothing else.
  const budget = fps > 0 ? 1000 / fps : 1000 / 30;

  // Device pixels, not layout pixels: a preview at half the screen's resolution looks soft next
  // to everything else in the window. The renderer never upscales, so asking for more than the
  // composition has costs nothing.
  const dpr = typeof window === "undefined" ? 1 : Math.min(window.devicePixelRatio || 1, 2);
  // Still pictures are always full size. A person who has stopped is looking *at* the frame,
  // and the whole bargain of a smaller one -- you are watching timing, not pixels -- is only
  // true while it moves. Stopping therefore sharpens, on the next frame, with no extra state.
  const scale = playing ? beat.scale : 1;
  const fw = sized(w * dpr, scale);
  const fh = sized(h * dpr, scale);
  const target = w > 0 && h > 0 ? frameUrl(base, variation, hash, t, fw, fh) : null;

  // A different composition, or a changed one, or a resized pane: what was on screen is not
  // this composition's frame any more, so stop claiming it is.
  useEffect(() => {
    setPainted(false);
    setShowing(null);
    warmed.current.clear();
  }, [variation, hash, w, h]);

  // A new run of playback starts from the benefit of the doubt. The last thing somebody did may
  // have been to scrub through the heaviest ten seconds in the composition, and starting the
  // next play at a quarter size because of it would be punishing them for it.
  useEffect(() => {
    if (playing) setBeat(FRESH);
  }, [playing]);

  useEffect(() => {
    want.current = target;
    if (!target || busy.current) return;
    const el = canvas.current;
    if (!el) return;

    let alive = true;
    const surface = canvasSurface(el);
    const run = async () => {
      busy.current = true;
      let at = performance.now();
      await pump(
        () => want.current,
        () => alive,
        async (url) => {
          at = performance.now();
          const ok = await paint(url, surface, msOf(url));
          if (ok && alive) {
            setShowing(url);
            setPainted(true);
            // What that frame cost, end to end -- the renderer, the wire and the canvas -- fed
            // back into how big to ask for the next one. It is the whole trip that has to fit
            // in a frame interval, not the part of it the renderer measured.
            const took = performance.now() - at;
            if (moving.current) setBeat((was) => pace(was, took, budget));
          }
          return ok;
        },
        (url) => span("drop", at, performance.now() - at, msOf(url)),
      );
      busy.current = false;
    };
    void run();
    return () => {
      alive = false;
    };
  }, [target, canvas]);

  // Warm what comes next. Only while playing: a paused person is not about to need the next
  // six frames, and asking for them would compete with the one they are looking at.
  //
  // How many is not a constant. The renderer is one queue, so warming is a loan against the
  // frame somebody is actually looking at: worth taking when frames are cheap, and the thing
  // making them dearer when they are not.
  const ahead = warmth(beat.cost * scale * scale, budget, most);
  useEffect(() => {
    if (!playing || !(fps > 0) || w <= 0 || h <= 0) return;
    for (let i = 1; i <= ahead; i += 1) {
      const at = t + i / fps;
      if (at > duration) break;
      // The same size the live frame is being asked for, or the warm one is a different cache
      // key and the whole run was spent filling a shelf nobody reaches for.
      const url = frameUrl(base, variation, hash, at, fw, fh);
      if (warmed.current.has(url)) continue;
      warmed.current.add(url);
      warm(url);
    }
    // The set is per (variation, hash, size) and cleared with them; capping it keeps a long
    // composition from remembering every frame it ever warmed.
    if (warmed.current.size > 4096) warmed.current.clear();
  }, [playing, t, fps, duration, ahead, base, variation, hash, w, h, fw, fh]);

  return { painted, behind: showing !== target, scale };
}
