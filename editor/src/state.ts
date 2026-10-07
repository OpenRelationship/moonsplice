// Ephemeral state, and only ephemeral state.
//
// `project-sync` names three kinds and keeps them apart. This store holds the third: the
// playhead, which tab is in front, what is selected, how big the panes are. None of it is
// persisted and none of it is a copy of a composition — the composition is the `.lua`, and what
// the UI holds about it is a hash and the outline Rust sent with it.
//
// There is no `dirty` flag. If saving were a separate act, the two copies would already have
// diverged.

import { create } from "zustand";

import { clampZoom } from "./timeline/lanes";
import type { CompMeta, Outline, ProjectView, SourceView } from "./types";

/** One tab: a composition. Its shape is a property of the tab, not a tab of its own — the left
 *  pane lists compositions, the way an editor's project panel does, and a composition that has a
 *  wide and a vertical cut is still one thing. */
export interface Tab {
  variation: string;
  composition: string;
  title: string;
  aspect: string;
  meta: CompMeta;
  /** The source hash. Every frame URL carries it, so invalidation is free. */
  hash: string;
  outline: Outline;
  undo: number;
  redo: number;
  undoLabel: string | null;
  redoLabel: string | null;
  /** Why what is on the disk stopped loading, while it is stopped. The preview keeps painting
   *  the last version that worked -- which is the right picture to keep showing and the wrong
   *  one to show without saying so. */
  trouble?: string | null;
}

export interface Selection {
  node: string | null;
  /** Which movement is selected, if the click was on one. */
  prop?: string;
  occurrence?: number;
}

export interface Notice {
  id: number;
  tone: "said" | "refused" | "working";
  text: string;
}

interface Studio {
  project: ProjectView | null;
  tabs: Tab[];
  active: string | null;
  playhead: number;
  playing: boolean;
  selection: Selection;
  notices: Notice[];
  frameBase: string;
  /** Where a composition's sounds are served from. Set once, at startup. */
  assetBase: string;
  agentOpen: boolean;
  libraryOpen: boolean;
  /** How tall the timeline is, in px. A person with six things wants more of it than the
   *  default; a person judging a frame wants none of it. */
  timelineHeight: number;
  /** Which lanes are showing what changes over time. Closed is the default, because a
   *  composition with thirty things in it has a hundred properties. */
  openLanes: string[];
  /** Pixels per second in the timeline, or null for "fit the pane" — which is the default, and
   *  the only scale a short composition needs. */
  zoom: number | null;
  /** The asset loaded for a look, the way double-clicking footage in an editor loads it into a
   *  source viewer. It sits beside the compositions rather than replacing one. */
  source: SourceView | null;
  /** Which of the two the centre is showing. */
  viewing: "comp" | "source";
  /** Which side panel is in front: the project, or what the selected thing can do. */
  sidebar: "project" | "effects";
  /** How loud the preview is, 0..1. The one number in here that is about listening rather than
   *  about the composition: it changes nothing that is written down and nothing that is
   *  exported, so it is not an edit and never reaches the source. */
  listening: number;
  /** How fast the transport is running, and which way. 1 is the speed it was shot at; J and L
   *  step through the ladder in `player.ts`. Only meaningful while `playing`. */
  rate: number;

  setProject(p: ProjectView | null): void;
  setFrameBase(b: string): void;
  setAssetBase(b: string): void;
  addTab(tab: Tab): void;
  closeTab(variation: string): void;
  activate(variation: string): void;
  updateTab(variation: string, patch: Partial<Tab>): void;
  seek(t: number): void;
  toggleLane(node: string): void;
  setZoom(pps: number | null): void;
  setSidebar(which: "project" | "effects"): void;
  showSource(source: SourceView): void;
  closeSource(): void;
  showComp(): void;
  setPlaying(p: boolean): void;
  select(s: Selection): void;
  say(tone: Notice["tone"], text: string): void;
  dismiss(id: number): void;
  toggleAgent(): void;
  toggleLibrary(): void;
  setTimelineHeight(h: number): void;
  setListening(v: number): void;
  /** Set the speed. A speed of nothing stops the transport, because that is what it means. */
  setRate(r: number): void;
}

let noticeId = 0;

export const useStudio = create<Studio>((set, get) => ({
  project: null,
  tabs: [],
  active: null,
  playhead: 0,
  playing: false,
  selection: { node: null },
  notices: [],
  frameBase: "cframe://localhost/",
  assetBase: "casset://localhost/",
  agentOpen: true,
  libraryOpen: true,
  timelineHeight: 228,
  openLanes: [],
  zoom: null,
  source: null,
  viewing: "comp",
  sidebar: "project",
  listening: 0.8,
  rate: 1,

  setProject: (project) => set({ project }),
  setFrameBase: (frameBase) => set({ frameBase }),
  setAssetBase: (assetBase) => set({ assetBase }),

  addTab: (tab) =>
    set((s) => {
      // One tab per composition. Opening another shape of something already open changes that
      // tab's shape in place rather than making a second tab of the same thing, which is what
      // "the pane lists compositions" has to mean once you can look at two shapes of one.
      const existing = s.tabs.findIndex(
        (t) => t.composition === tab.composition || t.variation === tab.variation,
      );
      const tabs = s.tabs.slice();
      if (existing >= 0) tabs[existing] = tab;
      else tabs.push(tab);
      return {
        tabs,
        active: tab.variation,
        viewing: "comp",
        playhead: 0,
        selection: { node: null },
        openLanes: [],
        zoom: null,
      };
    }),

  closeTab: (variation) =>
    set((s) => {
      const tabs = s.tabs.filter((t) => t.variation !== variation);
      const active =
        s.active === variation ? (tabs[tabs.length - 1]?.variation ?? null) : s.active;
      return { tabs, active, selection: { node: null } };
    }),

  activate: (variation) =>
    set({
      active: variation,
      viewing: "comp",
      playhead: 0,
      selection: { node: null },
      openLanes: [],
      zoom: null,
    }),

  updateTab: (variation, patch) =>
    set((s) => ({
      tabs: s.tabs.map((t) => (t.variation === variation ? { ...t, ...patch } : t)),
    })),

  seek: (t) => {
    const tab = get().tabs.find((x) => x.variation === get().active);
    const max = tab?.meta.duration ?? 0;
    const fps = tab?.meta.fps ?? 0;
    // Snapped to a frame, every time, wherever the time came from -- a click, a key, or the
    // wall clock during playback. A composition has no time between frames, so a playhead at
    // 1.0483s is a playhead pointing at nothing; and an unsnapped time is a cache key nothing
    // will ever ask for twice, which is what made the second pass of playback as slow as the
    // first.
    const clamped = Math.max(0, Math.min(t, max));
    set({ playhead: fps > 0 ? Math.round(clamped * fps) / fps : clamped });
  },

  // Pressing play is always pressing play at the speed a thing was shot at. Somebody who was
  // shuttling and hits the space bar means "watch it properly", not "carry on at four times".
  setPlaying: (playing) => set({ playing, rate: playing ? 1 : get().rate }),
  setRate: (rate) => set({ rate, playing: rate !== 0 }),
  setListening: (v) => set({ listening: Math.max(0, Math.min(1, v)) }),
  select: (selection) => set({ selection }),

  say: (tone, text) =>
    set((s) => ({
      notices: [...s.notices.filter((n) => n.text !== text), { id: ++noticeId, tone, text }].slice(
        -3,
      ),
    })),

  dismiss: (id) => set((s) => ({ notices: s.notices.filter((n) => n.id !== id) })),
  toggleAgent: () => set((s) => ({ agentOpen: !s.agentOpen })),
  toggleLibrary: () => set((s) => ({ libraryOpen: !s.libraryOpen })),
  setTimelineHeight: (h) => set({ timelineHeight: clampHeight(h) }),

  toggleLane: (node) =>
    set((s) => ({
      openLanes: s.openLanes.includes(node)
        ? s.openLanes.filter((n) => n !== node)
        : [...s.openLanes, node],
    })),

  // Clamped only at the top. The floor belongs to the timeline, which is the only thing that
  // knows how wide the pane is and therefore what "all of it" costs -- and on a ten minute edit
  // that is coarser than the floor a short composition wants.
  setZoom: (zoom) => set({ zoom: zoom == null ? null : clampZoom(zoom, 0) }),

  setSidebar: (sidebar) => set({ sidebar }),
  showSource: (source) => set({ source, viewing: "source" }),
  closeSource: () => set({ source: null, viewing: "comp" }),
  showComp: () => set({ viewing: "comp" }),
}));

/** Never so tall the preview is gone, never so short a lane is a sliver. */
export function clampHeight(h: number): number {
  const room = typeof window === "undefined" ? 900 : window.innerHeight;
  return Math.round(Math.max(132, Math.min(h, Math.max(180, room - 300))));
}

/** The tab in front, or nothing. */
export function activeTab(s: Pick<Studio, "tabs" | "active">): Tab | null {
  return s.tabs.find((t) => t.variation === s.active) ?? null;
}
