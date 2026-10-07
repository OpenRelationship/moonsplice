// The preview, heard.
//
// Until now the preview was silent: a composition's mix is made by ffmpeg at encode, so the only
// way to hear your own narration was to render the whole thing. For an edit with sixty spoken
// lines in it that is not an editor, it is a renderer with a picture attached.
//
// This file is the part that decides *what* should be sounding and *when* — a pure function of
// the mix and a moment, with no audio API anywhere in it, because the arithmetic is the whole of
// the difficulty and the arithmetic is what goes wrong. `Mix` in `mix.ts` drives Web Audio with
// what this says.

import type { AudioView } from "./types";

/** One sound, told when to start, where in itself to start, and how loud to be on the way. */
export interface Cued {
  /** The thing, by the name the composition gave it. */
  node: string;
  /** How long from now until it should be heard. Zero means it should already be sounding. */
  after: number;
  /** How far into its own file to begin. */
  from: number;
  /** How long to play for. */
  lasts: number;
  /** Loudness at the moment it starts, fades taken into account. */
  gain: number;
  /** The rest of a fade-in it is in the middle of: [seconds remaining, the level to reach]. */
  rampTo: [number, number] | null;
  /** When to begin fading out, from the start of this cue, and over how long. */
  rampDown: [number, number] | null;
}

/** How long a clip runs for, taking the composition's end as the limit when it says nothing. */
export function spanOf(a: AudioView, duration: number): [number, number] {
  const t0 = a.at;
  const t1 = a.duration != null ? t0 + a.duration : duration;
  return [t0, Math.min(t1, duration)];
}

/**
 * How loud a clip is `into` seconds after it began.
 *
 * A clip started in the middle of its own fade-in has to begin part way up the ramp — not at
 * nothing and not at full — which is the one thing "just play from here" gets audibly wrong.
 */
export function level(a: AudioView, into: number, whole: number): number {
  const gain = a.volume ?? 1;
  if (whole <= 0 || into < 0 || into > whole) return 0;
  const up = a.fade_in ?? 0;
  const down = a.fade_out ?? 0;
  let at = gain;
  if (up > 0 && into < up) at = Math.min(at, gain * (into / up));
  if (down > 0 && into > whole - down) at = Math.min(at, gain * ((whole - into) / down));
  return Math.max(0, at);
}

/**
 * Everything that should be heard between `from` and `from + window`.
 *
 * There are two kinds of call and the difference between them is the whole of the bookkeeping.
 * A **fresh** one — playback starting, or starting again somewhere else — has to pick up every
 * clip that overlaps the window, including the ones already half way through themselves. A
 * continuation, as the window slides forward, must pick up only the clips that *begin* in it:
 * the others are already sounding, and cueing them again would play them twice.
 */
export function cue(
  mix: AudioView[],
  duration: number,
  from: number,
  window: number,
  fresh: boolean,
): Cued[] {
  const until = from + window;
  const out: Cued[] = [];
  for (const a of mix) {
    if ((a.volume ?? 1) === 0) continue; // silenced in the composition; nothing to hear
    const [t0, t1] = spanOf(a, duration);
    if (t1 <= from || t0 >= until) continue;
    // A continuation only starts what starts here. A fresh one joins what is already running.
    if (!fresh && t0 < from) continue;

    const begins = Math.max(t0, from);

    const whole = t1 - t0;
    const into = begins - t0;
    const lasts = Math.min(t1, until) - begins;
    if (lasts <= 0) continue;

    const up = a.fade_in ?? 0;
    const down = a.fade_out ?? 0;
    const full = a.volume ?? 1;
    // Part of the fade-in still to do, if it started inside one.
    const rampTo: [number, number] | null = up > into && up > 0 ? [up - into, full] : null;
    // The fade-out, said relative to this cue rather than to the clip.
    const startsDown = whole - down - into;
    const rampDown: [number, number] | null =
      down > 0 && startsDown < lasts ? [Math.max(0, startsDown), down] : null;

    out.push({
      node: a.id,
      after: begins - from,
      from: (a.media_start ?? 0) + into,
      lasts,
      gain: level(a, into, whole),
      rampTo,
      rampDown,
    });
  }
  // Soonest first, so a window that has to be cut short loses the far end.
  return out.sort((x, y) => x.after - y.after || x.node.localeCompare(y.node));
}

/** Whether two moments are within a frame of each other, which is when a seek is not a seek. */
export function samePlace(a: number, b: number, fps: number): boolean {
  const frame = fps > 0 ? 1 / fps : 1 / 30;
  return Math.abs(a - b) < frame / 2;
}
