// The seam. AI SDK UI expects a stream of UIMessageChunks; a turn lives in this binary and
// speaks over a Tauri channel. `ChatTransport` is the one interface between them, which is why
// there is no local HTTP server in this app — `.robot/docs/desktop.robot` §6.
//
// The translation is small and deliberate:
//
//   the agent said                  the chat shows
//   --------------                  --------------
//   call / result                   a dynamic tool part, so the trail of work is visible
//   ask                             a data part the composer draws a yes/no on
//   answer                          the assistant's text
//   stop = budget | error           the text, plus a line saying why it ended
//
// It does not stream tokens, because `src/provider.lua` explicitly streams nothing and the
// alternative is a second wire format to keep in step. What it streams is *work* — which is
// what somebody watching an editing agent actually wants to see.

import type { ChatTransport, UIMessage, UIMessageChunk } from "ai";

import { bridge } from "../bridge";
import type { TurnChunk } from "../types";

/** The custom parts this transport can put in a message. */
export type StudioData = {
  ask: {
    id: number;
    tool: string;
    args: unknown;
    reason: string | null;
    can_remember: boolean;
  };
  ended: { stop: string; reason?: string | null; steps?: number };
};

export type StudioMessage = UIMessage<never, StudioData>;

/** What the person asked, out of an AI SDK message. */
export function textOf(message: UIMessage): string {
  return message.parts
    .filter((p): p is { type: "text"; text: string } => p.type === "text")
    .map((p) => p.text)
    .join("\n")
    .trim();
}

/** The conversation so far, in the shape the harness takes. The last message is the prompt, so
 *  it is not part of the history. */
export function historyOf(messages: UIMessage[]): { role: string; text: string }[] {
  return messages
    .slice(0, -1)
    .map((m) => ({ role: m.role, text: textOf(m) }))
    .filter((m) => m.text.length > 0);
}

/** What a tool call is doing, said in the words the tools are named for. */
export function working(tool: string): string {
  const named: Record<string, string> = {
    holds: "Looking at the composition",
    at: "Checking one moment",
    shows: "Checking the picture",
    change: "Changing the composition",
    undo: "Putting it back",
    export: "Rendering",
    repaint: "Asking the pixel model",
    // Tablua's verbs (`run.rs` reads them off the run's log)
    brief: "Reading the composition",
    look: "Looking at the picture",
    expect: "Writing down what it should do",
    reference: "Reading how the engine works",
    connect: "Using a connected service",
    set_prop: "Changing a property",
    add_node: "Adding something",
    remove_node: "Taking something out",
    add_key: "Adding a key",
    move_key: "Moving a key",
  };
  return named[tool] ?? tool;
}

export interface TransportOptions {
  /** Which composition the turn is about. */
  variation: () => string | null;
}

export function studioTransport(opts: TransportOptions): ChatTransport<StudioMessage> {
  return {
    async sendMessages({ messages, abortSignal }) {
      const variation = opts.variation();
      const last = messages[messages.length - 1];
      const prompt = last ? textOf(last) : "";
      const history = historyOf(messages);

      return new ReadableStream<UIMessageChunk>({
        start(controller) {
          let closed = false;
          const close = () => {
            if (!closed) {
              closed = true;
              try {
                controller.close();
              } catch {
                // already closed by an abort
              }
            }
          };

          controller.enqueue({ type: "start" });

          if (!variation) {
            controller.enqueue({
              type: "error",
              errorText: "Open a composition first — the agent works on one at a time.",
            });
            controller.enqueue({ type: "finish" });
            close();
            return;
          }

          abortSignal?.addEventListener("abort", () => {
            void bridge.stopTurn();
          });

          // One live tool part per call, keyed by the call id the harness gave it.
          const open = new Map<string, string>();

          const onChunk = (chunk: TurnChunk) => {
            if (closed) return;
            switch (chunk.event) {
              case "call": {
                open.set(chunk.call, chunk.tool);
                controller.enqueue({
                  type: "tool-input-available",
                  toolCallId: chunk.call,
                  toolName: chunk.tool,
                  input: { ask: chunk.ask },
                  dynamic: true,
                });
                break;
              }
              case "result": {
                const name = open.get(chunk.call) ?? chunk.tool;
                open.delete(chunk.call);
                if (chunk.refused) {
                  controller.enqueue({
                    type: "tool-output-error",
                    toolCallId: chunk.call,
                    errorText: "you turned this down",
                    dynamic: true,
                  });
                } else if (!chunk.ok) {
                  controller.enqueue({
                    type: "tool-output-error",
                    toolCallId: chunk.call,
                    errorText: "this could not be done",
                    dynamic: true,
                  });
                } else {
                  controller.enqueue({
                    type: "tool-output-available",
                    toolCallId: chunk.call,
                    output: { did: working(name) },
                    dynamic: true,
                  });
                }
                break;
              }
              case "ask": {
                controller.enqueue({
                  type: "data-ask",
                  id: `ask-${chunk.id}`,
                  data: {
                    id: chunk.id,
                    tool: chunk.tool,
                    args: chunk.args,
                    reason: chunk.reason,
                    can_remember: chunk.can_remember,
                  },
                });
                break;
              }
              case "answer": {
                const id = "answer";
                const text = chunk.answer?.trim();
                if (text) {
                  controller.enqueue({ type: "text-start", id });
                  controller.enqueue({ type: "text-delta", id, delta: text });
                  controller.enqueue({ type: "text-end", id });
                }
                if (chunk.stop !== "answered") {
                  controller.enqueue({
                    type: "data-ended",
                    data: {
                      stop: chunk.stop,
                      reason: chunk.reason ?? null,
                      steps: chunk.steps,
                    },
                  });
                }
                if (!text && chunk.stop === "answered") {
                  controller.enqueue({
                    type: "data-ended",
                    data: { stop: "answered", reason: "nothing came back", steps: chunk.steps },
                  });
                }
                controller.enqueue({ type: "finish" });
                close();
                break;
              }
              default:
                // start / step / stop are the harness narrating itself; the tool parts above
                // already say everything a person needs from them.
                break;
            }
          };

          bridge.askAgent(variation, prompt, history, onChunk).catch((e: unknown) => {
            controller.enqueue({
              type: "error",
              errorText: typeof e === "string" ? e : "the turn could not start",
            });
            controller.enqueue({ type: "finish" });
            close();
          });
        },
      });
    },

    // A turn lives in this process, so there is never a stream to rejoin.
    async reconnectToStream() {
      return null;
    },
  };
}
