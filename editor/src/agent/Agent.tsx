// The right pane. AI SDK UI on top, a turn in this binary underneath, and nothing in between
// but a Tauri channel.
//
// Two things here are the spec made visible. An approval is drawn where the work is, not in a
// modal, because a refusal is an ordinary answer and a modal makes it feel like an error. And
// the trail of work is shown as it happens — "looking at the composition", "changing the
// composition" — because an agent that edits your video silently is one you cannot trust.

import { useCallback, useMemo, useRef, useState } from "react";
import { useChat } from "@ai-sdk/react";
import clsx from "clsx";

import { activeTab, useStudio } from "../state";
import { Button, Empty, Icon } from "../ui/bits";
import { Said } from "./Said";
import { studioTransport, working, type StudioMessage } from "./transport";

const SUGGESTIONS = [
  "What is in this composition?",
  "Make the title fade in more gently",
  "Hold the last line half a second longer",
];

export function Agent() {
  const tab = useStudio((s) => activeTab(s));
  const activeRef = useRef<string | null>(null);
  activeRef.current = tab?.variation ?? null;

  const transport = useMemo(
    () => studioTransport({ variation: () => activeRef.current }),
    [],
  );

  const { messages, sendMessage, status, stop, error } = useChat<StudioMessage>({ transport });
  const [draft, setDraft] = useState("");
  const busy = status === "submitted" || status === "streaming";

  const send = useCallback(
    (text: string) => {
      const body = text.trim();
      if (!body || busy) return;
      setDraft("");
      void sendMessage({ text: body });
    },
    [busy, sendMessage],
  );

  return (
    <aside
      className="flex w-[336px] shrink-0 flex-col border-l bg-[var(--ink-1)]"
      style={{ borderColor: "var(--edge-soft)" }}
    >
      <div
        className="flex h-[30px] shrink-0 items-center gap-2 border-b px-3"
        style={{ borderColor: "var(--edge-soft)" }}
      >
        <Icon name="spark" className="text-[var(--move)]" />
        <span className="text-[10.5px] font-semibold uppercase tracking-[0.09em] text-[var(--text-3)]">
          Agent
        </span>
        <div className="flex-1" />
        {busy ? (
          <Button tone="ghost" title="Stop this turn" className="!px-1.5" onClick={() => stop()}>
            <Icon name="stop" className="h-3 w-3" />
          </Button>
        ) : null}
      </div>

      <div className="scroll min-h-0 flex-1 px-3 py-3">
        {messages.length === 0 ? (
          <Empty
            title="Ask for what you want"
            hint={
              tab
                ? "It reads the composition before it changes anything, and asks you before every change."
                : "Open a composition first — the agent works on one at a time."
            }
          />
        ) : (
          <ol className="flex flex-col gap-3">
            {messages.map((m) => (
              <Message key={m.id} message={m} />
            ))}
          </ol>
        )}
        {error ? (
          <p className="rise mt-3 rounded-[var(--radius-sm)] bg-[var(--ink-3)] px-2.5 py-2 text-[12px] text-[var(--warn)]">
            {error.message}
          </p>
        ) : null}
      </div>

      {messages.length === 0 && tab ? (
        <div className="flex flex-col gap-1 px-3 pb-2">
          {SUGGESTIONS.map((s) => (
            <button
              key={s}
              type="button"
              className="truncate rounded-[var(--radius-sm)] bg-[var(--ink-2)] px-2.5 py-1.5 text-left text-[12px] text-[var(--text-2)] transition-colors hover:bg-[var(--ink-3)] hover:text-[var(--text-1)]"
              onClick={() => send(s)}
            >
              {s}
            </button>
          ))}
        </div>
      ) : null}

      <div className="shrink-0 border-t p-2.5" style={{ borderColor: "var(--edge-soft)" }}>
        <div
          className={clsx(
            "flex items-end gap-1.5 rounded-[var(--radius)] bg-[var(--ink-2)] p-1.5 transition-shadow",
            "focus-within:ring-1 focus-within:ring-[var(--move)]",
          )}
        >
          <textarea
            rows={1}
            value={draft}
            placeholder={tab ? `Ask about ${tab.title}…` : "Open a composition first"}
            disabled={!tab}
            onChange={(e) => {
              setDraft(e.target.value);
              e.currentTarget.style.height = "auto";
              e.currentTarget.style.height = `${Math.min(e.currentTarget.scrollHeight, 132)}px`;
            }}
            onKeyDown={(e) => {
              if (e.key === "Enter" && !e.shiftKey) {
                e.preventDefault();
                send(draft);
              }
            }}
            className="max-h-[132px] min-h-[26px] flex-1 resize-none bg-transparent px-1.5 py-1 text-[12.5px] leading-[1.45] text-[var(--text-1)] outline-none placeholder:text-[var(--text-3)] disabled:opacity-50"
          />
          <Button
            tone={draft.trim() ? "solid" : "quiet"}
            title="Send"
            disabled={!draft.trim() || busy || !tab}
            onClick={() => send(draft)}
            className="!px-2 !py-1.5"
          >
            <Icon name="send" />
          </Button>
        </div>
      </div>
    </aside>
  );
}

function Message({ message }: { message: StudioMessage }) {
  if (message.role === "user") {
    return (
      <li className="rise self-end">
        <p
          data-selectable
          className="max-w-[276px] rounded-[var(--radius)] bg-[var(--ink-4)] px-2.5 py-1.5 text-[12.5px] text-[var(--text-1)]"
        >
          {message.parts.map((p, i) => (p.type === "text" ? <span key={i}>{p.text}</span> : null))}
        </p>
      </li>
    );
  }

  return (
    <li className="rise flex flex-col gap-1.5">
      {message.parts.map((part, i) => {
        if (part.type === "text") {
          return (
            <div key={i} data-selectable>
              <Said text={part.text} />
            </div>
          );
        }
        if (part.type === "dynamic-tool") {
          return <Working key={i} name={part.toolName} state={part.state} />;
        }
        if (part.type === "data-ended") {
          return <Ended key={i} data={part.data} />;
        }
        return null;
      })}
    </li>
  );
}

function Working({ name, state }: { name: string; state: string }) {
  const done = state === "output-available";
  const failed = state === "output-error";
  return (
    <p
      className={clsx(
        "flex items-center gap-1.5 text-[11.5px]",
        failed ? "text-[var(--warn)]" : done ? "text-[var(--text-3)]" : "text-[var(--text-2)]",
      )}
    >
      <span
        className={clsx("h-[5px] w-[5px] shrink-0 rounded-full", !done && !failed && "breathe")}
        style={{
          background: failed ? "var(--warn)" : done ? "var(--text-3)" : "var(--move)",
        }}
        aria-hidden
      />
      {working(name)}
      {failed ? " — not done" : null}
    </p>
  );
}

function Ended({ data }: { data: { stop: string; reason?: string | null } }) {
  const word =
    data.stop === "budget"
      ? "It stopped after taking as many steps as it is allowed."
      : data.stop === "error"
        ? "It could not finish."
        : "It ended without an answer.";
  return (
    <p className="rounded-[var(--radius-sm)] bg-[var(--ink-2)] px-2.5 py-1.5 text-[11.5px] text-[var(--text-2)]">
      {word}
      {data.reason ? ` ${data.reason}` : null}
    </p>
  );
}
