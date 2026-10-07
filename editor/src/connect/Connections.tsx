// Connections, in Settings: what is connected, forgetting it, and connecting something before
// any agent has asked. Names only; no value is ever shown, because none ever reaches the window.

import { useCallback, useEffect, useState } from "react";

import { bridge, why } from "../bridge";
import { Button } from "../ui/bits";
import type { ConnectFound, Connection } from "../types";
import { ConnectForm, Logo, type ConnectRequest } from "./Sheet";

export function Connections() {
  const [list, setList] = useState<Connection[] | null>(null);
  const [words, setWords] = useState("");
  const [found, setFound] = useState<ConnectFound[]>([]);
  const [connecting, setConnecting] = useState<ConnectRequest | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  const load = useCallback(() => {
    bridge
      .connections()
      .then((rows) => setList(Array.isArray(rows) ? rows : []))
      .catch((e) => {
        setList([]);
        setProblem(why(e));
      });
  }, []);
  useEffect(load, [load]);

  const find = async () => {
    setProblem(null);
    try {
      setFound(await bridge.connectFind(words));
    } catch (e) {
      setProblem(why(e));
    }
  };

  const start = async (service: string) => {
    setProblem(null);
    try {
      const needs = await bridge.connectNeeds(service);
      setConnecting({
        service: needs.service,
        name: needs.name,
        fields: needs.fields,
        docs: needs.docs,
      });
    } catch (e) {
      setProblem(why(e));
    }
  };

  if (connecting) {
    return (
      <ConnectForm
        ask={connecting}
        onClose={() => {
          setConnecting(null);
          setFound([]);
          setWords("");
          load();
        }}
      />
    );
  }

  return (
    <div className="flex flex-col gap-2">
      {list === null ? null : list.length === 0 ? (
        <p className="text-[12px] text-[var(--text-3)]">
          Nothing is connected. When an agent needs a service, it asks here first.
        </p>
      ) : (
        <ul className="flex flex-col gap-1">
          {list.map((c) => (
            <li
              key={c.service}
              className="flex items-center gap-2.5 rounded-[var(--radius-sm)] bg-[var(--ink-2)] px-2 py-1.5"
            >
              <Logo service={c.service} name={c.service} />
              <div className="min-w-0 flex-1">
                <p className="truncate text-[12.5px] text-[var(--text-1)]">{c.service}</p>
                <p className="truncate font-mono text-[10.5px] text-[var(--text-3)]">
                  {c.fields.join(", ")}
                </p>
              </div>
              <Button
                tone="danger"
                title={`Forget ${c.service} and take its keys out of the keychain`}
                onClick={async () => {
                  try {
                    await bridge.connectForget(c.service);
                  } catch (e) {
                    setProblem(why(e));
                  }
                  load();
                }}
              >
                Forget
              </Button>
            </li>
          ))}
        </ul>
      )}

      <form
        className="flex items-center gap-1.5 pt-1"
        onSubmit={(e) => {
          e.preventDefault();
          void find();
        }}
      >
        <input
          aria-label="Find a service to connect"
          placeholder="Find a service to connect"
          value={words}
          spellCheck={false}
          onChange={(e) => setWords(e.target.value)}
          className="min-w-0 flex-1 rounded-[var(--radius-sm)] border bg-[var(--ink-2)] px-2.5 py-1.5 text-[12.5px] text-[var(--text-1)] outline-none focus:border-[var(--focus)]"
          style={{ borderColor: "var(--edge)" }}
        />
        <Button tone="quiet" disabled={!words.trim()} onClick={() => void find()}>
          Find
        </Button>
      </form>
      {found.length > 0 ? (
        <ul className="flex flex-col">
          {found.map((f) => (
            <li key={f.service}>
              <button
                type="button"
                onClick={() => void start(f.service)}
                className="flex w-full items-center gap-2.5 rounded-[var(--radius-sm)] px-2 py-1.5 text-left hover:bg-[var(--ink-3)]"
              >
                <Logo service={f.service} name={f.name} />
                <span className="min-w-0 flex-1">
                  <span className="block truncate text-[12.5px] text-[var(--text-1)]">
                    {f.name}
                  </span>
                  <span className="block truncate text-[11px] text-[var(--text-3)]">
                    {f.categories.join(", ")}
                  </span>
                </span>
              </button>
            </li>
          ))}
        </ul>
      ) : null}
      {problem ? <p className="text-[12px] text-[var(--warn)]">{problem}</p> : null}
    </div>
  );
}
