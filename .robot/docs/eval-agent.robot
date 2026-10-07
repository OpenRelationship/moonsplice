*** Settings ***
Documentation    Agent eval: a Vox explainer from one long take
...
...    This eval asks whether an agent can take `IMG_6213.MOV` and build a five-minute, Vox-style
...    explainer from it as a Moonsplice composition. The footage is 13.6 minutes of one person talking to
...    a phone held upright. The narration has to be his own words, cut down. Two harnesses do the same
...    task from the same fresh project with the same goal (`goal.md`):
...
...    | tag | harness | how it reaches Moonsplice |
...    | --- | --- | --- |
...    | `claude` | Claude Code CLI (`claude -p`) | the `moonsplice` skill (copied from `skills/moonsplice/` into the project), `moonsplice` and `moonsplice-agent` on PATH, and the moonsplice-vision MCP |
...    | `moonsplice` | `moonsplice agent run`, the studio's agent run headless | its own tools |
...    | `smoke` | none: a hand-cut 40-second fixture | checks that every measurement runs |
...
...    ```bash
...    bin/moonsplice-eval-agent smoke \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # about 1 minute, about $0.07 for the judge
...    bin/moonsplice-eval-agent claude \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # one Claude run
...    bin/moonsplice-eval-agent moonsplice \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # one moonsplice-agent run
...    bin/moonsplice-eval-agent \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # both
...    bin/moonsplice-eval-agent claude -v HARNESS_MODEL_CLAUDE:opus -v TIMEOUT:"120 min"
...    just eval-agent claude \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ # same thing
...    ```
...
...    The first run creates `evals/agent/.venv` (Robot Framework) and fills `evals/agent/.cache/`:
...    - an upright H.264 transcode of the footage (about 530 MB, about 1 minute with VideoToolbox);
...    - a word-timed transcript (faster-whisper `small.en` on the CPU, about 3 minutes).
...
...    Both are keyed by the footage's sha256. The footage defaults to `~/Downloads/IMG_6213.MOV`; set
...    `MOONSPLICE_EVAL_FOOTAGE` to use a copy somewhere else. A file whose hash does not match
...    `fixture.json` is refused.
Metadata    Source    cadence@56ddad1:evals/agent/README.md

*** Test Cases ***
Where results go
    [Documentation]    Each run writes to `evals/agent/out/<run>/`, which contains `report.html`, `log.html` and
    ...    `summary.md` (the harnesses side by side). Each harness gets its own folder with:
    ...
    ...    - `project/`: what the agent built.
    ...    - `prompt.md`.
    ...    - The agent's transcript: `claude.ndjson`, or `events.ndjson` plus `run.json`.
    ...    - `process.json`: wall time, cost, turns, tool calls and how the run stopped.
    ...    - `metrics.json`: every measurement.
    ...    - `render.mp4`.
    ...    - `contact_sheet.jpg`.
    ...    - `cut_transcript.txt`: the narration actually heard.
    ...    - `judge.json`.
    [Tags]    doc    source:cadence@56ddad1:evals/agent/README.md
    Skip    prose

What is measured
    [Documentation]    Each criterion is its own Robot keyword, so the report lists exactly which ones failed. Every
    ...    criterion runs even after an earlier one fails.
    ...
    ...    | criterion | measured from | pass |
    ...    | --- | --- | --- |
    ...    | lints and checks clean | `moonsplice lint/check --json` | 0 errors |
    ...    | renders | `moonsplice render` (draft quality, full size) | succeeds |
    ...    | about five minutes | ffprobe on the render | 270–330 s |
    ...    | 16:9 at 1080p | ffprobe | 1920x1080 |
    ...    | his words carry the piece | his audio's on-air intervals, from the comp | ≥ 70% of the duration |
    ...    | the take is cut down | the number of pieces of the source in the narration | ≥ 8 |
    ...    | nothing is said twice | overlap of the media ranges used | ≤ 2 s |
    ...    | no cut lands mid-word | cut points (media time) against the source transcript | ≥ 80% on gaps |
    ...    | picture in sync with voice | where both his picture and his sound are on air, same media offset | ≥ 90% |
    ...    | opens on a title card | large type (≥ 56 px) visible in the first 10 s | yes |
    ...    | section cards | large type first appearing at times ≥ 20 s apart, title excluded | ≥ 3 |
    ...    | dense with graphics | non-footage visual nodes, and how many kinds | ≥ 20 nodes, ≥ 3 kinds |
    ...    | type on screen | sampled at 2 fps from the comp's evaluated state | ≥ 40% |
    ...    | judge rates it competent | `claude -p --model sonnet` on a 24-frame contact sheet and the cut transcript, scored 1–5 on hook, through-line, visual explanation, polish and faithfulness | mean ≥ 3.0 |
    ...
    ...    The comp measurements come from `vision/lua/props.lua`, which evaluates the composition without a
    ...    renderer, so they are exact rather than read back from pixels. Process numbers (wall time, cost,
    ...    turns, tool calls, whether it said it was done) are recorded but are not pass marks. Every
    ...    threshold is a Robot variable; override it with `-v NAME:value`.
    ...
    ...    Use sonnet for the judge. In testing, haiku scored the 40-second smoke fixture 3.0, while sonnet
    ...    scored it 1.8 with specific, correct reasons.
    [Tags]    doc    source:cadence@56ddad1:evals/agent/README.md
    Skip    prose

Cost and time
    [Documentation]    A full harness run is open-ended, with a 90-minute timeout by default. The eval's own work after
    ...    the run takes about 5–10 minutes: the render (a 5-minute comp at full size with 1080p footage,
    ...    roughly 2–6 minutes), the comp analysis and the judge (about $0.07). Claude's spend is in
    ...    `process.json` (`total_cost_usd` from the CLI); cap it with `-v CLAUDE_MAX_BUDGET_USD:20`.
    [Tags]    doc    source:cadence@56ddad1:evals/agent/README.md
    Skip    prose

Known renderer gaps the eval works around
    [Documentation]    - **Rotation.** The phone stores the picture landscape with a −90° display matrix, and Moonsplice's
    ...    \ \ decoder ignores it, so the raw `.MOV` paints sideways. Agents get the upright transcode by
    ...    \ \ default. `-v FOOTAGE_MODE:raw` hands them the original instead, which tests whether an agent
    ...    \ \ notices and works around it.
    ...    - **Sound from footage.** A `video` node paints pictures only. His voice needs an `audio` node
    ...    \ \ with the same `src` and the same `media_start`/`from` timing. The eval counts the audio nodes
    ...    \ \ as the narration and checks that the picture is in sync with them.
    [Tags]    doc    source:cadence@56ddad1:evals/agent/README.md
    Skip    prose

evals/agent/goal.md
    [Documentation]    Turn the footage in this project into a five-minute explainer in the style of Vox, built as a
    ...    Moonsplice composition.
    ...
    ...    The footage is one person talking to the camera for about thirteen and a half minutes, shot
    ...    vertically on a phone. He is the narrator: keep his own words and his own voice, cut down. Do
    ...    not write new narration and do not generate a voice.
    ...
    ...    What to make:
    ...
    ...    - One composition file, the one this project already has, 1920x1080 at 30 fps, between 4:30 and
    ...    \ \ 5:30 long.
    ...    - A tight through-line taken from what he says: open on a hook, move through a clear structure,
    ...    \ \ and land a payoff. Cut out false starts, repetition, filler and tangents. Never cut in the
    ...    \ \ middle of a word, and keep his picture in sync with his voice whenever he is on screen.
    ...    - His vertical picture placed inside a designed 16:9 frame rather than stretched or left in
    ...    \ \ black bars, with the layout changing as the piece moves.
    ...    - The visual language of a Vox explainer: a title card at the start, a card for each chapter or
    ...    \ \ section, kinetic type for key phrases, captions or pull quotes, and explanatory graphics:
    ...    \ \ callouts, diagrams, charts or maps wherever what he says supports one. Graphics must say
    ...    \ \ something true about what he is saying at that moment.
    ...    - One consistent visual system for colour, type and motion throughout.
    ...
    ...    You do not need to render the final video; the composition file is the deliverable. It must
    ...    pass `moonsplice lint` and `moonsplice check`. Work on your own until it is finished, because nobody
    ...    will answer questions.
    [Tags]    doc    source:cadence@56ddad1:evals/agent/goal.md
    Skip    prose

evals/agent/preamble/claude-cli.md
    [Documentation]    You are in a Moonsplice project folder (the current directory). The `moonsplice` skill in
    ...    .claude/skills/moonsplice explains how Moonsplice works; read it before you start. The `moonsplice` and
    ...    `moonsplice-agent` commands are on your PATH, and the moonsplice-vision MCP server is connected so you
    ...    can look at frames and contact sheets. The footage is in Footage/. The composition to write is
    ...    {comp}. The Moonsplice checkout at {root} has examples (comps/cases/) and docs (docs/) you may
    ...    read, but do not change anything outside this project folder.
    [Tags]    doc    source:cadence@56ddad1:evals/agent/preamble/claude-cli.md
    Skip    prose

evals/agent/preamble/moonsplice-agent.md
    [Documentation]    The project's footage is in Footage/ and the composition you are building is {comp}.
    [Tags]    doc    source:cadence@56ddad1:evals/agent/preamble/moonsplice-agent.md
    Skip    prose

