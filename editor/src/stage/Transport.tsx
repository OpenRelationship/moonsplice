import { useEffect, useRef, useState, type CSSProperties } from "react";
import clsx from "clsx";
import { bridge, why } from "../bridge";
import * as fmt from "../format";
import { saidRate } from "../player";
import { useStudio, type Tab } from "../state";
import { Button, Icon } from "../ui/bits";

/** Why the preview is behind, in one sentence, only while it is. Asked for once a second and
 *  only while playing: a measurement that costs something to look at is one nobody looks at. */
function useWhyBehind(behind: boolean, playing: boolean, fps: number): string | null {
  const [why, setWhy] = useState<string | null>(null);
  useEffect(() => {
    if (!playing) {
      setWhy(null);
      return;
    }
    let alive = true;
    const budget = fps > 0 ? 1000 / fps : 1000 / 30;
    const ask = async () => {
      try {
        const report = await bridge.playback(budget);
        if (alive) setWhy(report.why);
      } catch {
        // Nothing to say is the right answer when the question cannot be asked.
      }
    };
    void ask();
    const every = window.setInterval(ask, 1000);
    return () => {
      alive = false;
      window.clearInterval(every);
    };
  }, [playing, fps]);
  return behind ? why : null;
}

/**
 * How loud the preview is.
 *
 * The only control in the app that is not an edit: it changes nothing that is written down and
 * nothing that comes out of a render, which is why it sits next to the clock rather than
 * anywhere near the timeline. The speaker puts it to silence and back to where it was, the way
 * every other player does it -- so the quick thing is one click and the exact thing is a drag.
 */
function Listening() {
  const listening = useStudio((s) => s.listening);
  const setListening = useStudio((s) => s.setListening);
  /** Where it was before it was silenced, so clicking again puts it back rather than guessing. */
  const wasAt = useRef(0.8);

  const pct = Math.round(listening * 100);
  const glyph = listening === 0 ? "sound-off" : listening < 0.34 ? "sound-low" : "sound-high";

  return (
    <div
      className="flex items-center gap-1.5"
      title={listening === 0 ? "Silent" : `Listening at ${pct}%`}
    >
      <Button
        tone="ghost"
        title={listening === 0 ? "Hear it again" : "Silence the preview"}
        className="!px-1.5"
        onClick={() => {
          if (listening === 0) {
            setListening(wasAt.current || 0.8);
          } else {
            wasAt.current = listening;
            setListening(0);
          }
        }}
      >
        <Icon name={glyph} />
      </Button>
      <input
        type="range"
        className="fader"
        min={0}
        max={100}
        step={1}
        value={pct}
        aria-label="How loud the preview is"
        style={{ "--at": `${pct}%` } as CSSProperties}
        onChange={(e) => {
          const v = Number(e.target.value) / 100;
          if (v > 0) wasAt.current = v;
          setListening(v);
        }}
      />
    </div>
  );
}

export function Transport({
  tab,
  playing,
  playhead,
  behind,
  scale,
  rate,
  onPlay,
  onSeek,
}: {
  tab: Tab;
  playing: boolean;
  playhead: number;
  /** The picture is a frame or two back. Said quietly, by dimming the clock -- the honest
   *  reading is "the time is ahead of the picture", and that is what it looks like. */
  behind: boolean;
  /** How big the moving picture is being drawn, as a fraction of the pane. 1 unless playing
   *  had to give something up to keep time. */
  scale: number;
  /** How fast, and which way. 1 is the speed it was shot at. */
  rate: number;
  onPlay: () => void;
  onSeek: (t: number) => void;
}) {
  const say = useStudio((s) => s.say);
  const slow = useWhyBehind(behind, playing, tab.meta.fps);
  const said = saidRate(rate);
  return (
    <div
      className="flex h-[34px] shrink-0 items-center gap-2 border-t px-2.5"
      style={{ borderColor: "var(--edge-soft)" }}
    >
      <Button tone="ghost" title={playing ? "Pause" : "Play"} onClick={onPlay} className="!px-1.5">
        <Icon name={playing ? "pause" : "play"} />
      </Button>
      <span
        className={clsx(
          "tnum text-[11.5px] transition-colors",
          behind ? "text-[var(--text-3)]" : "text-[var(--text-2)]",
        )}
        title={behind ? "the picture is catching up" : undefined}
      >
        {fmt.timecode(playhead)}
      </span>
      <span className="text-[11px] text-[var(--text-3)]">/ {fmt.seconds(tab.meta.duration)}</span>

      {/* The shuttle speed, whenever it is not the speed the thing was shot at. A preview
          running backwards at four times with nothing said about it looks like a fault, and
          the sound going quiet looks like a second one -- so both are said, in three words. */}
      {playing && said ? (
        <span
          className="tnum rounded px-1 text-[10px]"
          style={{ background: "var(--ink-3)", color: "var(--text-2)" }}
          title="Sound plays at the speed it was recorded and nowhere else, so it is silent while you shuttle"
        >
          {said}
        </span>
      ) : null}

      {/* What playing gave up to keep time. Every editor does this and every editor says so,
          because a person who is not told will think the composition looks like that. It is
          one word, it is gone the moment they stop, and it is not a control: there is nothing
          to decide here, the player already decided. */}
      {playing && scale < 1 ? (
        <span
          className="rounded px-1 text-[10px] text-[var(--text-3)]"
          style={{ border: "1px solid var(--edge-soft)" }}
          title="The preview is drawn smaller while it plays, so it can keep time. It is full size again the moment you stop."
        >
          {scale >= 0.7 ? "¾ size" : scale >= 0.45 ? "half size" : scale >= 0.3 ? "⅓ size" : "¼ size"}
        </span>
      ) : null}

      {/* When the picture cannot keep up, say which part of it is slow rather than leaving a
          person to guess. It appears only while that is true, and says nothing otherwise. */}
      {slow ? (
        <span className="truncate text-[11px] text-[var(--text-3)]" title={slow}>
          {slow}
        </span>
      ) : null}

      <div className="flex-1" />

      <Listening />
      <span className="mx-1 h-[14px] w-px" style={{ background: "var(--edge-soft)" }} aria-hidden />

      <Button
        tone="ghost"
        title={tab.undoLabel ? `Undo — ${tab.undoLabel}` : "Nothing to undo"}
        disabled={tab.undo === 0}
        className="!px-1.5"
        onClick={async () => {
          try {
            say("said", await bridge.undo(tab.variation));
          } catch (e) {
            say("refused", why(e));
          }
        }}
      >
        <Icon name="undo" />
      </Button>
      <Button
        tone="ghost"
        title={tab.redoLabel ? `Redo — ${tab.redoLabel}` : "Nothing to redo"}
        disabled={tab.redo === 0}
        className="!px-1.5"
        onClick={async () => {
          try {
            say("said", await bridge.redo(tab.variation));
          } catch (e) {
            say("refused", why(e));
          }
        }}
      >
        <Icon name="redo" />
      </Button>

      <span className="tnum pl-1 text-[10.5px] text-[var(--text-3)]">
        {tab.meta.width}×{tab.meta.height}
      </span>
      <Button
        tone="ghost"
        title="Step back one frame"
        className="!px-1"
        onClick={() => onSeek(playhead - 1 / tab.meta.fps)}
      >
        <Icon name="step-back" className="h-[11px] w-[11px]" />
      </Button>
      <Button
        tone="ghost"
        title="Step on one frame"
        className="!px-1"
        onClick={() => onSeek(playhead + 1 / tab.meta.fps)}
      >
        <Icon name="step-on" className="h-[11px] w-[11px]" />
      </Button>
    </div>
  );
}
