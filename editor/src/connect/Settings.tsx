// Settings: the keys the app's own assistant uses, and the person's connections to other apps.
// Both go to the keychain and neither comes back: the window asks whether a key is set, never
// what it is.

import { useEffect, useState } from "react";

import { bridge, why } from "../bridge";
import { Button, GroupLabel } from "../ui/bits";
import { Connections } from "./Connections";
import { Overlay } from "./Sheet";

const MODELS: [string, string][] = [
  ["openrouter", "OpenRouter"],
  ["openai", "OpenAI"],
];

function ModelKey({ name, title }: { name: string; title: string }) {
  const [set, setSet] = useState<boolean | null>(null);
  const [value, setValue] = useState("");
  const [problem, setProblem] = useState<string | null>(null);

  useEffect(() => {
    bridge
      .keyIsSet(name)
      .then(setSet)
      .catch(() => setSet(false));
  }, [name]);

  const save = async () => {
    const sent = value;
    setValue("");
    try {
      await bridge.setKey(name, sent);
      setSet(await bridge.keyIsSet(name));
      setProblem(null);
    } catch (e) {
      setProblem(why(e));
    }
  };

  return (
    <form
      className="flex items-center gap-1.5"
      onSubmit={(e) => {
        e.preventDefault();
        if (value.trim()) void save();
      }}
    >
      <span className="w-[86px] shrink-0 text-[12px] text-[var(--text-2)]">{title}</span>
      <input
        type="password"
        autoComplete="off"
        aria-label={`${title} key`}
        placeholder={set ? "Set. Type a new one to replace it" : "Not set"}
        value={value}
        onChange={(e) => setValue(e.target.value)}
        className="min-w-0 flex-1 rounded-[var(--radius-sm)] border bg-[var(--ink-2)] px-2.5 py-1.5 text-[12.5px] text-[var(--text-1)] outline-none focus:border-[var(--focus)]"
        style={{ borderColor: "var(--edge)" }}
      />
      <Button tone="quiet" disabled={!value.trim()} onClick={() => void save()}>
        Save
      </Button>
      {problem ? <span className="text-[11px] text-[var(--warn)]">{problem}</span> : null}
    </form>
  );
}

export function Settings({ onClose }: { onClose: () => void }) {
  return (
    <Overlay onClose={onClose}>
      <div className="mb-1 flex items-baseline justify-between">
        <h2 className="text-[13px] font-semibold text-[var(--text-1)]">Settings</h2>
        <Button tone="ghost" onClick={onClose}>
          Close
        </Button>
      </div>
      <div className="-mx-3">
        <GroupLabel>The assistant's model</GroupLabel>
      </div>
      <div className="flex flex-col gap-1.5">
        {MODELS.map(([name, title]) => (
          <ModelKey key={name} name={name} title={title} />
        ))}
      </div>
      <div className="-mx-3 pt-2">
        <GroupLabel>Connections</GroupLabel>
      </div>
      <Connections />
    </Overlay>
  );
}
