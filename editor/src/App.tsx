// The window. Three panes, custom chrome, and one place where an event from Rust lands.

import { useCallback, useEffect } from "react";
import { open as openDialog } from "@tauri-apps/plugin-dialog";

import { Agent } from "./agent/Agent";
import { bridge, onComp, onExport, onProject, onTrouble, why } from "./bridge";
import { Chrome } from "./chrome/Chrome";
import * as fmt from "./format";
import { Keys } from "./Keys";
import { Sidebar } from "./Sidebar";
import { shuttle } from "./player";
import { Stage } from "./stage/Stage";
import { Timeline } from "./timeline/Timeline";
import { lanes, restep } from "./timeline/lanes";
import { activeTab, clampHeight, useStudio } from "./state";
import { Button, Empty } from "./ui/bits";

export default function App() {
  const project = useStudio((s) => s.project);
  const setProject = useStudio((s) => s.setProject);
  const setFrameBase = useStudio((s) => s.setFrameBase);
  const setAssetBase = useStudio((s) => s.setAssetBase);
  const addTab = useStudio((s) => s.addTab);
  const updateTab = useStudio((s) => s.updateTab);
  const say = useStudio((s) => s.say);
  const notices = useStudio((s) => s.notices);
  const dismiss = useStudio((s) => s.dismiss);
  const libraryOpen = useStudio((s) => s.libraryOpen);
  const agentOpen = useStudio((s) => s.agentOpen);

  // A window that got shorter must not leave the timeline taller than the window.
  useEffect(() => {
    const onResize = () => {
      const s = useStudio.getState();
      const fixed = clampHeight(s.timelineHeight);
      if (fixed !== s.timelineHeight) s.setTimelineHeight(fixed);
    };
    window.addEventListener("resize", onResize);
    return () => window.removeEventListener("resize", onResize);
  }, []);

  useEffect(() => {
    void bridge.frameBase().then(setFrameBase);
    void bridge.assetBase().then(setAssetBase);
    // A project may already be open when the window reloads in development.
    bridge
      .project()
      .then(setProject)
      .catch(() => setProject(null));
  }, [setFrameBase, setAssetBase, setProject]);

  // One representation: when a composition changes — by a drag, by the agent, or by a text
  // editor outside the app — this is where the UI hears about it, and all it does is take the
  // new outline and the new hash. There is nothing to patch, because it holds no copy.
  useEffect(() => {
    const comp = onComp((e) => {
      updateTab(e.variation, {
        hash: e.hash,
        outline: e.outline,
        undo: e.undo,
        redo: e.redo,
        undoLabel: e.undo_label,
        redoLabel: e.redo_label,
      });
      if (e.what.length > 0) say("said", e.what[0]);
    });
    const trouble = onTrouble((e) => {
      updateTab(e.variation, { trouble: e.why });
      say(
        e.why ? "refused" : "said",
        e.why
          ? `That change stopped the composition loading: ${e.why}. What you can see is the last version that worked.`
          : "It loads again.",
      );
    });
    const proj = onProject((p) => setProject(p));
    const exp = onExport((e) => {
      // Where it went is the project, which is the one place a person can look for it. A file
      // name is not an answer to that question, and naming one here would be the only place in
      // the app that did.
      if (e.state === "done") say("said", `${e.title} is finished, and in your project`);
      if (e.state === "failed") say("refused", `${e.title} did not render: ${e.why ?? "the render did not finish"}`);
    });
    return () => {
      void comp.then((un) => un());
      void trouble.then((un) => un());
      void proj.then((un) => un());
      void exp.then((un) => un());
    };
  }, [say, setProject, updateTab]);

  const openVariation = useCallback(
    async (variation: string) => {
      const existing = useStudio.getState().tabs.find((t) => t.variation === variation);
      if (existing) {
        useStudio.getState().activate(variation);
        return;
      }
      const p = useStudio.getState().project;
      const comp = p?.compositions.find((c) => c.variations.some((v) => v.id === variation));
      const v = comp?.variations.find((x) => x.id === variation);
      try {
        const opened = await bridge.openVariation(variation);
        addTab({
          variation,
          composition: comp?.id ?? variation,
          title: comp?.title ?? opened.outline.comp.title ?? "Composition",
          aspect: v?.aspect ?? "16:9",
          meta: opened.meta,
          hash: opened.hash,
          outline: opened.outline,
          undo: 0,
          redo: 0,
          undoLabel: null,
          redoLabel: null,
        });
        // Anything in it that is not on the air, said once, when it opens. The composition is
        // open either way -- one file that moved no longer takes the whole edit down with it --
        // so this is the only moment the app gets to point at it before somebody plays to four
        // minutes and wonders why the picture went grey.
        const out = fmt.offlineSaid(opened.outline.nodes ?? []);
        if (out) say("refused", out);
      } catch (e) {
        say("refused", why(e));
      }
    },
    [addTab, say],
  );

  // The keyboard, on the composition in front.
  //
  // Space is the one that needs care. A focused button already activates on space, so a global
  // handler that also toggles playback makes two toggles and looks like a key that does
  // nothing — which is exactly what it looked like. Anything that handles space itself keeps
  // it; everything else falls through to here.
  useEffect(() => {
    const typing = (el: HTMLElement | null) =>
      !!el &&
      (el.tagName === "INPUT" ||
        el.tagName === "TEXTAREA" ||
        el.tagName === "SELECT" ||
        el.isContentEditable);
    const activates = (el: HTMLElement | null) =>
      !!el && (el.tagName === "BUTTON" || el.getAttribute("role") === "button");

    const onKey = async (e: KeyboardEvent) => {
      const tab = activeTab(useStudio.getState());
      if (!tab) return;
      const mod = e.metaKey || e.ctrlKey;
      const target = e.target as HTMLElement | null;
      if (typing(target)) return;

      // The razor, on the key every editor puts it on. It cuts the selected clip where the
      // playhead is, and says so -- or says why not, which is what happens when the playhead is
      // not over the clip at all.
      if (mod && e.key.toLowerCase() === "k") {
        const node = useStudio.getState().selection.node;
        if (!node) {
          say("refused", "Pick the clip to cut first");
          return;
        }
        e.preventDefault();
        try {
          const cut = await bridge.gesture(tab.variation, {
            gesture: "split",
            node,
            t: useStudio.getState().playhead,
          });
          say("said", cut.what[0] ?? "Cut it in two");
        } catch (err) {
          say("refused", why(err));
        }
        return;
      }

      // Up and down the stack, one step at a time, on the bracket keys every layer-based editor
      // uses. What it can move it moves; what has no front and back says so.
      if (mod && (e.key === "]" || e.key === "[")) {
        const node = useStudio.getState().selection.node;
        if (!node) return;
        e.preventDefault();
        const step = restep(lanes(tab.outline), node, e.key === "]" ? "forward" : "back");
        if (!step) {
          say("refused", "There is nowhere further to take it");
          return;
        }
        try {
          const moved = await bridge.gesture(tab.variation, { gesture: "restack", ...step });
          say("said", moved.what[0] ?? "Moved it");
        } catch (err) {
          say("refused", why(err));
        }
        return;
      }

      if (mod && e.key.toLowerCase() === "z") {
        e.preventDefault();
        try {
          say("said", e.shiftKey ? await bridge.redo(tab.variation) : await bridge.undo(tab.variation));
        } catch (err) {
          say("refused", why(err));
        }
        return;
      }

      // The shuttle, on the three keys every editor has had since tape. L speeds up forwards,
      // J speeds up backwards, K stops -- and L from full reverse slows the reverse, crosses
      // over and speeds up forwards, which is one key doing the whole range.
      if (!mod && (e.key === "j" || e.key === "k" || e.key === "l")) {
        e.preventDefault();
        const state = useStudio.getState();
        state.setRate(shuttle(state.rate, e.key as "j" | "k" | "l"));
        return;
      }

      // A note, where you are looking, on the key every editor puts it on. It goes in saying
      // what it is for -- a note called "Marker 3" is a note nobody reads -- and the flag on the
      // ruler opens straight into renaming it.
      if (!mod && e.key.toLowerCase() === "m") {
        e.preventDefault();
        const at = useStudio.getState().playhead;
        try {
          const made = await bridge.gesture(tab.variation, {
            gesture: "mark",
            t: at,
            text: `Note at ${fmt.seconds(at)}`,
          });
          say("said", made.what[0] ?? "Made a note");
        } catch (err) {
          say("refused", why(err));
        }
        return;
      }

      const state = useStudio.getState();
      const frame = tab.meta.fps > 0 ? 1 / tab.meta.fps : 1 / 30;
      switch (e.key) {
        case " ":
          if (activates(target)) return;
          e.preventDefault();
          state.setPlaying(!state.playing);
          return;
        case "ArrowLeft":
          if (activates(target)) return;
          e.preventDefault();
          state.setPlaying(false);
          state.seek(state.playhead - (e.shiftKey ? frame * 10 : frame));
          return;
        case "ArrowRight":
          if (activates(target)) return;
          e.preventDefault();
          state.setPlaying(false);
          state.seek(state.playhead + (e.shiftKey ? frame * 10 : frame));
          return;
        case "Home":
          e.preventDefault();
          state.seek(0);
          return;
        case "End":
          e.preventDefault();
          state.seek(tab.meta.duration);
          return;
        case "Escape":
          if (state.selection.node) {
            e.preventDefault();
            state.select({ node: null });
          }
          return;
        case "Backspace":
        case "Delete": {
          // The key a person reaches for. It takes the selected thing out, and the app says what
          // it took — or says why it could not, which is the case when something else in the
          // composition refers to it.
          //
          // With the modifier it closes the hole as well: everything of the thing's own kind
          // that came after it moves up by its length. That is the pairing every editor uses,
          // and the reason it is the same key is that they are the same decision — whether the
          // time it took stays in the composition.
          const node = state.selection.node;
          if (!node) return;
          e.preventDefault();
          state.select({ node: null });
          try {
            const gone = await bridge.gesture(
              tab.variation,
              mod ? { gesture: "take_out_and_close", node } : { gesture: "remove", node },
            );
            say("said", gone.what[0] ?? (mod ? "Took it out and closed the gap" : "Took it out"));
          } catch (err) {
            state.select({ node });
            say("refused", why(err));
          }
          return;
        }
        default:
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [say]);

  return (
    <div className="flex h-full flex-col">
      <Keys />
      <Chrome />
      {project ? (
        <div className="flex min-h-0 flex-1">
          {libraryOpen ? <Sidebar onOpen={openVariation} /> : null}
          <div className="flex min-w-0 flex-1 flex-col">
            <Stage />
            <Timeline />
          </div>
          {agentOpen ? <Agent /> : null}
        </div>
      ) : (
        <div className="flex min-h-0 flex-1 items-center justify-center">
          <Empty
            title="Open a project"
            hint="Moonsplice Studio works on a folder: the compositions in it, and the footage they use."
            action={
              <Button
                tone="solid"
                onClick={async () => {
                  const picked = await openDialog({ directory: true, multiple: false });
                  if (typeof picked !== "string") return;
                  try {
                    setProject(await bridge.openProject(picked));
                  } catch (e) {
                    say("refused", why(e));
                  }
                }}
              >
                Choose a folder
              </Button>
            }
          />
        </div>
      )}

      {/* What just happened, briefly, bottom left. A refusal is a sentence, never a dialog. */}
      <div className="pointer-events-none fixed bottom-3 left-3 z-40 flex flex-col gap-1.5">
        {notices.map((n) => (
          <button
            key={n.id}
            type="button"
            className="rise pointer-events-auto max-w-[380px] truncate rounded-[var(--radius)] border px-2.5 py-1.5 text-left text-[12px]"
            style={{
              background: "var(--ink-2)",
              borderColor: n.tone === "refused" ? "var(--warn)" : "var(--edge)",
              color: n.tone === "refused" ? "var(--warn)" : "var(--text-2)",
              boxShadow: "var(--shadow-lift)",
            }}
            onClick={() => dismiss(n.id)}
          >
            {n.text}
          </button>
        ))}
      </div>
    </div>
  );
}
