// What the effects panel shows, decided without any React in the way.
//
// The panel itself is a rendering of these answers, and these are the answers worth testing: which
// sections a thing has, which effects are actually doing something, and what a search over the
// catalogue finds.

import * as fmt from "../format";

/** The properties worth showing, grouped the way a person thinks about them. */
export const GROUPS: { title: string; keys: string[] }[] = [
  { title: "Place", keys: ["x", "y"] },
  { title: "Size", keys: ["w", "h", "r", "size", "scale"] },
  { title: "Look", keys: ["opacity", "rotation", "color", "tracking", "rx"] },
];

/** Every effect the app can set, in the order they read. Also the list shown when nothing is
 *  selected, which is the answer to "what can this do?" */
export const EFFECTS = [
  "effect_blur",
  "effect_brightness",
  "effect_contrast",
  "effect_saturate",
  "effect_hue_rotate",
  "effect_grayscale",
  "effect_sepia",
  "effect_invert",
  "effect_opacity",
];

/** What each one does, in one sentence. The catalogue is the only place in the app that has to
 *  explain an effect rather than show it, because nothing is selected to show it on. */
export const DOES: Record<string, string> = {
  effect_blur: "Softens it, as if out of focus.",
  effect_brightness: "Makes it lighter or darker overall.",
  effect_contrast: "Pushes the darks and lights apart, or lets them close.",
  effect_saturate: "How much colour there is, from grey to vivid.",
  effect_hue_rotate: "Turns every colour around the wheel.",
  effect_grayscale: "Takes the colour out.",
  effect_sepia: "Warms it towards an old photograph.",
  effect_invert: "Swaps light for dark and every colour for its opposite.",
  effect_opacity: "How much of it you can see through.",
};

/** An effect nobody has touched, so the panel can say which ones are actually doing something. */
export const RESTING: Record<string, number> = {
  effect_blur: 0,
  effect_brightness: 1,
  effect_contrast: 1,
  effect_saturate: 1,
  effect_hue_rotate: 0,
  effect_grayscale: 0,
  effect_sepia: 0,
  effect_invert: 0,
  effect_opacity: 1,
};

type Props = Record<string, unknown> | null | undefined;

const has = (props: Props, key: string) => props != null && key in props;

/** The sections a selected thing actually has: a group with none of its properties is not an
 *  empty section, it is no section. */
export function sections(props: Props): { title: string; keys: string[] }[] {
  const out = GROUPS.map((g) => ({ title: g.title, keys: g.keys.filter((k) => has(props, k)) })).filter(
    (g) => g.keys.length > 0,
  );
  return out;
}

/** The effects this thing takes, and how many of them are away from their resting value. */
export function effectsOn(props: Props): { keys: string[]; busy: number } {
  const keys = EFFECTS.filter((k) => has(props, k));
  const busy = keys.filter((k) => Number(props?.[k]) !== RESTING[k]).length;
  return { keys, busy };
}

/** The catalogue search: over the words a person reads, never the keys underneath them. */
export function matching(find: string): string[] {
  const want = find.trim().toLowerCase();
  if (want === "") return [...EFFECTS];
  return EFFECTS.filter(
    (k) => fmt.property(k).toLowerCase().includes(want) || DOES[k]?.toLowerCase().includes(want),
  );
}
