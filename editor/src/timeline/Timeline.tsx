// The timeline.
//
// It works the way the timeline in any editor works, and that is the point. A **clip** is a bar
// whose width is the stretch of time a thing is on screen, so the widest shape in a lane carries
// the answer to the first question anybody asks of a timeline; the engine measures that stretch
// (`core/moonsplice/onscreen.lua`) rather than the app guessing at it. A lane **opens** into one row
// per property, named — a composition with thirty things in it has a hundred properties, and all
// of them at once is what made this unreadable. Sound sits below picture, because it is read
// differently. The scale is a number of pixels per second a person can change, not a fit to the
// pane, so a long composition is scrolled rather than crushed.
//
// Inside an open lane, a movement is a teal bar with its curve drawn in it and a value set by
// hand is an amber diamond. That is not decoration: `app-shell` requires a manual value to read
// as a different kind of thing from a tween, and it *is* one — a movement relates two values
// over a duration, a pin is a value somebody decided at an instant.
//
// Every drag here names a lowering verb. The one that has none — moving where a movement starts
// — is attempted and refused, because the alternative is a second way to edit a composition.

import { activeTab, useStudio } from "../state";
import { Empty } from "../ui/bits";
import { Lanes } from "./LanesView";

export function Timeline() {
  const tab = useStudio((s) => activeTab(s));
  const height = useStudio((s) => s.timelineHeight);
  if (!tab) {
    return (
      <div className="shrink-0 border-t" style={{ height, borderColor: "var(--edge-soft)" }}>
        <Empty title="No composition open" />
      </div>
    );
  }
  return <Lanes tab={tab} height={height} />;
}
