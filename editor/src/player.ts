// The frame pump.
//
// A preview is not an `<img src>` bound to the playhead. Bound that way, a 60 Hz playhead mints
// sixty URLs a second, the webview queues sixty requests against a renderer that can serve
// maybe a hundred, and every one of them arrives too late to be the current frame. The picture
// lags, and because `src` changes before the new bytes land, whatever stands in for "not loaded
// yet" flashes between every pair of frames. That reads as broken rather than slow.
//
// So: one request in flight, ever. A new target while one is loading replaces the target, it
// does not queue behind it -- the frames in between are frames nobody will see. What the pane
// shows is the last frame that actually painted, so it never shows nothing, and it never shows
// a half-painted anything.
//
// And no codec. A frame arrives as the pixels it already was, and goes onto a canvas as
// `ImageData` -- measured at about 2 ms against the 40-odd a JPEG cost to encode on one side and
// decode on the other, which was most of a 33 ms budget spent turning pixels into pixels. The
// window asks for the frame at device resolution; the renderer never upscales, so a composition
// smaller than the pane simply arrives at its own size.
//
// Playback keeps real time: the playhead advances on the wall clock and drops frames the
// renderer could not reach, the same bargain every player makes. What it must never do is drift
// off the frame grid, because a time between frames is a cache key nobody asks for twice --
// `seek` in the store snaps it, and this file counts on that.

import { useEffect, useRef, useState, type RefObject } from "react";

import { frameUrl, report } from "./bridge";

/** What the window measured, on its way to the trace. Flushed in batches, never per frame. */
type Span = { name: string; at_ms: number; dur_ms: number; t_ms?: number };

let pending: Span[] = [];
let flushing = false;

function span(name: string, at: number, dur: number, t_ms?: number) {
  pending.push({ name, at_ms: at, dur_ms: dur, t_ms });
  if (pending.length < 24 || flushing) return;
  flushing = true;
  const batch = pending;
  pending = [];
  void report(batch).finally(() => {
    flushing = false;
  });
}

/** Somewhere to put a frame. A canvas, in the window; something that counts, in a test.
 *
 *  The split exists so the frame path can be tested at all: a canvas in a test environment has
 *  no drawing context, so without this the one piece of the preview nothing else covers -- bytes
 *  in, picture out -- would only ever be checked by looking at it. */
export interface Surface {
  put(pixels: Uint8ClampedArray<ArrayBuffer>, w: number, h: number): void;
}

export function canvasSurface(canvas: HTMLCanvasElement): Surface {
  return {
    put(pixels, w, h) {
      const ctx = canvas.getContext("2d", { alpha: false });
      if (!ctx) return;
      if (canvas.width !== w || canvas.height !== h) {
        canvas.width = w;
        canvas.height = h;
      }
      ctx.putImageData(new ImageData(pixels, w, h), 0, 0);
    },
  };
}

/** How many bytes a raw frame spends saying how big it is: two 32-bit numbers, little-endian. */
export const STAMP = 8;

/** A frame, fetched and painted. Returns false if it could not be had.
 *
 *  Refusing is not an error: a frame that 404s is a composition that closed, and a body shorter
 *  than the size it claims is a frame that was cut off. Either way the pane keeps the last
 *  picture that was actually whole, which is the one rule the preview has.
 *
 *  **The size is read out of the frame, not out of a header.** It was in `x-frame-width` and
 *  `x-frame-height`, which is the tidy way to send it and does not work here: the page is served
 *  from one scheme and the frames from another, so every fetch of one is cross-origin, and a
 *  cross-origin response only lets script read the handful of headers CORS safelists. Those two
 *  came back `null`, the width was zero, every frame was refused as "not whole", and the preview
 *  showed its checkerboard forever -- for a renderer that was making frames perfectly well. Eight
 *  bytes on the front of the pixels cannot be stripped by anything between here and there. */
export async function paint(url: string, surface: Surface, t_ms?: number): Promise<boolean> {
  const started = performance.now();
  try {
    const res = await fetch(url);
    if (!res.ok) return false;
    const buf = await res.arrayBuffer();
    if (buf.byteLength < STAMP) return false;
    const stamp = new DataView(buf, 0, STAMP);
    const w = stamp.getUint32(0, true);
    const h = stamp.getUint32(4, true);
    if (!(w > 0) || !(h > 0) || buf.byteLength - STAMP < w * h * 4) return false;
    const got = performance.now();
    span("fetch", started, got - started, t_ms);
    surface.put(new Uint8ClampedArray(buf, STAMP, w * h * 4), w, h);
    span("paint", got, performance.now() - got, t_ms);
    return true;
  } catch {
    return false;
  }
}

/** Paint the newest frame wanted, and keep painting until the picture has caught up.
 *
 *  One request in flight, ever. Whatever was asked for while one was loading replaces the target
 *  rather than queueing behind it, because the frames in between are frames nobody will see --
 *  and each one of those is counted as a drop rather than quietly skipped, which is what makes
 *  "the preview is choppy" a number instead of a feeling. */
export async function pump(
  want: () => string | null,
  alive: () => boolean,
  paintOne: (url: string) => Promise<boolean>,
  dropped: (url: string) => void,
): Promise<void> {
  let url = want();
  while (alive() && url) {
    await paintOne(url);
    if (!alive()) return;
    const next = want();
    if (next === url) return;
    dropped(url);
    url = next;
  }
}

/** Fire and forget: have the renderer make a frame and keep it, without carrying it over here. A
 *  warm request answers with nothing at all -- the point is the frame that is now in the cache. */
export function warm(url: string) {
  void fetch(`${url}?warm=1`).catch(() => {});
}

// ---------------------------------------------------------------------------- keeping up

/**
 * The sizes a moving picture is allowed to be, as a fraction of the pane.
 *
 * Every editor in the world does this and says so in a menu: while it is playing you are
 * watching *timing*, and a preview at half width has four times less to rasterise. The steps are
 * few on purpose. Each distinct size is its own cache key and its own canvas resize, so a scale
 * that slid continuously would never hit the cache twice and would re-key the whole warmed run
 * every time the load changed by a hair.
 */
export const SCALES = [1, 0.75, 0.5, 1 / 3, 0.25];

/** How the player is keeping up: the size it is asking for, and what a frame has been costing. */
export interface Pace {
  /** Which of `SCALES` the moving picture is being drawn at. */
  scale: number;
  /**
   * Smoothed cost of a frame in ms, **as if it had been drawn full size**. Zero until the first
   * one lands.
   *
   * Normalising is the whole trick. Measurements arrive at whatever size was being asked for at
   * the time, and averaging those together compares a quarter-size frame with a full one — which
   * is how a controller ends up ratcheting itself down to the floor on frames that were cheap
   * precisely because it had already made them small.
   */
  cost: number;
  /** Consecutive frames with room to spare. Stepping back up waits for a few of these. */
  good: number;
}

export const FRESH: Pace = { scale: 1, cost: 0, good: 0 };

/**
 * The largest allowed size whose frame would fit in the budget.
 *
 * Rasterising costs about what the picture has area, so a frame that took `took` at `at` would
 * take `took * (s/at)^2` at `s`. Solving that for the budget gives the size to ask for, and it
 * is snapped *down* to a step -- a controller that aims exactly at the budget spends its life
 * one frame over it.
 */
export function scaleFor(took: number, budget: number, at: number): number {
  if (!(took > 0) || !(budget > 0) || !(at > 0)) return at;
  const ideal = at * Math.sqrt(budget / took);
  for (const s of SCALES) {
    if (s <= ideal + 1e-9) return s;
  }
  return SCALES[SCALES.length - 1];
}

/**
 * What to ask for next, having just spent `took` ms on a frame.
 *
 * Down is immediate and up is slow, which is the only asymmetry in here and the whole of its
 * manners. Falling behind is something a person sees at once, so the picture gets smaller the
 * moment it happens; getting sharper again is something they are pleased by rather than waiting
 * for, so it takes a few easy frames and then goes up one step, not all the way. A player that
 * jumped straight back to full size would spend a busy passage flickering between two sizes,
 * which reads far worse than the smaller one.
 */
export function pace(was: Pace, took: number, budget: number): Pace {
  if (!(took > 0) || !(budget > 0) || !(was.scale > 0)) return was;
  // What that frame would have cost at full size, so it can be averaged with the others.
  const unit = took / (was.scale * was.scale);
  // Smoothed, because one slow frame is a hiccup and three is a scene.
  const cost = was.cost > 0 ? was.cost * 0.7 + unit * 0.3 : unit;
  const want = scaleFor(cost, budget, 1);
  if (want < was.scale) return { scale: want, cost, good: 0 };
  if (want > was.scale) {
    const good = was.good + 1;
    if (good < 4) return { scale: was.scale, cost, good };
    const up = SCALES[Math.max(0, SCALES.indexOf(was.scale) - 1)];
    return { scale: up, cost, good: 0 };
  }
  return { scale: was.scale, cost, good: 0 };
}

/** How many frames it is worth warming ahead, given what one costs.
 *
 *  Warming is not free: the renderer is one queue, and six frames nobody has reached yet is six
 *  frames of its time spent while the frame somebody *is* looking at waits. When frames are
 *  cheap, warming is most of what makes the second pass smooth; when they are dear, it is the
 *  thing making them dearer. So it is asked for in proportion to what fits. */
export function warmth(cost: number, budget: number, most: number): number {
  if (!(cost > 0) || !(budget > 0)) return most;
  return Math.max(1, Math.min(most, Math.round((budget / cost) * most)));
}

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

/** The milliseconds a frame URL names, for the trace. */
function msOf(url: string): number | undefined {
  const parts = url.split("/");
  const n = Number(parts[parts.length - 2]);
  return Number.isFinite(n) ? n : undefined;
}

/**
 * Playback on the wall clock.
 *
 * `onTick` gets the time it should be, not the time plus one frame: a player that counts frames
 * runs slow by exactly however long the renderer took, and by the end of a minute it is visibly
 * behind the audio it will eventually be married to.
 */
export function useClock(
  playing: boolean,
  duration: number,
  from: () => number,
  onTick: (t: number) => void,
  rate = 1,
  onEnd?: () => void,
) {
  useEffect(() => {
    if (!playing || !(duration > 0) || rate === 0) return;
    let raf = 0;
    const started = performance.now();
    const at = from();
    const step = (now: number) => {
      const elapsed = (now - started) / 1000;
      const t = at + elapsed * rate;
      // Going forward it wraps, which is what watching something over and over wants. Going
      // backwards it stops at the top, because there is nothing before the start of a
      // composition and wrapping to the end would be a surprise rather than a convenience.
      if (t <= 0 && rate < 0) {
        onTick(0);
        onEnd?.();
        return;
      }
      onTick(t >= duration ? t % duration : t);
      raf = requestAnimationFrame(step);
    };
    raf = requestAnimationFrame(step);
    return () => cancelAnimationFrame(raf);
    // `from` and `onTick` read and write the store, which is stable.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [playing, duration, rate]);
}

// ------------------------------------------------------------------------------- the shuttle

/**
 * The speeds J and L step through.
 *
 * The ladder every editor has, and the reason it is a ladder rather than a number is that a
 * person shuttling is not choosing a speed, they are pressing a key until the picture moves at
 * about the rate they want. Doubling is what that feels like. There is no zero in it: stopping
 * is K, and a speed of nothing is not a speed.
 */
export const RATES = [-8, -4, -2, -1, 1, 2, 4, 8];

/**
 * Where J, K or L takes the transport from the speed it is at.
 *
 * L steps up the ladder and J steps down, so from full reverse L slows the reverse, crosses over
 * and speeds up forwards -- one key, one direction, the whole range. K stops, always and from
 * anywhere. Starting from a stop, L plays and J plays backwards, which is what pressing them
 * means to somebody who has not pressed anything yet.
 */
export function shuttle(rate: number, key: "j" | "k" | "l"): number {
  if (key === "k") return 0;
  const i = RATES.indexOf(rate);
  if (i < 0) return key === "l" ? 1 : -1;
  const next = key === "l" ? i + 1 : i - 1;
  return RATES[Math.min(RATES.length - 1, Math.max(0, next))];
}

/** How a speed is said out loud. Never "1x": at the speed it was shot, nobody says a number. */
export function saidRate(rate: number): string | null {
  if (rate === 1) return null;
  if (rate === 0) return "stopped";
  if (rate === -1) return "backwards";
  if (rate < 0) return `${-rate}x backwards`;
  return `${rate}x`;
}
