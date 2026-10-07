import { type Lane, isAudio } from "./lanes";

/** Where a time sits in a track, 0..1. */
export function fraction(t: number, duration: number): number {
  if (!(duration > 0)) return 0;
  return Math.max(0, Math.min(1, t / duration));
}

/** The time a click at `x` fraction means, snapped to a frame. */
export function timeAt(x: number, duration: number, fps: number): number {
  const t = Math.max(0, Math.min(1, x)) * duration;
  if (!(fps > 0)) return t;
  return Math.round(t * fps) / fps;
}

/** Ticks a person can count: about one every 80px, on a round number of seconds. */
export function ticks(duration: number, width: number): number[] {
  if (!(duration > 0) || !(width > 0)) return [];
  const want = Math.max(2, Math.floor(width / 80));
  const raw = duration / want;
  const steps = [0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60];
  const step = steps.find((s) => s >= raw) ?? 60;
  const out: number[] = [];
  for (let t = 0; t <= duration + 1e-9; t += step) {
    out.push(Math.round(t * 1000) / 1000);
  }
  return out;
}

/** Sampled easing, for the little curve drawn inside a movement. Cheap and approximate: it
 *  says "this accelerates" rather than claiming to be the renderer's own function. */
export function easeShape(ease: string | undefined): number[] {
  const f = EASES[ease ?? "linear"] ?? EASES.linear;
  return Array.from({ length: 16 }, (_, i) => f(i / 15));
}

const EASES: Record<string, (k: number) => number> = {
  linear: (k) => k,
  sineIn: (k) => 1 - Math.cos((k * Math.PI) / 2),
  sineOut: (k) => Math.sin((k * Math.PI) / 2),
  sineInOut: (k) => -(Math.cos(Math.PI * k) - 1) / 2,
  quadIn: (k) => k * k,
  quadOut: (k) => 1 - (1 - k) ** 2,
  quadInOut: (k) => (k < 0.5 ? 2 * k * k : 1 - (-2 * k + 2) ** 2 / 2),
  cubicIn: (k) => k ** 3,
  cubicOut: (k) => 1 - (1 - k) ** 3,
  cubicInOut: (k) => (k < 0.5 ? 4 * k ** 3 : 1 - (-2 * k + 2) ** 3 / 2),
  expoIn: (k) => (k === 0 ? 0 : 2 ** (10 * k - 10)),
  expoOut: (k) => (k === 1 ? 1 : 1 - 2 ** (-10 * k)),
  expoInOut: (k) =>
    k === 0 ? 0 : k === 1 ? 1 : k < 0.5 ? 2 ** (20 * k - 10) / 2 : (2 - 2 ** (-20 * k + 10)) / 2,
  backOut: (k) => 1 + 2.70158 * (k - 1) ** 3 + 1.70158 * (k - 1) ** 2,
  backIn: (k) => 2.70158 * k ** 3 - 1.70158 * k ** 2,
  elasticOut: (k) =>
    k === 0 ? 0 : k === 1 ? 1 : 2 ** (-10 * k) * Math.sin((k * 10 - 0.75) * ((2 * Math.PI) / 3)) + 1,
  bounceOut: (k) => {
    const n = 7.5625;
    const d = 2.75;
    if (k < 1 / d) return n * k * k;
    if (k < 2 / d) return n * (k -= 1.5 / d) * k + 0.75;
    if (k < 2.5 / d) return n * (k -= 2.25 / d) * k + 0.9375;
    return n * (k -= 2.625 / d) * k + 0.984375;
  },
};

// --------------------------------------------------------------------------------- zoom

/** How much of a second a pixel is worth, and the range a person can ask for.
 *
 *  A timeline that only ever fits the composition to the pane is unreadable the moment the
 *  composition is long: at a minute wide, a quarter-second movement is two pixels. So the scale
 *  is a number, `fit` is one value of it, and the rest is scrolling. */
/** The coarsest a person may zoom *out* to by hand: eight pixels a second, which is about the
 *  narrowest a clip can be and still be worth clicking. */
export const ZOOM_MIN = 8;
export const ZOOM_MAX = 1200;
/** The coarsest scale that is still a scale. Only fitting reaches it, and only for something
 *  very long: at a twentieth of a pixel a second, five and a half hours fits in a laptop pane. */
const FLOOR = 0.05;

/**
 * The scale that shows the whole composition.
 *
 * Fit means fit. This used to clamp to `ZOOM_MIN` like everything else, and on a ten minute edit
 * that is not a rounding difference -- 600 seconds at eight pixels a second is 4,800 pixels in a
 * 670 pixel pane, so "fit the pane" showed the first eighty seconds and the Fit button was greyed
 * out because, as far as the app knew, it was already fitted. There was no way to see a long edit
 * whole. The floor that keeps a clip clickable is for zooming out by hand, where there is always
 * further out to go; it has no business overriding the one request that has a right answer.
 */
export function fitZoom(duration: number, width: number): number {
  if (!(duration > 0) || !(width > 0)) return 100;
  return Math.max(FLOOR, Math.min(ZOOM_MAX, width / duration));
}

/** A scale a person asked for, held between what is useful and what is possible. `floor` is the
 *  fitted scale when the caller knows it: you can never zoom out past seeing all of it, which is
 *  what every editor does and what stops zooming out from zooming in. */
export function clampZoom(pps: number, floor = ZOOM_MIN): number {
  if (!Number.isFinite(pps)) return 100;
  return Math.max(Math.min(floor, ZOOM_MIN), Math.min(ZOOM_MAX, pps));
}

/** Zoom in or out by one step, keeping `anchor` (a time) under the same pixel. Returns the new
 *  scale and the scroll offset that holds the anchor still. */
export function zoomStep(
  pps: number,
  by: number,
  anchor: number,
  anchorPx: number,
  /** The scale that shows all of it. Zooming out stops here: past it there is nothing further
   *  to see, and on a long edit the fitted scale is coarser than `ZOOM_MIN`, so without this
   *  a step outward would step inward. */
  floor = ZOOM_MIN,
): { pps: number; scroll: number } {
  const next = clampZoom(pps * 1.3 ** by, floor);
  return { pps: next, scroll: Math.max(0, anchor * next - anchorPx) };
}

/** One step up or down the stack, said the way the composition takes it.
 *
 *  The lane list is front first, the way a layer list always is, and the composition is written
 *  back to front — so moving a thing one step toward the front means naming the thing it now
 *  paints over. `null` for `over` is the very back, behind everything.
 *
 *  Only among its own siblings: a thing held inside something else moves within that something,
 *  and never out of it, because out of it is a different place in the picture and not a step. */
export function restep(
  all: Lane[],
  node: string,
  dir: "forward" | "back",
): { node: string; over: string | null } | null {
  const mine = all.find((l) => l.node.id === node);
  if (!mine || mine.group !== "picture") return null;
  const siblings = all.filter(
    (l) => l.group === "picture" && l.depth === mine.depth && l.node.parent === mine.node.parent,
  );
  const i = siblings.findIndex((l) => l.node.id === node);
  if (i < 0) return null;
  if (dir === "forward") {
    return i === 0 ? null : { node, over: siblings[i - 1].node.id };
  }
  if (i >= siblings.length - 1) return null;
  const over = siblings[i + 2]?.node.id ?? null;
  // The very back of the scene is only the very back for something the scene holds directly.
  if (over === null && mine.node.parent) return null;
  return { node, over };
}

/** Everything a dragged clip should catch on: the playhead, the ends of the composition, and
 *  where every other clip starts and stops. Its own edges are left out — a clip cannot snap to
 *  where it already is — and so is anything further than a screenful, which would be a magnet
 *  nobody asked for. */
export function edges(all: Lane[], exclude: string, duration: number, playhead: number): number[] {
  const out = new Set<number>([0, duration, playhead]);
  for (const lane of all) {
    if (lane.node.id === exclude) continue;
    for (const clip of lane.clips) {
      out.add(clip.t0);
      out.add(clip.t1);
    }
  }
  return [...out].sort((a, b) => a - b);
}

/** The nearest edge within `within` pixels, or the time itself. Pixels rather than seconds,
 *  because what a person means by "next to" is what they can see, and that changes with zoom. */
export function snap(t: number, targets: number[], pps: number, within = 7): number {
  let best = t;
  let gap = within / Math.max(pps, 1e-6);
  for (const target of targets) {
    const d = Math.abs(target - t);
    if (d < gap) {
      gap = d;
      best = target;
    }
  }
  return best;
}

/** The hole that follows a clip, if there is one.
 *
 * "Follows" is within its own kind: a hole in the narration is the stretch before the next thing
 * you would hear, and the pictures above it have nothing to do with it. That is the same rule
 * the app applies when it closes one, and it has to be the same rule that draws it — a hole you
 * can see and cannot close would be worse than one nobody drew.
 *
 * Anything that is animated after the hole makes it uncloseable, and the app says so when asked;
 * this does not try to guess that here, because a hole you can see and are told why about is the
 * honest pair.
 */
export function gapAfter(
  all: Lane[],
  node: string,
  duration: number,
): { t0: number; t1: number } | null {
  const mine = all.find((l) => l.node.id === node);
  if (!mine || mine.clips.length === 0) return null;
  const sound = isAudio(mine.node.kind);
  const ends = Math.max(...mine.clips.map((c) => c.t1));
  let next: number | null = null;
  for (const lane of all) {
    if (lane.node.id === node || isAudio(lane.node.kind) !== sound) continue;
    for (const clip of lane.clips) {
      if (clip.t0 > ends + 1e-6 && (next === null || clip.t0 < next)) next = clip.t0;
    }
  }
  if (next === null) return null;
  // A hole shorter than a tenth of a second is a rounding difference, not a hole.
  if (next - ends < 0.1 || next > duration + 1e-6) return null;
  return { t0: ends, t1: next };
}
