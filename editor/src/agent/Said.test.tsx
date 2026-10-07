import { act } from "react";
import { createRoot } from "react-dom/client";
import { describe, expect, it } from "vitest";

import { Said } from "./Said";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

async function draw(text: string): Promise<HTMLElement> {
  const host = document.createElement("div");
  await act(async () => createRoot(host).render(<Said text={text} />));
  return host;
}

describe("what the agent said", () => {
  it("is drawn as markdown, with none of its marks left on screen", async () => {
    const el = await draw("**Handing in**\n\n- one `set_prop`\n- two\n\n## Status\n\n| a | b |\n|---|---|\n| 1 | 2 |");
    expect(el.querySelector("strong")?.textContent).toBe("Handing in");
    expect(el.querySelectorAll("li")).toHaveLength(2);
    expect(el.querySelector("code")?.textContent).toBe("set_prop");
    expect(el.querySelector("td")?.textContent).toBe("1");
    expect(el.textContent).not.toMatch(/\*\*|##|\|---/);
  });

  it("never renders the model's own HTML, and its links go nowhere", async () => {
    const el = await draw('<img src=x onerror="alert(1)"> and [docs](https://example.com)');
    expect(el.querySelector("img")).toBeNull();
    expect(el.querySelector("a")).toBeNull();
    expect(el.textContent).toContain("docs");
  });
});
