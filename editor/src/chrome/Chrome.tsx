// The window's own top bar: stoplights left, the project in the middle, Export right.
//
// The title bar is the system's (`titleBarStyle: "Overlay"`), so the first 78px belong to the
// traffic lights and nothing interactive may sit there.

import { useEffect, useState } from "react";

import { bridge, why } from "../bridge";
import { Settings } from "../connect/Settings";
import { Button, Icon } from "../ui/bits";
import { activeTab, useStudio } from "../state";

export function Chrome() {
  const project = useStudio((s) => s.project);
  const tab = useStudio((s) => activeTab(s));
  const say = useStudio((s) => s.say);
  const libraryOpen = useStudio((s) => s.libraryOpen);
  const agentOpen = useStudio((s) => s.agentOpen);
  const toggleLibrary = useStudio((s) => s.toggleLibrary);
  const toggleAgent = useStudio((s) => s.toggleAgent);
  const [theme, setTheme] = useState<"dark" | "light">("dark");
  const [exporting, setExporting] = useState(false);
  const [settings, setSettings] = useState(false);

  useEffect(() => {
    document.documentElement.dataset.theme = theme;
  }, [theme]);

  return (
    <>
      <header
        className="chrome-drag relative z-20 flex h-[var(--chrome)] shrink-0 items-center gap-2 border-b bg-[var(--ink-0)] pl-[78px] pr-2"
        style={{ borderColor: "var(--edge-soft)" }}
      >
        {/* Show me less. Both panes are helpful and neither is the work; you can put them away. */}
        <div className="chrome-no-drag flex flex-1 items-center gap-1">
          <Button
            tone="ghost"
            title={libraryOpen ? "Hide the project" : "Show the project"}
            onClick={toggleLibrary}
            className={libraryOpen ? "!text-[var(--text-1)]" : undefined}
          >
            <Icon name="panel-left" />
          </Button>
        </div>

        <div className="chrome-no-drag flex items-center gap-2">
          <span className="text-[12.5px] font-semibold tracking-[-0.01em] text-[var(--text-1)]">
            {project?.name ?? "Moonsplice Studio"}
          </span>
          {tab ? (
            <>
              <span className="text-[var(--text-3)]">·</span>
              <span className="text-[12.5px] text-[var(--text-2)]">{tab.title}</span>
            </>
          ) : null}
        </div>

        <div className="flex flex-1 items-center justify-end gap-1">
          <Button
            tone="ghost"
            title={agentOpen ? "Hide the assistant" : "Show the assistant"}
            onClick={toggleAgent}
            className={agentOpen ? "chrome-no-drag !text-[var(--text-1)]" : "chrome-no-drag"}
          >
            <Icon name="panel-right" />
          </Button>
          <Button
            tone="ghost"
            title="Settings: model keys and connections"
            onClick={() => setSettings(true)}
            className="chrome-no-drag"
          >
            <Icon name="settings" />
          </Button>
          <Button
            tone="ghost"
            title={theme === "dark" ? "Switch to light" : "Switch to dark"}
            onClick={() => setTheme(theme === "dark" ? "light" : "dark")}
            className="chrome-no-drag"
          >
            <Icon name="sun" />
          </Button>
          <Button
            tone="solid"
            disabled={!tab || exporting}
            title="Render this composition to a finished video"
            className="chrome-no-drag"
            onClick={async () => {
              if (!tab) return;
              setExporting(true);
              try {
                const title = await bridge.export(tab.variation);
                say("working", `Rendering ${title}`);
              } catch (e) {
                say("refused", why(e));
              } finally {
                setExporting(false);
              }
            }}
          >
            {exporting ? "Rendering…" : "Export"}
          </Button>
        </div>
      </header>
      {/* Outside the header: everything inside it is a handle for moving the window. */}
      {settings ? <Settings onClose={() => setSettings(false)} /> : null}
    </>
  );
}
