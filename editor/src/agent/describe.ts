// What an approval asks, in one sentence.
//
// Never the raw arguments: a person deciding whether to allow a change should read the
// intention, and a JSON blob is not one. The agent is made to state its intention in the
// person's own words (`why`), which is what this shows when it has one.

export function describeAsk(tool: string, args: unknown): string {
  const a = (args ?? {}) as Record<string, unknown>;
  switch (tool) {
    case "change": {
      const reason = typeof a.why === "string" && a.why.trim() ? a.why.trim() : null;
      const n = Array.isArray(a.edits) ? a.edits.length : 0;
      if (reason) return `Change the composition — ${reason}`;
      return n === 1
        ? "Change one thing in the composition"
        : `Change ${n} things in the composition`;
    }
    case "undo":
      return "Put the composition back the way it was";
    case "export":
      return `Render this composition${
        typeof a.quality === "string" ? ` at ${a.quality} quality` : ""
      }`;
    case "repaint":
      return `Alter the rendered picture — ${
        typeof a.instruction === "string" ? a.instruction : "no detail given"
      }`;
    default:
      return `Run ${tool}`;
  }
}
