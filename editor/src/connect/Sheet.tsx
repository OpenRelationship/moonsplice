// The sheet an agent's ask is answered in (.robot/docs/connect.robot): connect a service, or let
// the agent make a call that changes something.
//
// A credential has its own field and goes from there to the keychain. It is never in the
// conversation, never in a row, and held by this window only between the keystroke and the
// press of Connect: the fields are emptied before the answer comes back, whatever it is.

import { useEffect, useState, type ReactNode } from "react";

import { bridge, why } from "../bridge";
import { Button } from "../ui/bits";
import type { ConnectAnswer, ConnectAsk, ConnectField } from "../types";

/** The part of an ask the connect form needs. A `--needs` answer has the same shape, which is
 *  how Settings connects a service nobody asked for yet. */
export interface ConnectRequest {
  service: string;
  name?: string | null;
  fields: ConnectField[];
  docs?: string | null;
  why?: string | null;
}

/** The dimmed window and the card on it, as the quick-ways sheet draws them. */
export function Overlay({ children, onClose }: { children: ReactNode; onClose: () => void }) {
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [onClose]);
  return (
    <div
      className="fixed inset-0 z-[110] flex items-center justify-center p-8"
      style={{ background: "color-mix(in oklab, var(--ink-0) 72%, transparent)" }}
      onPointerDown={onClose}
      role="presentation"
    >
      <div
        role="dialog"
        aria-modal="true"
        className="rise max-h-full w-full max-w-[420px] overflow-auto rounded-[var(--radius)] p-5"
        style={{
          background: "var(--ink-1)",
          boxShadow: "var(--shadow-lift)",
          border: "1px solid var(--edge-soft)",
        }}
        onPointerDown={(e) => e.stopPropagation()}
      >
        {children}
      </div>
    </div>
  );
}

/** The service's own mark, or its initial when the directory has none. */
export function Logo({ service, name }: { service: string; name: string }) {
  const [svg, setSvg] = useState<string | null>(null);
  useEffect(() => {
    let live = true;
    bridge
      .connectLogo(service)
      .then((s) => live && setSvg(s))
      .catch(() => {});
    return () => {
      live = false;
    };
  }, [service]);
  const box = "flex h-9 w-9 shrink-0 items-center justify-center rounded-[var(--radius-sm)]";
  if (svg) {
    // As an image, so nothing in the file can run.
    return (
      <span className={box} style={{ background: "#fff" }}>
        <img
          alt=""
          className="h-6 w-6 object-contain"
          src={`data:image/svg+xml;charset=utf-8,${encodeURIComponent(svg)}`}
        />
      </span>
    );
  }
  return (
    <span className={`${box} bg-[var(--ink-3)] text-[14px] font-semibold text-[var(--text-2)]`}>
      {name.slice(0, 1).toUpperCase()}
    </span>
  );
}

function Heading({
  service,
  name,
  children,
}: {
  service: string;
  name: string;
  children: ReactNode;
}) {
  return (
    <div className="mb-3 flex items-center gap-3">
      <Logo service={service} name={name} />
      <div className="min-w-0">
        <h2 className="text-[13px] font-semibold text-[var(--text-1)]">{name}</h2>
        <p className="text-[11.5px] text-[var(--text-3)]">{children}</p>
      </div>
    </div>
  );
}

type Outcome = { ok: true; text: string } | { ok: false; text: string };

/** One field per thing the service needs, a secret one masked. */
export function ConnectForm({
  ask,
  onClose,
  onActed,
}: {
  ask: ConnectRequest;
  onClose: () => void;
  onActed?: () => void;
}) {
  const name = ask.name || ask.service;
  const [values, setValues] = useState<Record<string, string>>({});
  const [busy, setBusy] = useState(false);
  const [outcome, setOutcome] = useState<Outcome | null>(null);

  const connect = async () => {
    const sent = values;
    onActed?.();
    // Out of the window's state before the answer, so a failure does not leave it lying there.
    setValues({});
    setBusy(true);
    try {
      const r = await bridge.connectSave(ask.service, sent);
      setOutcome({
        ok: true,
        text: r.checked
          ? `${name} is connected, and its test call passed.`
          : `${name} is connected. Its test call did not pass, or it has none.`,
      });
    } catch (e) {
      setOutcome({ ok: false, text: why(e) });
    } finally {
      setBusy(false);
    }
  };

  const filled =
    ask.fields.length > 0 && ask.fields.every((f) => (values[f.name] ?? "").trim() !== "");

  return (
    <>
      <Heading service={ask.service} name={name}>
        An agent wants to use {name}
      </Heading>
      {ask.why ? <p className="mb-3 text-[12px] text-[var(--text-2)]">{ask.why}</p> : null}
      <form
        className="flex flex-col gap-2.5"
        onSubmit={(e) => {
          e.preventDefault();
          if (filled && !busy) void connect();
        }}
      >
        {ask.fields.map((f) => (
          <label key={f.name} className="flex flex-col gap-1">
            <span className="text-[11px] text-[var(--text-3)]">{label(f)}</span>
            <input
              name={f.name}
              type={f.secret ? "password" : "text"}
              autoComplete="off"
              spellCheck={false}
              value={values[f.name] ?? ""}
              onChange={(e) => {
                const v = e.target.value;
                setValues((was) => ({ ...was, [f.name]: v }));
              }}
              className="rounded-[var(--radius-sm)] border bg-[var(--ink-2)] px-2.5 py-1.5 text-[12.5px] text-[var(--text-1)] outline-none focus:border-[var(--focus)]"
              style={{ borderColor: "var(--edge)" }}
            />
          </label>
        ))}
        <p className="text-[11px] text-[var(--text-3)]">
          {ask.fields.some((f) => f.secret)
            ? "Kept in your keychain. The agent is told only that it is connected."
            : "The agent is told only that it is connected."}
          {ask.docs ? (
            <>
              {" "}
              <button
                type="button"
                className="text-[var(--move)] underline-offset-2 hover:underline"
                onClick={() => void bridge.connectDocs(ask.service).catch(() => {})}
              >
                Where to find these
              </button>
            </>
          ) : null}
        </p>
        {outcome ? (
          <p
            role="status"
            className="text-[12px]"
            style={{ color: outcome.ok ? "var(--sound)" : "var(--warn)" }}
          >
            {outcome.text}
          </p>
        ) : null}
        <div className="flex items-center justify-end gap-1.5 pt-1">
          {outcome?.ok ? (
            <Button tone="solid" onClick={onClose}>
              Done
            </Button>
          ) : (
            <>
              <Button tone="ghost" onClick={onClose}>
                Not now
              </Button>
              <Button tone="solid" disabled={!filled || busy} onClick={() => void connect()}>
                {busy ? "Connecting…" : "Connect"}
              </Button>
            </>
          )}
        </div>
      </form>
    </>
  );
}

/** A field's label as a person would say it: "token", not GITHUB_TOKEN. */
function label(f: ConnectField): string {
  const l = f.label || f.name;
  return l.slice(0, 1).toUpperCase() + l.slice(1);
}

/** A call that changes something, waiting on the person's word. */
export function ApproveForm({ ask, onClose }: { ask: ConnectAsk; onClose: () => void }) {
  const name = ask.name || ask.service;
  const [problem, setProblem] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const answer = async (a: ConnectAnswer) => {
    setBusy(true);
    try {
      await bridge.connectAnswer(ask.service, ask.op ?? "", a);
      onClose();
    } catch (e) {
      setProblem(why(e));
      setBusy(false);
    }
  };

  return (
    <>
      <Heading service={ask.service} name={name}>
        A call that changes something
      </Heading>
      <p className="text-[12.5px] text-[var(--text-1)]">
        The agent wants to run{" "}
        <span className="font-mono text-[12px]">
          {ask.method ? `${ask.method} ` : ""}
          {ask.op}
        </span>{" "}
        on {name}.
      </p>
      {ask.why ? <p className="pt-1 text-[12px] text-[var(--text-2)]">{ask.why}</p> : null}
      {problem ? (
        <p role="status" className="pt-2 text-[12px] text-[var(--warn)]">
          {problem}
        </p>
      ) : null}
      <div className="flex items-center justify-end gap-1.5 pt-3">
        <Button tone="quiet" disabled={busy} onClick={() => void answer("deny")}>
          Deny
        </Button>
        <Button tone="ghost" disabled={busy} onClick={() => void answer("always")}>
          Always allow
        </Button>
        <Button tone="solid" disabled={busy} onClick={() => void answer("once")}>
          Allow once
        </Button>
      </div>
    </>
  );
}

/** One ask, in the sheet that suits it. */
export function AskSheet({
  ask,
  onClose,
  onActed,
}: {
  ask: ConnectAsk;
  onClose: () => void;
  onActed?: () => void;
}) {
  return (
    <Overlay onClose={onClose}>
      {ask.kind === "approve" ? (
        <ApproveForm ask={ask} onClose={onClose} />
      ) : (
        <ConnectForm ask={ask} onClose={onClose} onActed={onActed} />
      )}
    </Overlay>
  );
}
