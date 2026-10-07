import { useEffect, useState } from "react";
import { bridge } from "../bridge";

/** Every sound shape the window has asked for, by composition and name.
 *
 *  A module-level map rather than state, because the answer does not change while the app is
 *  open and two lanes of the same sound must not ask twice. `null` is "asked and there is no
 *  answer" -- a sound that would not read is not asked about again. */
const SHAPES = new Map<string, number[] | null>();
const ASKING = new Set<string>();

/** The shape of one sound, fetched the first time a lane wants it. */
export function useShape(variation: string, node: string, wanted: boolean): number[] | null {
  const key = `${variation}\u0000${node}`;
  const [shape, setShape] = useState<number[] | null>(() => SHAPES.get(key) ?? null);

  useEffect(() => {
    if (!wanted || SHAPES.has(key)) {
      setShape(SHAPES.get(key) ?? null);
      return;
    }
    if (ASKING.has(key)) return;
    ASKING.add(key);
    let alive = true;
    bridge
      .soundShape(variation, node)
      .then((peaks) => {
        SHAPES.set(key, peaks);
        if (alive) setShape(peaks);
      })
      .catch(() => {
        // A sound the app cannot read is drawn as a plain bar. It is not worth a notice: the
        // person did not ask for a waveform, they asked for a timeline.
        SHAPES.set(key, null);
      })
      .finally(() => ASKING.delete(key));
    return () => {
      alive = false;
    };
  }, [key, node, variation, wanted]);

  return shape;
}
