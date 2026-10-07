// What the composition actually shows at the playhead.
//
// The outline carries what somebody *wrote* — the number in the constructor. This carries what
// the movements made of it. The two differ the moment anything is animated, and a field reading
// `Visibility 0` beside a label you can plainly see is the kind of small lie an editor never
// recovers from.
//
// Both the stage and the inspector want the same answer at the same moment, so they ask once.
// The key is the whole question — which composition, which source, which frame — so a stale
// answer is not a thing that can happen.

import { useEffect, useState } from "react";
import { invoke } from "@tauri-apps/api/core";

export interface Instant {
  t: number;
  nodes: { id: string; kind: string; label?: string | null; props?: Record<string, unknown> }[];
}

const answers = new Map<string, Instant>();
const asking = new Map<string, Promise<Instant | null>>();

export function keyOf(variation: string, hash: string, t: number): string {
  return `${variation}\u0000${hash}\u0000${Math.round(t * 1000)}`;
}

/** Ask, or reuse the answer somebody already got. Never more than one request in flight for the
 *  same question, however many panes want it. */
export function instantAt(variation: string, hash: string, t: number): Promise<Instant | null> {
  const key = keyOf(variation, hash, t);
  const known = answers.get(key);
  if (known) return Promise.resolve(known);
  const running = asking.get(key);
  if (running) return running;
  const p = invoke<Instant>("instant", { variation, t })
    .then((v) => {
      answers.set(key, v);
      // A composition is small and a frame is a frame; a few hundred answers is nothing, and
      // dropping the oldest keeps a long scrub from growing without bound.
      if (answers.size > 400) answers.delete(answers.keys().next().value as string);
      return v;
    })
    .catch(() => null)
    .finally(() => asking.delete(key));
  asking.set(key, p);
  return p;
}

/** The instant, while paused. During playback nobody is reading it and one request per frame
 *  would be one request per frame wasted. */
export function useInstant(
  variation: string | null,
  hash: string | null,
  t: number,
  paused: boolean,
): Instant | null {
  const [value, setValue] = useState<Instant | null>(null);
  useEffect(() => {
    if (!variation || !hash || !paused) return;
    const key = keyOf(variation, hash, t);
    const known = answers.get(key);
    if (known) {
      setValue(known);
      return;
    }
    let alive = true;
    const id = window.setTimeout(() => {
      void instantAt(variation, hash, t).then((v) => {
        if (alive) setValue(v);
      });
    }, 40);
    return () => {
      alive = false;
      window.clearTimeout(id);
    };
  }, [variation, hash, t, paused]);
  return value;
}

/** What a property is right now, or nothing if this moment has no answer yet. */
export function valueNow(
  instant: Instant | null,
  node: string,
  key: string,
): unknown | undefined {
  if (!Array.isArray(instant?.nodes)) return undefined;
  return instant.nodes.find((n) => n.id === node)?.props?.[key];
}
