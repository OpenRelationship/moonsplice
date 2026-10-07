-- The asks both arms get, in the words a person would use. Video asks may use the harbour footage
-- (evals/longform/Footage) and the 112 bpm music bed; games play themselves through a script.
return {
  { id = "harbour-minute", kind = "video", ask = "A 12-second piece about the harbour town in our footage. Make it feel authored, not templated." },
  { id = "tide-numbers", kind = "video", ask = "A 10-second data piece: the tide in this harbour rises 3.2 m twice a day. Make the number felt, using the sea footage." },
  { id = "nets-on-beat", kind = "video", ask = "An 8-second cut of the fisherman and the boats, timed to the music bed's beats." },
  { id = "night-title", kind = "video", ask = "A 6-second title sequence for a documentary called 'Night Ferry', from the night and ferry footage." },
  { id = "type-only", kind = "video", ask = "An 8-second kinetic-type piece (no footage) for the phrase 'every tide comes back'." },
  { id = "lighthouse-3d", kind = "video", ask = "A 6-second 3D shot of a lighthouse on a rock at dusk, built from primitives in the Bevy world, with its beam sweeping." },
  { id = "buoy-slalom", kind = "game", ask = "A 15-second game: steer a small boat between buoys against a current. Rapier physics. It must play itself through its script." },
  { id = "gull-catch", kind = "game", ask = "A 12-second game: a gull dives for fish that jump from the water; score on screen. Plays itself." },
  { id = "tide-pong", kind = "game", ask = "A 12-second two-paddle game where the playfield's water level rises and falls with a tide. Plays itself." },
  { id = "crane-stack", kind = "game", ask = "A 15-second dock-crane game: drop containers to stack them on a ship, with physics. Plays itself." },
  { id = "night-lights", kind = "game", ask = "A 12-second game in the Bevy 3D world: guide a lantern boat through a dark harbour to light the buoys. Plays itself." },
  { id = "storm-dodge", kind = "game", ask = "A 12-second game: a small boat dodges breaking waves in a storm; seeded randomness; plays itself." },
  -- the showcase (job showcase): the two eval ideas, judged separately (.robot/claims/quality.robot)
  { id = "tide-table", kind = "video", showcase = true, ask = "Tide Table: a 30-second film of the harbour town in our footage, built on one rule: a single horizontal waterline that rises and falls like a compressed tide, with every shot placed so its own water sits on that line and transitions that flood in below it. Type set like a nautical almanac. Use the music bed's beats for the cuts." },
  { id = "harbour-run", kind = "game", showcase = true, ask = "Harbour Run: a 20-second game where a small boat with rapier physics runs a course of numbered gates between real-looking harbour buoys, at dusk, with a wake, a race clock and an almanac-style HUD. It plays itself through its script and must be something you'd want to play." },
}
