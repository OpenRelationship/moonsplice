// The shapes Rust sends. Nothing here is a file path: the app shows compositions, things and
// movements, never a name with a dot in it.

export type AssetKind = "footage" | "image" | "audio" | "font" | "data" | "other";

export interface AssetView {
  id: string;
  name: string;
  kind: AssetKind;
  size: number | null;
}

export interface VariationView {
  id: string;
  title: string;
  aspect: string;
  empty: boolean;
}

export interface CompositionView {
  id: string;
  title: string;
  variations: VariationView[];
}

export interface ProjectView {
  name: string;
  compositions: CompositionView[];
  assets: AssetView[];
  /** How the left pane draws them: the project's own folders, which are real directories. */
  tree: TreeItem[];
}

/** One row of the left pane. A folder is a directory; the other two are things you can open. */
export type TreeItem =
  | { what: "folder"; name: string; at: string; items: TreeItem[] }
  | { what: "composition"; comp: CompositionView }
  | { what: "asset"; asset: AssetView };

/** One asset, ready to look at: an id, a name, and a URL Rust will serve the bytes on. */
export interface SourceView {
  id: string;
  name: string;
  kind: AssetKind;
  url: string;
  media: string;
}

export interface CompMeta {
  width: number;
  height: number;
  duration: number;
  fps: number;
}

export type Scalar = number | string | boolean | number[] | null;

export interface NodeView {
  id: string;
  kind: string;
  index: number;
  label?: string | null;
  perspective?: boolean;
  props?: Record<string, Scalar>;
  /** What holds it, when something does. The timeline indents a group's children under it. */
  parent?: string;
  /** When this thing is on screen, measured by the engine rather than inferred by the app. An
   *  empty list means never; a missing one means an engine that does not measure it yet. */
  onscreen?: { t0: number; t1: number }[];
  /** Set when what this thing needed is not on the disk: one word from a closed set, turned
   *  into a sentence by `offlineWhy` in `format.ts`. Absent is the normal case. Deliberately a
   *  word rather than the renderer's message — that message names a file, and no file name
   *  reaches this side. */
  offline?: string;
}

/** A tween is a relation; a pin is a value somebody put there. Structurally different. */
export interface Segment {
  kind: "tween" | "pin" | "cue" | "step" | "path" | "bake" | "wiggle";
  t0: number;
  t1: number;
  manual: boolean;
  ease?: string;
  overshoot?: boolean;
  from?: Scalar;
  to?: Scalar;
}

export interface Track {
  node: string;
  index: number;
  prop: string;
  segments: Segment[];
}

export interface CueView {
  node: string;
  index: number;
  t0: number;
  t1: number;
  text: string;
}

export interface AudioView {
  id: string;
  kind: string;
  at: number;
  duration?: number;
  /** How far into its own file the clip begins. */
  media_start?: number;
  /** How long the file is, which is not how long the clip is. */
  media_duration?: number;
  /** Seconds of ramp at each end, which the preview honours and the render already does. */
  fade_in?: number;
  fade_out?: number;
  volume: number;
  bus: string | false;
  label?: string | null;
}

export interface CliOnly {
  node: string;
  kind: string;
  why: string;
}

export interface Outline {
  comp: {
    width: number;
    height: number;
    duration: number;
    fps: number;
    background: number[];
    direct: boolean;
    title?: string;
    /** 1 unless the composition was long enough that on-screen was sampled every N frames. */
    onscreen_stride?: number;
  };
  nodes: NodeView[];
  tracks: Track[];
  cues: CueView[];
  audio: AudioView[];
  cli_only: CliOnly[];
}

export interface Opened {
  variation: string;
  meta: CompMeta;
  hash: string;
  outline: Outline;
}

export interface CompChanged {
  variation: string;
  hash: string;
  what: string[];
  undo: number;
  redo: number;
  undo_label: string | null;
  redo_label: string | null;
  outline: Outline;
}

/** Every gesture the UI is allowed to make. One of these maps to a lowering verb, or it is
 *  refused — there is no third path. */
export type Gesture =
  | { gesture: "move"; node: string; x: number; y: number }
  | { gesture: "set_value"; node: string; key: string; value: number | string | boolean }
  | { gesture: "curve"; node: string; ease: string; occurrence?: number }
  | { gesture: "lengthen"; node: string; seconds: number; occurrence?: number }
  | { gesture: "line"; node: string; index: number; t0?: number; t1?: number; text?: string }
  | { gesture: "pin"; node: string; t: number; key: string; value: number }
  | { gesture: "remove"; node: string }
  /** Dragging a clip or a sound along the track: it begins at `t` now. */
  | { gesture: "slide"; node: string; t: number }
  /** Dragging one end of a clip: the front of it, or the back, lands at `t`. */
  | { gesture: "trim"; node: string; edge: "in" | "out"; t: number }
  /** The razor: one clip becomes two, joined at `t`. */
  | { gesture: "split"; node: string; t: number }
  /** Dragging a movement's left edge: it begins at `t` now, and what follows moves with it. */
  | { gesture: "move_start"; node: string; t: number; occurrence?: number }
  /** Up or down the stack: it now paints over `over`, or over nothing, which is the very back. */
  | { gesture: "restack"; node: string; over: string | null }
  /** Take it out and pull the rest of its own kind up by its length. */
  | { gesture: "take_out_and_close"; node: string }
  /** Close the hole that follows a clip, without taking anything out. */
  | { gesture: "close_gap"; after: string }
  /** Pin a note to a moment. The one thing in a composition that is neither seen nor heard. */
  | { gesture: "mark"; t: number; text: string };

export interface Refused {
  refused: true;
  why: string;
  kind: { kind: string } & Record<string, unknown>;
}

export interface Applied {
  hash: string;
  what: string[];
  undo: number;
  redo: number;
}

/** What a turn says as it runs. `ask` is the only one that waits for an answer. */
export type TurnChunk =
  | { event: "start"; budget: number }
  | { event: "step"; step: number; budget: number }
  | { event: "call"; step: number; call: string; tool: string; ask: boolean }
  | { event: "result"; call: string; tool: string; ok: boolean; refused: boolean; size: number }
  | { event: "stop"; stop: string; reason?: string; steps: number }
  | {
      event: "ask";
      id: number;
      tool: string;
      args: unknown;
      reason: string | null;
      can_remember: boolean;
    }
  | {
      event: "answer";
      stop: string;
      reason?: string | null;
      answer?: string | null;
      steps?: number;
      notes?: string[];
    };

// ------------------------------------------------------------------------------ connections

/** One thing a service needs to be connected: a token, an account id. Only its name and label
 *  ever reach the window; the value goes from the field to the keychain. */
export interface ConnectField {
  name: string;
  label: string;
  secret: boolean;
}

/** Something an agent is waiting on the person for (.robot/docs/connect.robot). */
export interface ConnectAsk {
  id: string;
  kind: "connect" | "approve";
  service: string;
  name?: string | null;
  op?: string | null;
  method?: string | null;
  fields: ConnectField[];
  docs?: string | null;
  why?: string | null;
  at?: string | null;
  status?: string | null;
}

export interface Connection {
  service: string;
  fields: string[];
  at?: string | null;
}

export interface ConnectNeeds {
  service: string;
  name: string;
  docs?: string | null;
  fields: ConnectField[];
  missing: string[];
}

export interface ConnectFound {
  service: string;
  name: string;
  categories: string[];
  operations: number;
  docs?: string | null;
}

export interface ConnectRecorded {
  service: string;
  fields: string[];
  checked: boolean;
}

export type ConnectAnswer = "once" | "always" | "deny";
