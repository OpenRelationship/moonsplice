// The timeline, derived. Pure functions over the outline, so what the timeline draws is a
// function of the composition and nothing else — no local copy, nothing to keep in step.
//
// The shape of this file is the shape of every timeline a person has already used:
//
//   * A **clip** is the stretch of time a thing is on screen. It is the widest thing in a lane
//     and its width means something, because the engine measured it rather than the app guessing
//     (`core/moonsplice/onscreen.lua`). This is the one convention every editor shares, and reading
//     it needs no explanation.
//   * A lane's **rows** are its properties, one row each, named — the layer-property model. They
//     are hidden until the lane is opened, because a composition with thirty things in it has a
//     hundred properties and all of them at once is the thing that made this unreadable.
//   * Lanes are **grouped and ordered** the way a layer list is: what is in front is at the top,
//     children sit under the thing that holds them, and sound is below a divider — it is read
//     differently from picture and every editor separates it.
//
// The distinction `app-shell` asks for survives all of that and is still structural, not
// decorative: a **movement** relates two values over a duration, and a **pin** is a value
// somebody put at an instant. They come from different parts of the timeline model (`record` vs
// `record_step`), so the UI cannot get them the wrong way round.

import { names, property } from "../format";
import type { AudioView, CueView, NodeView, Outline, Segment, Track } from "../types";

// Time, zoom, snapping and gaps live in scale.ts; these names stay importable from here.
export {
  clampZoom,
  easeShape,
  edges,
  fitZoom,
  fraction,
  gapAfter,
  restep,
  snap,
  ticks,
  timeAt,
  ZOOM_MAX,
  ZOOM_MIN,
  zoomStep,
} from "./scale";

export interface Mark {
  /** When it sits, in seconds. */
  t: number;
  prop: string;
  segment: Segment;
  /** Index of this segment among the ones on the same property — what `occurrence` means. */
  occurrence: number;
}

export interface Bar {
  t0: number;
  t1: number;
  prop: string;
  segment: Segment;
  occurrence: number;
}

/** A stretch of time a thing is on screen, measured by the engine. */
export interface Clip {
  t0: number;
  t1: number;
}

/** One property of one thing: its own row, with its own name. */
export interface Row {
  prop: string;
  /** "Across", "Visibility" — the words the app says for it. */
  name: string;
  bars: Bar[];
  marks: Mark[];
}

export type Group = "picture" | "sound";

export interface Lane {
  node: NodeView;
  /** What to call it, unambiguous across this composition. */
  name: string;
  group: Group;
  /** How far under a parent it sits. 0 for anything that is not held by something else. */
  depth: number;
  /** When it is on screen. Empty means never, which the lane says rather than drawing a lie. */
  clips: Clip[];
  /** One per property, in the order the app lists properties. */
  rows: Row[];
  /** Movements across every property, for the closed lane's marks. */
  bars: Bar[];
  /** Pins across every property, for the closed lane's marks. */
  marks: Mark[];
  /** Spoken lines, for a captions lane. */
  cues: CueView[];
  /** Sound, for an audio lane. */
  audio?: AudioView;
  /** Something the app cannot paint; the lane says so instead of drawing a lie. */
  unpaintable?: string;
  /** Set when what this thing needed is not on the disk. The lane keeps its place, its length
   *  and everything on it — an offline clip is still an edit — and draws itself as what it is.
   *  One word, from the renderer; `offlineWhy` in `format.ts` says it out loud. */
  offline?: string;
}

const AUDIO_KINDS = new Set(["audio", "tts", "music", "sfx"]);

export function isAudio(kind: string): boolean {
  return AUDIO_KINDS.has(kind);
}

/** A note pinned to a moment, read off the composition.
 *
 *  It is a node like anything else -- which is what makes putting one in, moving it, renaming it
 *  and taking it out the verbs the app already had -- but it is not a *lane*. A lane is a thing
 *  that is on screen for a stretch of time, and a note is neither on screen nor a stretch. It
 *  goes on the ruler, where every editor puts it and where it is read as "something happens
 *  here" rather than "something is here". */
export interface Note {
  id: string;
  at: number;
  text: string;
}

export function isNote(kind: string): boolean {
  return kind === "marker";
}

export function notes(outline: Outline): Note[] {
  return (outline.nodes ?? [])
    .filter((n) => isNote(n.kind))
    .map((n) => ({
      id: n.id,
      at: typeof n.props?.at === "number" ? n.props.at : 0,
      text: typeof n.props?.text === "string" ? n.props.text : "",
    }))
    .sort((a, b) => a.at - b.at);
}

/** Lanes, grouped and ordered the way a layer list is: front first, children under their
 *  parent, sound last. */
export function lanes(outline: Outline): Lane[] {
  const duration = outline.comp?.duration ?? 0;
  const byNode = new Map<string, Track[]>();
  for (const t of outline.tracks ?? []) {
    const list = byNode.get(t.node);
    if (list) list.push(t);
    else byNode.set(t.node, [t]);
  }
  const cuesByNode = new Map<string, CueView[]>();
  for (const c of outline.cues ?? []) {
    const list = cuesByNode.get(c.node);
    if (list) list.push(c);
    else cuesByNode.set(c.node, [c]);
  }
  const audioById = new Map((outline.audio ?? []).map((a) => [a.id, a]));
  const unpaintable = new Map((outline.cli_only ?? []).map((c) => [c.node, c.why]));
  const nodes = outline.nodes ?? [];
  const named = names(nodes);

  const one = (node: NodeView, depth: number): Lane => {
    const tracks = byNode.get(node.id) ?? [];
    const rows: Row[] = [];
    const bars: Bar[] = [];
    const marks: Mark[] = [];
    for (const track of tracks) {
      const rowBars: Bar[] = [];
      const rowMarks: Mark[] = [];
      track.segments.forEach((segment, occurrence) => {
        // A spoken line is recorded the same way a hand-pinned value is, and it is not one. The
        // engine tags it; the lane draws it as a line, once, from `cues`.
        if (segment.kind === "cue") return;
        if (segment.manual) {
          rowMarks.push({ t: segment.t0, prop: track.prop, segment, occurrence });
        } else {
          rowBars.push({ t0: segment.t0, t1: segment.t1, prop: track.prop, segment, occurrence });
        }
      });
      if (rowBars.length === 0 && rowMarks.length === 0) continue;
      rowBars.sort((a, b) => a.t0 - b.t0);
      rowMarks.sort((a, b) => a.t - b.t);
      rows.push({ prop: track.prop, name: property(track.prop), bars: rowBars, marks: rowMarks });
      bars.push(...rowBars);
      marks.push(...rowMarks);
    }
    rows.sort((a, b) => a.name.localeCompare(b.name));
    bars.sort((a, b) => a.t0 - b.t0 || a.prop.localeCompare(b.prop));
    marks.sort((a, b) => a.t - b.t || a.prop.localeCompare(b.prop));
    const cues = (cuesByNode.get(node.id) ?? []).slice().sort((a, b) => a.t0 - b.t0);
    const audio = audioById.get(node.id);
    return {
      node,
      name: named.get(node.id) ?? node.id,
      group: audio || isAudio(node.kind) ? "sound" : "picture",
      depth,
      clips: clipsOf(node, { audio, cues, duration }),
      rows,
      bars,
      marks,
      cues,
      audio,
      unpaintable: unpaintable.get(node.id),
      offline: node.offline,
    };
  };

  // Front first. A composition paints in build order, so the last thing built is nearest the
  // front, and a layer list puts the front at the top — the same order the preview reads in.
  const children = new Map<string | undefined, NodeView[]>();
  for (const n of nodes) {
    const key = n.parent && nodes.some((o) => o.id === n.parent) ? n.parent : undefined;
    const list = children.get(key);
    if (list) list.push(n);
    else children.set(key, [n]);
  }

  const out: Lane[] = [];
  const walk = (parent: string | undefined, depth: number) => {
    const list = (children.get(parent) ?? []).slice().reverse();
    for (const node of list) {
      // A note is on the ruler, not in the lanes. Given one it would draw an empty row saying
      // "never on screen", which is true and useless.
      if (isNote(node.kind)) continue;
      out.push(one(node, depth));
      walk(node.id, depth + 1);
    }
  };
  walk(undefined, 0);

  // Sound below picture, each keeping the order it already had.
  return [...out.filter((l) => l.group === "picture"), ...out.filter((l) => l.group === "sound")];
}

/** When a thing is on screen.
 *
 *  The engine measures this and the app does not second-guess it. Before it did, every lane drew
 *  a bar across the whole composition, which is the same as drawing nothing: the widest shape in
 *  the timeline carried no information. An older engine that does not send the measurement gets
 *  the old answer, so the app still runs against it. */
function clipsOf(
  node: NodeView,
  it: { audio?: AudioView; cues: CueView[]; duration: number },
): Clip[] {
  if (node.onscreen) {
    return node.onscreen
      .filter((c) => c.t1 > c.t0)
      .map((c) => ({ t0: c.t0, t1: Math.min(c.t1, it.duration) }));
  }
  if (it.audio) {
    const t0 = it.audio.at;
    const t1 = it.audio.duration != null ? t0 + it.audio.duration : it.duration;
    return [{ t0, t1: Math.min(t1, it.duration) }];
  }
  if (it.cues.length > 0) {
    return [{ t0: it.cues[0].t0, t1: Math.min(it.cues[it.cues.length - 1].t1, it.duration) }];
  }
  return [{ t0: 0, t1: it.duration }];
}
