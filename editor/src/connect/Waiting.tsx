// What agents are waiting on the person for, brought to the front.
//
// The asks are rows the command line keeps (`./moonsplice connect --asks`), raised by an agent run
// anywhere: in this window, at a terminal, in a script. So the window asks for them, every two
// seconds while it is in front of somebody and at once when it comes back, rather than waiting
// to be told by a run it may never have seen.

import { useCallback, useEffect, useState } from "react";

import { bridge } from "../bridge";
import type { ConnectAsk } from "../types";
import { AskSheet } from "./Sheet";

export const EVERY_MS = 2000;

export function Waiting() {
  const [asks, setAsks] = useState<ConnectAsk[]>([]);
  // Put off for now. Still open, still a row; only this window stops pressing it until the
  // agent asks again under a new id.
  const [later, setLater] = useState<Set<string>>(() => new Set());
  // The ask on screen, held apart from the rows: a connected service settles its ask, and the
  // sheet should still say how the connecting went. One answered somewhere else, at a terminal,
  // goes away -- unless the person has started answering it here.
  const [shown, setShown] = useState<{ ask: ConnectAsk; acted: boolean } | null>(null);

  const look = useCallback(() => {
    if (document.visibilityState !== "visible") return;
    bridge
      .connectAsks()
      .then((rows) => setAsks(Array.isArray(rows) ? rows.filter((r) => r.status !== "done") : []))
      // No engine, no asks: nothing for the person to do, so nothing to say.
      .catch(() => {});
  }, []);

  useEffect(() => {
    look();
    const timer = window.setInterval(look, EVERY_MS);
    window.addEventListener("focus", look);
    document.addEventListener("visibilitychange", look);
    return () => {
      window.clearInterval(timer);
      window.removeEventListener("focus", look);
      document.removeEventListener("visibilitychange", look);
    };
  }, [look]);

  useEffect(() => {
    setShown((was) => {
      if (was && (was.acted || asks.some((a) => a.id === was.ask.id))) return was;
      const next = asks.find((a) => !later.has(a.id));
      return next ? { ask: next, acted: false } : null;
    });
  }, [asks, later]);

  if (!shown) return null;
  const id = shown.ask.id;
  return (
    <AskSheet
      key={id}
      ask={shown.ask}
      onActed={() => setShown((was) => (was && was.ask.id === id ? { ...was, acted: true } : was))}
      onClose={() => {
        setShown(null);
        setLater((was) => new Set(was).add(id));
        look();
      }}
    />
  );
}
