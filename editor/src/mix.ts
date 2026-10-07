// The mix, playing.
//
// `sound.ts` decides what should be heard; this puts it through the speakers. It is kept apart
// from that on purpose — the arithmetic is testable and this is not, so as little as possible
// lives here.
//
// The shape is the one every scheduler-on-Web-Audio has: an `AudioContext` whose clock is the
// truth, a window of a second or so scheduled ahead of the playhead, and a tick that tops the
// window up. Clips are decoded once and kept; a ten minute edit with seventy sounds in it holds
// them all, which is a few tens of megabytes and far cheaper than decoding one twice.
//
// Nothing here knows a path. A sound is fetched by the name the composition gave it, from a
// route the app answers out of what the engine said — the same rule the picture follows.

import { cue, type Cued } from "./sound";
import type { AudioView } from "./types";

/** How far ahead to schedule. Long enough to survive a slow tick, short enough that stopping
 *  is immediate to a person rather than to a machine. */
const WINDOW = 1.2;
/** How often to top the window up. */
const TICK = 400;

type Ctx = AudioContext & { decodeAudioData(b: ArrayBuffer): Promise<AudioBuffer> };

export interface Sounded {
  /** What is playing, so the caller can stop it. */
  stop(): void;
}

/**
 * One composition's sound, played against the transport.
 *
 * `at()` is asked for the playhead whenever it is needed rather than being pushed one, because
 * the transport moves on its own clock and a number handed over is a number already stale.
 */
export class Mix {
  private ctx: Ctx | null = null;
  private out: GainNode | null = null;
  private held = new Map<string, AudioBuffer | null>();
  private asking = new Set<string>();
  private live: AudioBufferSourceNode[] = [];
  private timer: ReturnType<typeof setInterval> | null = null;
  /** Where the window has been filled up to, in composition time. */
  private filled = 0;
  /** The context's own clock at the moment the playhead was `filled`. */
  private anchor = 0;

  constructor(
    private variation: string,
    private base: string,
  ) {}

  /** What the app has of the mix. Changed whenever the composition does. */
  private mix: AudioView[] = [];
  private duration = 0;

  holds(mix: AudioView[], duration: number) {
    this.mix = mix;
    this.duration = duration;
  }

  /** Start sounding from `t`. Safe to call again while playing: it is a seek. */
  async play(t: number) {
    const ctx = this.wake();
    if (ctx.state === "suspended") await ctx.resume();
    this.silence();
    this.filled = t;
    this.anchor = ctx.currentTime;
    this.fill(true);
    if (this.timer === null) {
      this.timer = setInterval(() => this.fill(false), TICK);
    }
  }

  /** Stop, at once. */
  stop() {
    if (this.timer !== null) {
      clearInterval(this.timer);
      this.timer = null;
    }
    this.silence();
  }

  /** How loud everything is, 0..1. The one control that is about listening rather than about
   *  the composition — it changes nothing that is written down and nothing that is exported. */
  setLevel(v: number) {
    const out = this.wake() && this.out;
    if (out) out.gain.value = Math.max(0, Math.min(1, v));
  }

  /** Let go of the audio device. */
  close() {
    this.stop();
    this.ctx?.close().catch(() => {});
    this.ctx = null;
    this.out = null;
    this.held.clear();
  }

  // --------------------------------------------------------------------------------- inside

  private wake(): Ctx {
    if (!this.ctx) {
      const Ctor =
        (window as unknown as { AudioContext?: typeof AudioContext }).AudioContext ??
        (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
      this.ctx = new Ctor!() as Ctx;
      this.out = this.ctx.createGain();
      this.out.connect(this.ctx.destination);
    }
    return this.ctx;
  }

  private silence() {
    for (const node of this.live) {
      try {
        node.stop();
      } catch {
        // already finished; nothing to stop
      }
    }
    this.live = [];
  }

  /** Top the window up. `fresh` means the playhead just moved, so what is already sounding has
   *  to be joined rather than waited for. */
  private fill(fresh: boolean) {
    const ctx = this.ctx;
    if (!ctx || !this.out) return;
    // Where the playhead is now, by the context's clock — which is the only clock that agrees
    // with what is coming out of the speakers.
    const now = this.filled + (ctx.currentTime - this.anchor);
    if (now >= this.duration) {
      this.stop();
      return;
    }
    const at = fresh ? this.filled : Math.max(this.filled, now);
    const ahead = fresh ? WINDOW : Math.max(0, now + WINDOW - at);
    if (ahead <= 0) return;

    for (const c of cue(this.mix, this.duration, at, ahead, fresh)) {
      const buffer = this.held.get(c.node);
      if (buffer === undefined) {
        void this.fetch(c.node);
        continue; // it will be there for the next window; one late cue is better than a stall
      }
      if (buffer === null) continue; // it would not decode, and said so once
      this.start(ctx, buffer, c, ctx.currentTime + (at - now) + c.after);
    }
    this.filled = at + ahead;
  }

  private start(ctx: Ctx, buffer: AudioBuffer, c: Cued, when: number) {
    if (c.from >= buffer.duration) return;
    const node = ctx.createBufferSource();
    node.buffer = buffer;
    const gain = ctx.createGain();
    gain.gain.setValueAtTime(Math.max(0.0001, c.gain), when);
    if (c.rampTo) {
      gain.gain.linearRampToValueAtTime(Math.max(0.0001, c.rampTo[1]), when + c.rampTo[0]);
    }
    if (c.rampDown) {
      const [after, over] = c.rampDown;
      gain.gain.setValueAtTime(gain.gain.value, when + after);
      gain.gain.linearRampToValueAtTime(0.0001, when + after + over);
    }
    node.connect(gain).connect(this.out!);
    node.start(Math.max(when, ctx.currentTime), c.from, c.lasts);
    node.onended = () => {
      this.live = this.live.filter((n) => n !== node);
    };
    this.live.push(node);
  }

  private async fetch(node: string) {
    if (this.asking.has(node)) return;
    this.asking.add(node);
    try {
      const url = `${this.base}sound/${encodeURIComponent(this.variation)}/${encodeURIComponent(node)}`;
      const res = await fetch(url);
      if (!res.ok) throw new Error(String(res.status));
      const bytes = await res.arrayBuffer();
      this.held.set(node, await this.wake().decodeAudioData(bytes));
    } catch {
      // A sound the app cannot read is silent, once. It is not worth a notice: the person asked
      // to hear the edit, not to be told which of seventy files has a codec nobody has.
      this.held.set(node, null);
    } finally {
      this.asking.delete(node);
    }
  }
}
