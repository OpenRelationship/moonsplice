*** Settings ***
Documentation    App
...
...    Deliverables. One folder per surface you ship. Surfaces consume `library/` as buck2 targets and `packages/` for third-party code.
Metadata    Source    cadence@56ddad1:app/AGENTS.md

*** Test Cases ***
Rules
    [Documentation]    - Add a sibling folder when a new surface is real, not before.
    ...    - Code used by two surfaces moves to `library/`.
    ...    - No surface-local manifest or lockfile. Dependencies come from `packages/`.
    ...    - Each surface has a `BUCK`. `just run //app/<surface>:<target>` is how it starts.
    [Tags]    doc    source:cadence@56ddad1:app/AGENTS.md
    Skip    prose

