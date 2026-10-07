import { describe, expect, it, vi } from "vitest";

import type { TurnChunk } from "../types";
import { describeAsk } from "./describe";
import { historyOf, studioTransport, textOf, working } from "./transport";

vi.mock("../bridge", () => {
  const sent: { prompt: string; history: unknown }[] = [];
  let feed: ((c: TurnChunk) => void) | null = null;
  return {
    bridge: {
      askAgent(
        _variation: string,
        prompt: string,
        history: unknown,
        onChunk: (c: TurnChunk) => void,
      ) {
        sent.push({ prompt, history });
        feed = onChunk;
        return Promise.resolve();
      },
      stopTurn: () => Promise.resolve(),
    },
    __sent: sent,
    __feed: (c: TurnChunk) => feed?.(c),
    why: (e: unknown) => String(e),
  };
});

const msg = (role: "user" | "assistant", text: string) =>
  ({ id: `${role}-${text}`, role, parts: [{ type: "text" as const, text }] }) as never;

async function drain(stream: ReadableStream<unknown>): Promise<unknown[]> {
  const out: unknown[] = [];
  const reader = stream.getReader();
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    out.push(value);
  }
  return out;
}

describe("the seam between the chat and the turn", () => {
  it("reads a message's words back out", () => {
    expect(textOf(msg("user", "make it blue"))).toBe("make it blue");
  });

  it("sends everything before the last message as the history", () => {
    const h = historyOf([msg("user", "one"), msg("assistant", "ok"), msg("user", "two")]);
    expect(h).toEqual([
      { role: "user", text: "one" },
      { role: "assistant", text: "ok" },
    ]);
  });

  it("refuses to start a turn with no composition open, and says why", async () => {
    const t = studioTransport({ variation: () => null });
    const chunks = await drain(
      await t.sendMessages({
        chatId: "c",
        messageId: undefined,
        trigger: "submit-message",
        messages: [msg("user", "do something")],
        abortSignal: undefined,
      }),
    );
    expect(chunks).toEqual([
      { type: "start" },
      {
        type: "error",
        errorText: "Open a composition first — the agent works on one at a time.",
      },
      { type: "finish" },
    ]);
  });

  it("turns a turn's work into parts the chat can draw", async () => {
    const mod = (await import("../bridge")) as unknown as {
      __feed: (c: TurnChunk) => void;
      __sent: { prompt: string }[];
    };
    const t = studioTransport({ variation: () => "hero" });
    const stream = await t.sendMessages({
      chatId: "c",
      messageId: undefined,
      trigger: "submit-message",
      messages: [msg("user", "soften the bar")],
      abortSignal: undefined,
    });
    const collected = drain(stream);

    // give the transport's promise a tick to register the feed
    await Promise.resolve();
    mod.__feed({ event: "start", budget: 20 });
    mod.__feed({ event: "call", step: 1, call: "c1", tool: "holds", ask: false });
    mod.__feed({ event: "result", call: "c1", tool: "holds", ok: true, refused: false, size: 40 });
    mod.__feed({
      event: "ask",
      id: 7,
      tool: "change",
      args: { why: "softened the bar" },
      reason: null,
      can_remember: true,
    });
    mod.__feed({ event: "call", step: 2, call: "c2", tool: "change", ask: true });
    mod.__feed({ event: "result", call: "c2", tool: "change", ok: false, refused: true, size: 0 });
    mod.__feed({ event: "answer", stop: "answered", answer: "You turned that down." });

    const chunks = (await collected) as { type: string }[];
    const types = chunks.map((c) => c.type);
    expect(types).toContain("tool-input-available");
    expect(types).toContain("tool-output-available");
    expect(types).toContain("data-ask");
    expect(types).toContain("tool-output-error");
    expect(types.filter((x) => x === "text-delta")).toHaveLength(1);
    expect(types[types.length - 1]).toBe("finish");
    expect(mod.__sent[mod.__sent.length - 1].prompt).toBe("soften the bar");
  });

  it("says why a turn ended when it did not answer", async () => {
    const mod = (await import("../bridge")) as unknown as { __feed: (c: TurnChunk) => void };
    const t = studioTransport({ variation: () => "hero" });
    const stream = await t.sendMessages({
      chatId: "c",
      messageId: undefined,
      trigger: "submit-message",
      messages: [msg("user", "keep going")],
      abortSignal: undefined,
    });
    const collected = drain(stream);
    await Promise.resolve();
    mod.__feed({ event: "answer", stop: "budget", reason: "it took every step it is allowed" });
    const chunks = (await collected) as { type: string; data?: { stop: string } }[];
    const ended = chunks.find((c) => c.type === "data-ended");
    expect(ended?.data?.stop).toBe("budget");
  });

  it("names what a tool is doing in words, never the tool", () => {
    expect(working("holds")).toBe("Looking at the composition");
    expect(working("change")).toBe("Changing the composition");
    expect(working("whatever")).toBe("whatever");
  });
});

describe("what an approval asks", () => {
  it("says the intention, not the arguments", () => {
    expect(describeAsk("change", { why: "softened the bar", edits: [1, 2] })).toBe(
      "Change the composition — softened the bar",
    );
    expect(describeAsk("change", { edits: [1] })).toBe("Change one thing in the composition");
    expect(describeAsk("change", { edits: [1, 2, 3] })).toBe(
      "Change 3 things in the composition",
    );
    expect(describeAsk("undo", {})).toBe("Put the composition back the way it was");
    expect(describeAsk("export", { quality: "high" })).toBe(
      "Render this composition at high quality",
    );
    expect(describeAsk("repaint", { instruction: "remove the sign" })).toBe(
      "Alter the rendered picture — remove the sign",
    );
  });

  it("never shows a JSON blob, even for something it does not know", () => {
    const said = describeAsk("mystery", { secret: { deep: true } });
    expect(said).toBe("Run mystery");
    expect(said).not.toContain("{");
  });
});
