*** Settings ***
Documentation    The known gaps against the bet (AGENTS.md, "Known gaps against the bet"), each reproduced by a probe in
...    .robot/fixtures/probe/. A test passes once its gap is fixed, so the suite is red until the engine work lands:
...    run it before and after each fix (luajit .robot/run.lua suites/gaps). Gaps 6 (curve kinds spelled four times)
...    and 7 (games replay from zero) are design debts with no failing behaviour to probe; their tests are the fixes'.
...    The probes were written in Cadence's audit (cadence-03, 2026-10-07) and moved here at the handoff.
Test Tags    gap

*** Test Cases ***
1 a system that fails at some times is a finding, not a dead comp
    Command Succeeds    luajit .robot/fixtures/probe/protect.lua

2 lint sees every frame render will draw
    Command Succeeds    luajit .robot/fixtures/probe/sampling.lua

3 a time lands on the frame its author meant
    Command Succeeds    luajit .robot/fixtures/probe/time.lua

4 a system cannot write into the host
    Command Succeeds    luajit .robot/fixtures/probe/sandbox.lua

5 what was authored is kept apart from the defaults
    Command Succeeds    luajit .robot/fixtures/probe/defaults.lua

8 the same comp hashes the same twice (Bevy 3D)
    Command Succeeds    luajit .robot/fixtures/probe/determinism.lua
