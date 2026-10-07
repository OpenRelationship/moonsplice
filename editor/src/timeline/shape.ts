// What a sound looks like, and how to draw it.
//
// The app asks Rust for the loudest sample in each of five hundred slices; this turns that into
// one SVG path, mirrored about the middle the way every editor has drawn a waveform since tape.
// One path rather than five hundred rectangles, because a ten minute edit has seventy sound
// lanes and seventy times five hundred is a timeline that scrolls like a slideshow.

/** The box the path is drawn in. It is stretched to the bar, so these are not pixels. */
export const BOX = { w: 1000, h: 100 };

/**
 * One closed path: along the top from left to right, back along the bottom.
 *
 * `peaks` are 0..255. A flat 0 still draws a hairline through the middle — a sound that is
 * silent is still a sound that is there, and a bar with nothing in it reads as a bar that failed
 * to load.
 */
export function wavePath(peaks: number[]): string {
  if (peaks.length === 0) return "";
  const mid = BOX.h / 2;
  const at = (i: number) => (i * BOX.w) / (peaks.length - 1 || 1);
  const up: string[] = [];
  const down: string[] = [];
  for (let i = 0; i < peaks.length; i += 1) {
    // A floor of one unit: the line stays visible through a silence.
    const half = Math.max(1, (peaks[i] / 255) * (mid - 2));
    up.push(`${at(i).toFixed(1)} ${(mid - half).toFixed(1)}`);
    down.push(`${at(peaks.length - 1 - i).toFixed(1)} ${(mid + half).toFixed(1)}`);
  }
  return `M${up.join("L")}L${down.join("L")}Z`;
}

/** Fewer points, for a bar too narrow to show them. Takes the loudest of each group, never the
 *  average: an average of a transient is a transient nobody can see. */
export function coarser(peaks: number[], want: number): number[] {
  if (want <= 0 || peaks.length <= want) return peaks;
  const out: number[] = [];
  for (let i = 0; i < want; i += 1) {
    const from = Math.floor((peaks.length * i) / want);
    const to = Math.max(from + 1, Math.floor((peaks.length * (i + 1)) / want));
    let loudest = 0;
    for (let k = from; k < to && k < peaks.length; k += 1) {
      if (peaks[k] > loudest) loudest = peaks[k];
    }
    out.push(loudest);
  }
  return out;
}

/**
 * The slice of a sound that a clip actually plays.
 *
 * A clip is a window on its file: it starts `mediaStart` seconds in and runs for `duration`. The
 * shape is of the whole file, so drawing all of it inside a trimmed clip would draw the part
 * that was trimmed away. `whole` is how long the file is; without it there is nothing to slice
 * against and the shape is drawn as it came.
 */
export function windowed(
  peaks: number[],
  mediaStart: number,
  duration: number,
  whole?: number,
): number[] {
  if (!whole || whole <= 0 || peaks.length === 0) return peaks;
  const from = Math.max(0, Math.min(1, mediaStart / whole));
  const to = Math.max(from, Math.min(1, (mediaStart + duration) / whole));
  if (to - from >= 0.999) return peaks;
  const a = Math.floor(from * peaks.length);
  const b = Math.max(a + 1, Math.ceil(to * peaks.length));
  return peaks.slice(a, Math.min(b, peaks.length));
}
