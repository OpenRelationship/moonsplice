// The one door to Rust. Every call the UI makes goes through here, and so does every call the
// agent makes — `src-tauri/src/lib.rs` hands the agent's tool bodies the same functions.
//
// Nothing in this file holds a copy of a composition. It holds a hash.

import { invoke } from "@tauri-apps/api/core";
import { listen } from "@tauri-apps/api/event";
import { Channel } from "@tauri-apps/api/core";

import type {
  Applied,
  AssetView,
  CompChanged,
  ConnectAnswer,
  ConnectAsk,
  ConnectFound,
  ConnectNeeds,
  ConnectRecorded,
  Connection,
  Gesture,
  Opened,
  ProjectView,
  Refused,
  SourceView,
  TurnChunk,
} from "./types";

export function isRefused(e: unknown): e is Refused {
  return typeof e === "object" && e !== null && (e as Refused).refused === true;
}

/** Whatever came back from Rust, as one sentence a person can read. */
export function why(e: unknown): string {
  if (isRefused(e)) return e.why;
  if (typeof e === "string") return e;
  if (e instanceof Error) return e.message;
  return "something did not work";
}

export const bridge = {
  openProject: (path: string) => invoke<ProjectView>("open_project", { path }),
  project: () => invoke<ProjectView>("project"),
  openVariation: (variation: string) => invoke<Opened>("open_variation", { variation }),
  closeVariation: (variation: string) => invoke<void>("close_variation", { variation }),
  frameBase: () => invoke<string>("frame_base"),
  assetBase: () => invoke<string>("asset_base"),
  /** An asset, ready to show or play. The window never learns where it is. */
  assetSource: (asset: string) => invoke<SourceView>("asset_source", { asset }),
  /** What a sound looks like: the loudest sample in each of 512 slices, 0..255. Asked for by
   *  the name the composition gave the sound, because the window has no path for it. */
  soundShape: (variation: string, node: string) =>
    invoke<number[]>("sound_shape", { variation, node }),

  gesture: (variation: string, gesture: Gesture) =>
    invoke<Applied>("apply_gesture", { variation, gesture }),
  /** Put a thing from the project into the composition, at the time it was dropped on. */
  placeAsset: (variation: string, asset: string, t?: number) =>
    invoke<Applied>("place_asset", { variation, asset, t: t ?? null }),
  undo: (variation: string) => invoke<string>("undo", { variation }),
  redo: (variation: string) => invoke<string>("redo", { variation }),

  addComposition: (title: string, width: number, height: number, into?: string) =>
    invoke<ProjectView>("add_composition", { title, width, height, into: into ?? null }),
  addVariation: (composition: string, width: number, height: number) =>
    invoke<ProjectView>("add_variation", { composition, width, height }),
  addAssets: (paths: string[], into?: string) =>
    invoke<AssetView[]>("add_assets", { paths, into: into ?? null }),
  dropPaths: (paths: string[], into?: string) =>
    invoke<AssetView[]>("drop_paths", { paths, into: into ?? null }),

  /** The project's folders are real directories, so these are real moves. */
  addFolder: (parent: string, name: string) =>
    invoke<ProjectView>("add_folder", { parent: parent || null, name }),
  moveItem: (id: string, into: string) =>
    invoke<ProjectView>("move_item", { id, into: into || null }),
  renameFolder: (at: string, name: string) =>
    invoke<ProjectView>("rename_folder", { at, name }),

  export: (variation: string, quality?: string) =>
    invoke<string>("export", { variation, quality }),

  stopTurn: () => invoke<void>("stop_turn"),

  setKey: (name: string, value: string) => invoke<void>("set_key", { name, value }),
  keyIsSet: (name: string) => invoke<boolean>("key_is_set", { name }),

  /** Other people's apps (.robot/docs/connect.robot). What agents are waiting on the person for,
   *  and what is connected: names only, never a value. */
  connectAsks: () => invoke<ConnectAsk[]>("connect_asks"),
  connections: () => invoke<Connection[]>("connect_list"),
  connectNeeds: (service: string) => invoke<ConnectNeeds>("connect_needs", { service }),
  connectFind: (words: string) => invoke<ConnectFound[]>("connect_find", { words }),
  /** The values go to the keychain on the other side and are never sent back. */
  connectSave: (service: string, values: Record<string, string>) =>
    invoke<ConnectRecorded>("connect_save", { service, values }),
  connectAnswer: (service: string, op: string, answer: ConnectAnswer) =>
    invoke<{ service: string; op: string; answer: ConnectAnswer }>("connect_answer", {
      service,
      op,
      answer,
    }),
  connectForget: (service: string) => invoke<void>("connect_forget", { service }),
  connectLogo: (service: string) => invoke<string | null>("connect_logo", { service }),
  /** The service's documentation, in the browser. Rust looks the address up itself. */
  connectDocs: (service: string) => invoke<void>("connect_docs", { service }),
  /** What playback is costing, per stage. Asked for while playing, so the app can say which of
   *  the four steps is eating the budget rather than only that it is behind. */
  playback: (budgetMs: number) => invoke<PlaybackReport>("playback", { budgetMs }),

  /** One turn. Chunks arrive on the channel; there is no HTTP server anywhere. */
  askAgent(
    variation: string,
    prompt: string,
    history: { role: string; text: string }[],
    onChunk: (chunk: TurnChunk) => void,
  ) {
    const channel = new Channel<TurnChunk>();
    channel.onmessage = onChunk;
    return invoke<void>("ask_agent", { variation, prompt, history, channel });
  },
};

/** A composition changed — by a drag, by the agent, or by a text editor outside the app. */
export function onComp(f: (e: CompChanged) => void) {
  return listen<CompChanged>("comp", (e) => f(e.payload));
}

/** A composition that is open stopped re-reading, or started again. `why` is null when it has
 *  come back. The preview goes on painting the last version that loaded, so without this the
 *  window and the file quietly stop being the same composition. */
export interface TroubleEvent {
  variation: string;
  why: string | null;
}

export function onTrouble(f: (e: TroubleEvent) => void) {
  return listen<TroubleEvent>("trouble", (e) => f(e.payload));
}

export function onProject(f: (p: ProjectView) => void) {
  return listen<ProjectView>("project", (e) => f(e.payload));
}

export interface ExportEvent {
  variation: string;
  state: "running" | "done" | "failed";
  /** What the composition is called. Never where the video went. */
  title: string;
  why?: string;
}

export function onExport(f: (e: ExportEvent) => void) {
  return listen<ExportEvent>("export", (e) => f(e.payload));
}

/** Microseconds, at the three points worth knowing. */
export interface Spread {
  p50: number;
  p95: number;
  worst: number;
}

export interface PlaybackReport {
  served: number;
  hits: number;
  warmed: number;
  dropped: number;
  frames: number;
  hit_rate: number;
  live: Spread;
  wait: Spread;
  render: Spread;
  read: Spread;
  encode: Spread;
  waiting: number;
  tracing: boolean;
  /** One sentence about why the preview is behind, or nothing when it is not. */
  why: string | null;
}

/** Spans the window measured, on their way into the same trace as the renderer's. Failing to
 *  report them is never worth telling anybody about: it is a measurement, not the work. */
export function report(spans: { name: string; at_ms: number; dur_ms: number; t_ms?: number }[]) {
  return invoke<void>("report_playback", { spans }).catch(() => {});
}

/** The URL of one frame. Every part of the cache key is in the path, so the webview's own
 *  cache is correct for free and a changed composition asks for a different URL. */
export function frameUrl(
  base: string,
  variation: string,
  hash: string,
  t: number,
  w: number,
  h: number,
): string {
  const ms = Math.max(0, Math.round(t * 1000));
  // `.raw` is the pixels themselves, which is what the preview paints. `.jpg` is the same frame
  // as a picture, for anything that wants one -- and it is a different entry in the cache,
  // because they are not interchangeable.
  return `${base}${encodeURIComponent(variation)}/${hash}/${ms}/${Math.round(w)}x${Math.round(h)}.raw`;
}
