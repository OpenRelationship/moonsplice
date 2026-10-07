// The timeline, at the length a real edit is.
//
// Every other test here works on a four second composition with five things in it. A ten minute
// edit has ninety, sixty of them sound, and a person scrolling it is asking questions the short
// one cannot pose: does the ruler still count in numbers anybody reads, does a click at nine
// minutes land on the frame it points at, does building the lanes take long enough to feel.
//
// The shape is the one `bin/moonsplice-longform` writes, because that is the fixture the Rust side
// measures against; this is the same edit from the window's side of the wall.

import { describe, expect, it } from "vitest";

import type { AudioView, CueView, NodeView, Outline, Track } from "../types";
import { fitZoom, fraction, isAudio, lanes, ticks, timeAt, ZOOM_MAX } from "./lanes";
import { cue } from "../sound";

const MINUTES = 10;
const DURATION = MINUTES * 60;
const CHAPTERS = 10;
const LINES = 6;

/** Ten minutes: ten clips, the furniture, three cards under a camera, sixty lines of narration
 *  with their captions, a bed and an effect on every cut. */
function longform(): Outline {
  const nodes: NodeView[] = [];
  const tracks: Track[] = [];
  const cues: CueView[] = [];
  const audio: AudioView[] = [];
  const per = DURATION / CHAPTERS;

  for (let c = 0; c < CHAPTERS; c += 1) {
    const at = c * per;
    nodes.push({
      id: `video${c}`,
      kind: "video",
      index: nodes.length + 1,
      label: null,
      props: { x: 0, y: 0, w: 1920, h: 1080 },
      onscreen: [{ t0: at, t1: at + per }],
    });
    tracks.push({
      node: `video${c}`,
      index: nodes.length,
      prop: "opacity",
      segments: [{ kind: "tween", manual: false, t0: at, t1: at + 0.8, from: 0, to: 1, ease: "sineInOut" }],
    });
    audio.push({
      id: `sfx${c}`,
      kind: "sfx",
      at,
      duration: 0.7,
      volume: 0.5,
      bus: false,
      label: "Whoosh",
    });
  }

  for (const [i, name] of ["plate", "rule", "mark", "title", "under"].entries()) {
    nodes.push({
      id: name,
      kind: i === 0 || i === 1 ? "rect" : "text",
      index: nodes.length + 1,
      label: null,
      props: { x: 96, y: 832, opacity: 0 },
    });
    tracks.push({
      node: name,
      index: nodes.length,
      prop: "opacity",
      // One per chapter: on at the top, off before the next one.
      segments: Array.from({ length: CHAPTERS }, (_, c) => ({
        kind: "tween" as const,
        manual: false,
        t0: c * per + 0.25,
        t1: c * per + 0.75,
        from: 0,
        to: 1,
        ease: "sineOut",
      })),
    });
  }

  nodes.push({ id: "camera", kind: "camera", index: nodes.length + 1, label: null, props: {} });
  for (let i = 0; i < 3; i += 1) {
    nodes.push({
      id: `card${i}`,
      kind: "rect",
      index: nodes.length + 1,
      label: null,
      props: { x: 520 + i * 440, y: 520, w: 460, h: 620, opacity: 0 },
      onscreen: [{ t0: 3 * per, t1: 3 * per + 12 }],
    });
  }

  nodes.push({ id: "captions", kind: "captions", index: nodes.length + 1, label: "Captions" });
  audio.push({ id: "bed", kind: "music", at: 0, duration: DURATION, volume: 0.16, bus: false, label: "Music bed" });
  for (let c = 0; c < CHAPTERS; c += 1) {
    let at = c * per + 1.5;
    for (let i = 0; i < LINES; i += 1) {
      const dur = 3.4;
      cues.push({ node: "captions", index: cues.length + 1, t0: at, t1: at + dur, text: `Line ${c}.${i}` });
      audio.push({
        id: `vo-${c}-${i}`,
        kind: "tts",
        at,
        duration: dur,
        volume: 1,
        bus: false,
        label: `Line ${c}.${i}`,
      });
      at += dur + 0.45;
    }
  }

  // A sound is a node in the composition and an entry in the mix, and the timeline pairs them by
  // id -- the same thing `s:audio` makes on the other side of the wall.
  for (const a of audio) {
    nodes.push({
      id: a.id,
      kind: a.kind,
      index: nodes.length + 1,
      label: a.label ?? null,
      props: {},
    });
  }

  return {
    comp: {
      width: 1920,
      height: 1080,
      duration: DURATION,
      fps: 30,
      background: [0, 0, 0],
      direct: false,
      title: "A place",
    },
    nodes,
    tracks,
    cues,
    audio,
    cli_only: [],
  };
}

describe("a ten minute edit in the timeline", () => {
  const outline = longform();

  it("draws every layer of a long edit, sound under the picture", () => {
    const began = performance.now();
    const built = lanes(outline);
    const took = performance.now() - began;

    // Everything that is in the composition is in the timeline: a lane per node, plus one per
    // sound, and nothing silently dropped because the list got long.
    expect(built.length).toBe(outline.nodes.length);
    expect(built.filter((l) => l.group === "sound").length).toBe(outline.audio.length);

    // Sound sits below the picture, in one block, the way an editor stacks it.
    const firstSound = built.findIndex((l) => l.group === "sound");
    expect(built.slice(firstSound).every((l) => l.group === "sound")).toBe(true);
    expect(built.slice(0, firstSound).every((l) => l.group === "picture")).toBe(true);

    // Every sound lane knows when it is audible, and the narration lands where it was placed.
    const line = built.find((l) => l.name.startsWith("Line 4.2"));
    expect(line?.audio?.at).toBeCloseTo(4 * 60 + 1.5 + 2 * 3.85, 6);
    expect(line?.clips).toEqual([{ t0: line!.audio!.at, t1: line!.audio!.at + 3.4 }]);
    expect(isAudio(line!.node.kind)).toBe(true);

    // The captions lane carries its sixty lines rather than sixty lanes of one line.
    const captions = built.find((l) => l.node.id === "captions");
    expect(captions?.cues.length).toBe(CHAPTERS * LINES);

    // And it is built in the time between two frames. A timeline that takes a beat to lay out
    // is a timeline that stutters every time the composition changes -- which, here, is every
    // edit anybody makes.
    expect(took, `laying out ${built.length} lanes took ${took.toFixed(1)} ms`).toBeLessThan(120);
  });

  it("counts a ten minute ruler in numbers a person reads", () => {
    // Zoomed to fit in a 1200px pane, and zoomed in to a second at a time.
    for (const width of [1200, 3000, 60_000]) {
      const marks = ticks(DURATION, width);
      expect(marks.length).toBeGreaterThan(2);
      expect(marks.length).toBeLessThan(width / 40);
      expect(marks[0]).toBe(0);
      // Every step is the same, and it is a number somebody would choose.
      const step = Math.round((marks[1] - marks[0]) * 1000) / 1000;
      expect([0.1, 0.25, 0.5, 1, 2, 5, 10, 15, 30, 60]).toContain(step);
      for (let i = 1; i < marks.length; i += 1) {
        expect(Math.round((marks[i] - marks[i - 1]) * 1000) / 1000).toBe(step);
      }
    }
  });

  it("lands on the frame it was pointed at, nine minutes in", () => {
    // A click at the far end of a ten minute track. The rounding has to survive the scale: at
    // 30 fps, ten minutes is eighteen thousand frames, and a click is one pixel of twelve
    // hundred -- which is fifteen frames, so the frame it lands on has to be the frame under
    // the pointer and not the one next to it.
    for (const t of [0, 1 / 30, 59.9, 300, 540.0333, DURATION]) {
      const x = fraction(t, DURATION);
      const back = timeAt(x, DURATION, 30);
      expect(Math.abs(back - Math.round(t * 30) / 30)).toBeLessThan(1 / 60);
      // And it is on the grid, which is what makes two clicks in one frame one cache key.
      expect(Math.abs(back * 30 - Math.round(back * 30))).toBeLessThan(1e-6);
    }

    // Fitting ten minutes into a pane fits ten minutes into the pane.
    //
    // This assertion used to say the opposite, and was passing: it required the fitted scale to
    // be at least `ZOOM_MIN` and the fitted content to be *wider* than the pane -- which is the
    // defect written down as an expectation. On screen it meant the timeline showed the first
    // eighty seconds of a ten minute edit and greyed out the Fit button, because as far as the
    // app knew it was already fitted. The floor that keeps a clip wide enough to click is for
    // zooming out by hand; fitting has a right answer and this is it.
    for (const pane of [600, 1200, 2400]) {
      const z = fitZoom(DURATION, pane);
      expect(z).toBeLessThanOrEqual(ZOOM_MAX);
      expect(z * DURATION).toBeLessThanOrEqual(pane + 0.5);
      expect(z * DURATION).toBeGreaterThan(pane - 1);
    }
    // And a short composition still fits at a scale anybody can work at, which is what the
    // floor was protecting and what it keeps protecting.
    expect(fitZoom(4, 1200)).toBe(ZOOM_MAX > 300 ? 300 : ZOOM_MAX);
  });
});

// The same ten minutes, heard rather than looked at.
//
// A scheduler is a thing that is right for four seconds and wrong for ten minutes: it keeps a
// window, and every bug it has is a clip that falls between two of them or is caught by both. So
// the test is the whole edit, played through in windows the way it is really played, with the
// mix counted at the end -- sixty lines, ten effects and a bed, each heard once, where it was
// put.
describe("ten minutes, heard", () => {
  const out = longform();
  const mix = out.audio ?? [];

  it("every line of a ten minute edit is heard once, where it was put", () => {
    const WINDOW = 1.2;
    const heard = new Map<string, number[]>();
    let at = 0;
    let fresh = true;
    while (at < DURATION) {
      for (const c of cue(mix, DURATION, at, WINDOW, fresh)) {
        const when = at + c.after;
        heard.set(c.node, [...(heard.get(c.node) ?? []), when]);
      }
      at += WINDOW;
      fresh = false;
    }

    // Everything in the mix was heard, and none of it twice.
    expect(heard.size).toBe(mix.length);
    for (const a of mix) {
      const when = heard.get(a.id);
      expect(when, `${a.id} was never cued`).toBeDefined();
      expect(when!.length, `${a.id} was cued ${when!.length} times`).toBe(1);
      // Within the window it was cued in -- a window is scheduled ahead, so the moment it is
      // handed over is the moment it sounds, not a window later.
      expect(Math.abs(when![0] - a.at), `${a.id} was cued at the wrong moment`).toBeLessThan(1e-9);
    }

    // And the sixty spoken lines are all there, which is the point of the thing.
    expect(mix.filter((a) => a.kind === "tts").length).toBe(CHAPTERS * LINES);
  });

  it("joins the bed and the line already speaking when playback starts in the middle", () => {
    // Dropping the playhead into the ninth minute has to pick up the music that started at zero
    // and whatever line is mid-sentence, not wait for the next thing to begin.
    const line = mix.find((a) => a.id === "vo-8-2")!;
    const into = 1.1;
    const cues = cue(mix, DURATION, line.at + into, 0.5, true);
    const ids = cues.map((c) => c.node);
    expect(ids).toContain("bed");
    expect(ids).toContain("vo-8-2");

    // Each one starts part way into its own file, by exactly how far in it already is.
    const spoken = cues.find((c) => c.node === "vo-8-2")!;
    expect(Math.abs(spoken.from - into)).toBeLessThan(1e-9);
    expect(spoken.after).toBe(0);
    const bed = cues.find((c) => c.node === "bed")!;
    expect(Math.abs(bed.from - (line.at + into))).toBeLessThan(1e-9);
  });

  it("costs nothing worth measuring to schedule a whole ten minutes", () => {
    // The tick runs beside playback, so the arithmetic for one window has to disappear next to
    // a frame. Ten minutes is five hundred windows; if all of them together are under a frame,
    // one of them is nothing.
    const t0 = performance.now();
    let at = 0;
    let fresh = true;
    while (at < DURATION) {
      cue(mix, DURATION, at, 1.2, fresh);
      at += 1.2;
      fresh = false;
    }
    const took = performance.now() - t0;
    // eslint-disable-next-line no-console
    console.log(`\nmix       ${Math.ceil(DURATION / 1.2)} windows scheduled in ${took.toFixed(1)} ms`);
    expect(took).toBeLessThan(1000 / 30);
  });
});
