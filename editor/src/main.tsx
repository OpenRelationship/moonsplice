import { StrictMode } from "react";
import { createRoot } from "react-dom/client";

import App from "./App";
import "./app.css";

// In development the window answers questions about itself.
//
// The Rust half of this is in `src-tauri/src/lib.rs` behind `#[cfg(debug_assertions)]`: it opens
// a socket, and a question arrives here as an event that this listener answers. Both halves are
// needed -- without this one the socket is up, `health_check` replies, and everything that has to
// reach the DOM waits five seconds and times out, which is a confusing way to learn you installed
// half a thing.
//
// `bin/studio-ask` is the shell side of it. It exists because "the preview is blank" is a question
// about the window, and a screenshot of a blank pane only says that it is blank.
if (import.meta.env.DEV) {
  void import("../.tauri-plugin-mcp/guest-js/index")
    .then((m) => m.setupPluginListeners())
    .catch((e) => {
      // Not set up on this machine. `bin/studio-devtools` sets it up; nothing else needs it --
      // but said out loud, because a silent catch here is how you spend an afternoon asking a
      // window questions it was never listening to.
      console.warn("no devtools socket:", e);
    });
  // What the window can be asked about itself: the store it is drawn from and the commands it
  // calls. `window.__TAURI__` is deliberately not exposed (`withGlobalTauri` stays off, because
  // it is a real surface in a shipped app), so without this there is no way in from `eval` and
  // every question has to be answered by looking at pixels.
  void Promise.all([import("./state"), import("./bridge")]).then(([state, bridge]) => {
    (window as unknown as { __studio: unknown }).__studio = {
      store: state.useStudio,
      bridge: bridge.bridge,
    };
  });
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
