*** Settings ***
Documentation    The engine: Rust + Lua on Bevy, our own motion-graphics renderer (continued)

*** Test Cases ***
What does not change
    [Documentation]    Comps and the authoring API. Seek-not-playback. The resolve phase before render. Audio mixed only
    ...    at encode by ffmpeg. One pinned YUV→RGB path. The Studio's UI, its agent, `lower.rs`, the fact log
    ...    and `moonsplice-vision`.
    [Tags]    doc    source:cadence@56ddad1:docs/ENGINE.md
    Skip    prose

