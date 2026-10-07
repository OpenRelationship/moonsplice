// How the app says things. One place, because a number formatted two ways is two products.
//
// The rule behind all of it: a person reading this screen should never have to know that a
// composition is a file, that a property has a name in code, or that a curve has a camelCase
// identifier. Everything here translates one of those into words.

import vocab from "../vocabulary.json";

/** The words this app says out loud, shared with `src-tauri/src/words.rs`. They were two
 *  tables until they drifted: the timeline called a curve "Soft stop" while a notice called the
 *  same curve "Easing out". */
const vocabulary = vocab as {
  property: Record<string, string>;
  kind: Record<string, string>;
  curve: Record<string, string>;
  offline: Record<string, string>;
  curveMenu: string[];
};

/** `4.20s` is a receipt. `4.2s` is a duration. */
export function seconds(t: number): string {
  if (!Number.isFinite(t)) return "—";
  if (t === 0) return "0s";
  if (Math.abs(t) < 0.095) return `${Math.round(t * 1000)}ms`;
  // Past a minute, minutes. "600s" is a number a person has to do arithmetic on before it means
  // anything, and it is what the transport said the length of a ten minute edit was; the ruler
  // counted "540s" for nine minutes in. Nobody works in seconds at that scale.
  if (Math.abs(t) >= 60) {
    const sign = t < 0 ? "-" : "";
    // To a tenth, and no finer: a minute and a half is "1:30.5", not "1:30.50".
    const tenths = Math.round(Math.abs(t) * 10);
    const m = Math.floor(tenths / 600);
    const rest = (tenths - m * 600) / 10;
    const whole = Math.floor(rest);
    const frac = Math.round((rest - whole) * 10);
    return `${sign}${m}:${String(whole).padStart(2, "0")}${frac ? `.${frac}` : ""}`;
  }
  const s = t.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
  return `${s}s`;
}

/** A timecode for the playhead: `0:04.2`. Truncated, never rounded — a playhead that reads
 *  ahead of the frame on screen is a playhead nobody trusts. */
export function timecode(t: number): string {
  const clamped = Math.max(0, t);
  const m = Math.floor(clamped / 60);
  const s = Math.floor((clamped - m * 60) * 10) / 10;
  return `${m}:${s.toFixed(1).padStart(4, "0")}`;
}

const UNITS = ["bytes", "KB", "MB", "GB"];

export function size(bytes: number | null | undefined): string | null {
  if (bytes == null) return null;
  let v = bytes;
  let u = 0;
  while (v >= 1024 && u < UNITS.length - 1) {
    v /= 1024;
    u += 1;
  }
  return `${u === 0 ? v : v < 10 ? v.toFixed(1) : Math.round(v)} ${UNITS[u]}`;
}

/** What a kind of asset is called in the one place it is grouped and the one place it is shown.
 *  Plural, because it labels a group of them. */
export function assetKind(kind: string): string {
  const words: Record<string, string> = {
    footage: "Footage",
    image: "Pictures",
    audio: "Sound",
    font: "Type",
    data: "Notes",
    other: "Other",
  };
  return words[kind] ?? "Other";
}

/** `effect_hue_rotate` is a field name. "Hue" is what it does. */
export function property(key: string): string {
  return vocabulary.property[key] ?? spaced(key);
}

/** What a kind of thing is, in one word a person would use. */
export function kind(k: string): string {
  return vocabulary.kind[k] ?? spaced(k);
}

/** `expoOut` is an identifier. "Fast, then easing out" is a movement. */
export function curve(ease: string | undefined): string {
  if (!ease) return vocabulary.curve.linear;
  return vocabulary.curve[ease] ?? spaced(ease);
}

/** `effect_hueRotate` -> `Hue rotate`. The fallback, never the plan: a key with no word of its
 *  own is still shown as words, never as the identifier a programmer typed. */
function spaced(k: string): string {
  const stripped = k.replace(/^effect_/, "");
  const words = stripped
    .replace(/[_-]+/g, " ")
    .replace(/([a-z0-9])([A-Z])/g, (_m, a: string, b: string) => `${a} ${b.toLowerCase()}`);
  return words.charAt(0).toUpperCase() + words.slice(1);
}

/** Why a thing is not on the air, as the end of a sentence: "Beach Sunset is not where the
 *  composition left it." The renderer picks the word; this picks the words, and a word this
 *  side does not recognise gets the mildest of them rather than being shown raw. */
export function offlineWhy(word: string | undefined): string {
  if (!word) return vocabulary.offline["would not load"];
  return vocabulary.offline[word] ?? vocabulary.offline["would not load"];
}

/** What to say about the things that are not on the air. One reason wins when they share one,
 *  because "Three sounds are not where the composition left them" is a sentence somebody can
 *  act on and "3 offline nodes" is not. */
export function offlineSaid(
  things: { label?: string | null; kind: string; offline?: string }[],
): string | null {
  const out = things.filter((t) => t.offline);
  if (out.length === 0) return null;
  if (out.length === 1) return `${nodeName(out[0])} is ${offlineWhy(out[0].offline)}.`;
  const reasons = new Set(out.map((t) => t.offline));
  if (reasons.size === 1) return `${out.length} things are ${offlineWhy(out[0].offline)}.`;
  return `${out.length} things are not playing.`;
}

/** The curves offered in the picker, in the order somebody would look for them. */
export const CURVES: readonly string[] = vocabulary.curveMenu;

/** A value as the inspector shows it. Colours are their own thing and handled by the swatch. */
export function value(v: unknown): string {
  if (v == null) return "—";
  if (typeof v === "boolean") return v ? "yes" : "no";
  if (typeof v === "number") {
    if (Number.isInteger(v)) return String(v);
    return String(Math.round(v * 100) / 100);
  }
  if (Array.isArray(v)) return v.map((n) => Math.round(Number(n) * 255)).join(", ");
  return String(v);
}

/** What a thing is called on screen: its label if it has one, else what kind of thing it is. */
export function nodeName(node: { kind: string; label?: string | null }): string {
  const label = node.label?.trim();
  if (label) return label;
  return kind(node.kind);
}

/** Names for a whole composition at once.
 *
 *  A name that two things share is not a name. Nothing in the composition says which rectangle
 *  is which -- both are `rect` with no label -- so the honest fix is what a person does out
 *  loud: the first one, the second one. Only the ones that collide are numbered; a thing with a
 *  name of its own keeps it. */
export function names(nodes: { id: string; kind: string; label?: string | null }[]): Map<string, string> {
  const count = new Map<string, number>();
  for (const n of nodes) {
    const base = nodeName(n);
    count.set(base, (count.get(base) ?? 0) + 1);
  }
  const seen = new Map<string, number>();
  const out = new Map<string, string>();
  for (const n of nodes) {
    const base = nodeName(n);
    if ((count.get(base) ?? 0) < 2) {
      out.set(n.id, base);
      continue;
    }
    const nth = (seen.get(base) ?? 0) + 1;
    seen.set(base, nth);
    out.set(n.id, `${base} ${nth}`);
  }
  return out;
}

/** A colour from the outline's 0..1 triple, for a swatch. */
export function swatch(v: unknown): string | null {
  if (!Array.isArray(v) || v.length < 3) return null;
  const channels = v.slice(0, 3).map(Number);
  if (channels.some((n) => !Number.isFinite(n))) return null;
  const hex = channels
    .map((n) => Math.max(0, Math.min(255, Math.round(n * 255))).toString(16).padStart(2, "0"))
    .join("");
  return `#${hex}`;
}

/** A sentence for a list of changes: "moved the title" / "moved the title, and 3 more". */
export function changes(what: string[]): string {
  if (what.length === 0) return "nothing changed";
  if (what.length === 1) return what[0];
  return `${what[0]}, and ${what.length - 1} more`;
}
