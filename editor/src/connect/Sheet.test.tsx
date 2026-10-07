import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";

import type { ConnectAsk } from "../types";

// The window's one door to Rust, replaced: every call is recorded, and each command answers
// what the test says it should.
const calls: { cmd: string; args: unknown }[] = [];
let answers: Record<string, unknown> = {};
vi.mock("@tauri-apps/api/core", () => ({
  invoke: vi.fn(async (cmd: string, args?: unknown) => {
    calls.push({ cmd, args });
    const a = answers[cmd];
    if (a instanceof Error) throw a.message;
    return a ?? null;
  }),
  Channel: class {},
}));

const { AskSheet } = await import("./Sheet");
const { Waiting } = await import("./Waiting");

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const acme: ConnectAsk = {
  id: "connect-acme-1",
  kind: "connect",
  service: "acme",
  name: "Acme",
  fields: [
    { name: "ACME_TOKEN", label: "API token", secret: true },
    { name: "ACME_ORG", label: "organisation", secret: false },
  ],
  docs: "https://acme.test/docs",
  why: "to fetch the sales chart",
  status: "open",
};

const post: ConnectAsk = {
  id: "approve-acme-2",
  kind: "approve",
  service: "acme",
  name: "Acme",
  op: "acme.post_item",
  method: "POST",
  fields: [],
  status: "open",
};

let host: HTMLDivElement;
let root: Root;

beforeEach(() => {
  calls.length = 0;
  answers = {};
  host = document.createElement("div");
  document.body.appendChild(host);
  root = createRoot(host);
});

afterEach(() => {
  act(() => root.unmount());
  host.remove();
});

async function draw(el: React.ReactElement) {
  await act(async () => root.render(el));
}

function type(input: HTMLInputElement, value: string) {
  const set = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  set.call(input, value);
  input.dispatchEvent(new Event("input", { bubbles: true }));
}

function button(text: string): HTMLButtonElement {
  const b = [...document.querySelectorAll("button")].find((x) => x.textContent?.trim() === text);
  if (!b) throw new Error(`no button says ${text}`);
  return b;
}

const field = (name: string) => document.querySelector<HTMLInputElement>(`input[name="${name}"]`)!;

describe("the connect sheet", () => {
  it("asks for each field, a secret one masked, by its label", async () => {
    await draw(<AskSheet ask={acme} onClose={() => {}} />);
    expect(field("ACME_TOKEN").type).toBe("password");
    expect(field("ACME_ORG").type).toBe("text");
    expect(document.body.textContent).toContain("API token");
    expect(document.body.textContent).toContain("Organisation");
    expect(document.body.textContent).toContain("to fetch the sales chart");
    expect(button("Connect").disabled, "nothing typed yet").toBe(true);
  });

  it("sends exactly what was typed, then holds none of it", async () => {
    answers.connect_save = { service: "acme", fields: ["ACME_TOKEN", "ACME_ORG"], checked: true };
    await draw(<AskSheet ask={acme} onClose={() => {}} />);
    await act(async () => {
      type(field("ACME_TOKEN"), "sk-live-very-secret");
      type(field("ACME_ORG"), "north");
    });
    await act(async () => button("Connect").click());

    const saves = calls.filter((c) => c.cmd === "connect_save");
    expect(saves).toEqual([
      {
        cmd: "connect_save",
        args: { service: "acme", values: { ACME_TOKEN: "sk-live-very-secret", ACME_ORG: "north" } },
      },
    ]);
    expect(field("ACME_TOKEN").value).toBe("");
    expect(field("ACME_ORG").value).toBe("");
    expect(document.body.innerHTML).not.toContain("sk-live-very-secret");
    expect(document.body.textContent).toContain("Acme is connected, and its test call passed.");
  });

  it("empties the fields when connecting fails too, and says why", async () => {
    answers.connect_save = new Error("Acme still lacks ACME_ORG");
    await draw(<AskSheet ask={acme} onClose={() => {}} />);
    await act(async () => {
      type(field("ACME_TOKEN"), "sk-live-very-secret");
      type(field("ACME_ORG"), "north");
    });
    await act(async () => button("Connect").click());
    expect(field("ACME_TOKEN").value).toBe("");
    expect(document.body.innerHTML).not.toContain("sk-live-very-secret");
    expect(document.body.textContent).toContain("Acme still lacks ACME_ORG");
  });

  it("opens the docs through Rust, by service, never by address", async () => {
    await draw(<AskSheet ask={acme} onClose={() => {}} />);
    await act(async () => button("Where to find these").click());
    expect(calls.find((c) => c.cmd === "connect_docs")?.args).toEqual({ service: "acme" });
  });
});

describe("the approval sheet", () => {
  for (const [text, answer] of [
    ["Allow once", "once"],
    ["Always allow", "always"],
    ["Deny", "deny"],
  ] as const) {
    it(`${text} answers ${answer}`, async () => {
      const closed = vi.fn();
      answers.connect_answer = { service: "acme", op: "acme.post_item", answer };
      await draw(<AskSheet ask={post} onClose={closed} />);
      expect(document.body.textContent).toContain("The agent wants to run POST acme.post_item on Acme.");
      await act(async () => button(text).click());
      expect(calls.filter((c) => c.cmd === "connect_answer").map((c) => c.args)).toEqual([
        { service: "acme", op: "acme.post_item", answer },
      ]);
      expect(closed).toHaveBeenCalled();
    });
  }
});

describe("what agents are waiting on", () => {
  it("draws nothing when nobody is waiting", async () => {
    answers.connect_asks = [];
    await draw(<Waiting />);
    expect(calls.some((c) => c.cmd === "connect_asks")).toBe(true);
    expect(host.innerHTML).toBe("");
    expect(document.querySelector("[role=dialog]")).toBeNull();
  });

  it("brings the first open ask to the front, and puts it off on Not now", async () => {
    answers.connect_asks = [acme];
    await draw(<Waiting />);
    expect(document.querySelector("[role=dialog]")).not.toBeNull();
    expect(field("ACME_TOKEN")).not.toBeNull();
    await act(async () => button("Not now").click());
    expect(document.querySelector("[role=dialog]")).toBeNull();
  });
});
