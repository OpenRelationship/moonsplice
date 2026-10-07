*** Settings ***
Documentation    The port of the Cadence tree into Moonsplice, as a Robot suite run by tablua's Lua runner.
...
...    The test cases are the dry run: they read Cadence at one commit, place every file by manifest.lua, and fail
...    on anything the plan does not account for. They write nothing. The tasks are the port itself: run them only
...    when every test passes, into a clean checkout, then cut the files the split plans name until rules.robot
...    passes.
...
...    luajit .robot/run.lua port    the dry run
...    luajit .robot/run.lua port --tasks --var COMMIT=<sha>    the port
...    luajit .robot/run.lua outline core/runtime/painter.lua    a file's chunks, to write its split plan
...
...    The order after the tasks: (1) the rewrites (Rewrites Left To Write) are written in Lua or Robot from the
...    Cadence file as reference; (2) each leftover reference is fixed by hand; (3) each oversized file is cut by its
...    plan in splits.lua, one file per commit, with the goldens (.robot/golden) and test/run.lua green before and
...    after; (4) rules.robot passes, and the port is done.
Metadata    Source    ~/cadence, or $CADENCE

*** Variables ***
${COMMIT}    HEAD
${CARRIED}    no

*** Test Cases ***
The Source Is One Commit
    [Documentation]    Every file comes from `git show <commit>:<path>`; uncommitted work in the areas that port would
    ...    be lost, so it must be committed first. Parked and dropped areas may be dirty.
    Use Source    ${COMMIT}
    Source Is Committed

Every Cadence File Is Placed
    [Documentation]    One rule per file, first match wins; no file is left behind by accident.
    Use Source    ${COMMIT}
    Every File Has A Rule
    Every Rule Is Used
    Plan Counts

No Two Files Collide
    Use Source    ${COMMIT}
    No Two Files Land On One Path

Every Markdown Page Becomes Robot Within The Limit
    [Documentation]    Each page is a suite: its sections are test cases tagged doc whose body is Skip until made
    ...    checkable. Long pages are cut at section boundaries into name-2.robot and on.
    Use Source    ${COMMIT}
    Docs Parse As Robot

Old Paths Left In Ported Text
    [Documentation]    rewrite.lua moves paths; what it cannot move safely is listed for a hand fix. This lists, it
    ...    does not fail.
    Use Source    ${COMMIT}
    Leftover References

Every Oversized File Has A Split Plan
    [Documentation]    A ported code file over 400 lines needs a split plan in splits.lua.
    Use Source    ${COMMIT}
    Every Oversized File Has A Split Plan

Every Split Plan Fits
    [Documentation]    Every module a plan makes measures 400 lines or fewer, from the file itself.
    Use Source    ${COMMIT}
    Show Split Sizes
    Every Split Plan Fits

What Is Rewritten By Hand
    Use Source    ${COMMIT}
    Rewrites Left To Write

*** Tasks ***
Port Cadence Into Moonsplice
    [Documentation]    --var CARRIED=yes ports the commit while others' uncommitted work is still in flight; each
    ...    owner carries their own changes over afterwards.
    Use Source    ${COMMIT}
    Source Is Committed    ${CARRIED}
    Every File Has A Rule
    No Two Files Land On One Path
    Docs Parse As Robot
    Every Oversized File Has A Split Plan
    Every Split Plan Fits
    Write Ported Files
    Write The Port Record
    Leftover References
    Rewrites Left To Write
