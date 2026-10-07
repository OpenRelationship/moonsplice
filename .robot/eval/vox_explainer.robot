*** Settings ***
Documentation       Can an agent turn one long take into a five-minute Vox-style explainer with Moonsplice?
...
...                 The footage is IMG_6213.MOV: thirteen and a half minutes of one person talking
...                 to a phone held upright. Each harness gets the same fresh project and the same
...                 goal (goal.md), works on its own, and leaves a composition behind. The suite then
...                 lints it, renders it, measures the edit from the composition itself, and asks a
...                 judge model the questions that need taste. Every criterion is its own keyword,
...                 so the report says which ones failed rather than only that something did.
...
...                 robot --include claude    evals/agent      Claude Code CLI with the moonsplice skill
...                 robot --include moonsplice   evals/agent      moonsplice agent, the headless harness
...                 robot --include smoke     evals/agent      the scorer on a hand-cut fixture

Library             MoonspliceEval.py
Suite Setup         Suite Prerequisites
Suite Teardown      Write Summary    ${OUT}


*** Variables ***
${OUT}                      ${CURDIR}/out/manual
${GOAL_FILE}                ${CURDIR}/goal.md
${TIMEOUT}                  90 min
${RENDER_TIMEOUT}           60 min
${FOOTAGE_MODE}             upright
${HARNESS_MODEL_CLAUDE}     ${EMPTY}
${HARNESS_MODEL_MOONSPLICE}    ${EMPTY}
${CLAUDE_MAX_TURNS}         200
${CLAUDE_MAX_BUDGET_USD}    ${EMPTY}
${CLAUDE_VISION_MCP}        true
${MOONSPLICE_BUDGET}           400
${MOONSPLICE_TURNS}            40
${JUDGE_MODEL}              sonnet

# Pass marks. Loose enough that a competent edit passes, tight enough that a stub does not.
${MIN_DURATION_S}           270
${MAX_DURATION_S}           330
${MIN_SEGMENTS}             8
${MIN_SOURCE_AUDIO_PCT}     70
${MAX_REUSE_S}              2
${MIN_CLEAN_CUT_PCT}        80
${MIN_LIP_SYNC_PCT}         90
${MIN_VISUAL_NODES}         20
${MIN_TEXT_PCT}             40
${MIN_SECTION_CARDS}        3
${MIN_GRAPHIC_KINDS}        3
${MIN_JUDGE_MEAN}           3.0


*** Test Cases ***
Claude CLI Builds A Vox Explainer
    [Documentation]    Claude Code, headless, with the moonsplice skill installed in the project.
    [Tags]    claude    harness
    Prepare Fresh Project    ${OUT}    claude    footage_mode=${FOOTAGE_MODE}
    Run Claude Cli    ${OUT}    ${GOAL_FILE}    model=${HARNESS_MODEL_CLAUDE}    timeout=${TIMEOUT}
    ...    max_turns=${CLAUDE_MAX_TURNS}    with_vision_mcp=${CLAUDE_VISION_MCP}
    ...    max_budget_usd=${CLAUDE_MAX_BUDGET_USD}
    Measure And Judge    claude

Moonsplice Agent Builds A Vox Explainer
    [Documentation]    Our own harness: the studio's agent, run headless by moonsplice agent.
    [Tags]    moonsplice    harness
    Prepare Fresh Project    ${OUT}    moonsplice-agent    footage_mode=${FOOTAGE_MODE}
    Run Moonsplice Agent    ${OUT}    ${GOAL_FILE}    model=${HARNESS_MODEL_MOONSPLICE}    timeout=${TIMEOUT}
    ...    budget=${MOONSPLICE_BUDGET}    turns=${MOONSPLICE_TURNS}
    Measure And Judge    moonsplice-agent

Scorer Runs End To End On A Hand-Cut Fixture
    [Documentation]    Forty seconds in four pieces, cut on word gaps, with a title, two cards and
    ...    captions. Proves every measurement runs. It is short on purpose, so the duration and
    ...    graphics checks are expected to fail; the clean-cut and lip-sync checks must pass.
    [Tags]    smoke
    Build Smoke Fixture    ${OUT}
    Measure And Judge    smoke


*** Keywords ***
Suite Prerequisites
    Verify Footage
    Check Prerequisites
    Upright Footage
    Source Words

Measure And Judge
    [Arguments]    ${harness}
    Record Process    ${OUT}    ${harness}
    ${comp}=    Find Comp    ${OUT}    ${harness}
    Set Test Variable    ${COMP}    ${comp}
    Lint And Check    ${OUT}    ${harness}    ${comp}
    ${render}=    Render    ${OUT}    ${harness}    ${comp}    timeout=${RENDER_TIMEOUT}
    Analyze Comp    ${OUT}    ${harness}    ${comp}
    IF    ${render}[ok]
        Judge    ${OUT}    ${harness}    model=${JUDGE_MODEL}
    END
    # Every criterion runs and reports, even after one fails.
    Run Keyword And Continue On Failure    Composition Lints And Checks Clean    ${harness}
    Run Keyword And Continue On Failure    Composition Renders    ${harness}
    Run Keyword And Continue On Failure    Length Is About Five Minutes    ${harness}
    Run Keyword And Continue On Failure    Frame Is 16 By 9 At 1080p    ${harness}
    Run Keyword And Continue On Failure    His Words Carry The Piece    ${harness}
    Run Keyword And Continue On Failure    The Take Is Actually Cut Down    ${harness}
    Run Keyword And Continue On Failure    Nothing Is Said Twice    ${harness}
    Run Keyword And Continue On Failure    No Cut Lands Mid Word    ${harness}
    Run Keyword And Continue On Failure    Picture Stays In Sync With Voice    ${harness}
    Run Keyword And Continue On Failure    Opens On A Title Card    ${harness}
    Run Keyword And Continue On Failure    Has Section Cards    ${harness}
    Run Keyword And Continue On Failure    Is Dense With Graphics    ${harness}
    Run Keyword And Continue On Failure    Type Is On Screen Much Of The Time    ${harness}
    Run Keyword And Continue On Failure    Judge Rates It Competent    ${harness}

Composition Lints And Checks Clean
    [Arguments]    ${harness}
    ${lint}=    Metric    ${OUT}    ${harness}    lint.lint.errors
    ${check}=    Metric    ${OUT}    ${harness}    lint.check.errors
    Should Be True    ${lint} == 0 and ${check} == 0    lint errors ${lint}, check errors ${check}

Composition Renders
    [Arguments]    ${harness}
    ${ok}=    Metric    ${OUT}    ${harness}    render.ok
    Should Be True    ${ok}    the composition did not render

Length Is About Five Minutes
    [Arguments]    ${harness}
    ${d}=    Metric    ${OUT}    ${harness}    render.duration_s
    Should Be True    ${MIN_DURATION_S} <= ${d} <= ${MAX_DURATION_S}    rendered ${d}s, want ${MIN_DURATION_S}-${MAX_DURATION_S}s

Frame Is 16 By 9 At 1080p
    [Arguments]    ${harness}
    ${w}=    Metric    ${OUT}    ${harness}    render.width
    ${h}=    Metric    ${OUT}    ${harness}    render.height
    Should Be True    ${w} == 1920 and ${h} == 1080    rendered ${w}x${h}

His Words Carry The Piece
    [Arguments]    ${harness}
    ${pct}=    Metric    ${OUT}    ${harness}    comp.source_audio_on_air_pct
    Should Be True    ${pct} >= ${MIN_SOURCE_AUDIO_PCT}    his sound is on air ${pct}% of the time, want ${MIN_SOURCE_AUDIO_PCT}%

The Take Is Actually Cut Down
    [Arguments]    ${harness}
    ${n}=    Metric    ${OUT}    ${harness}    comp.segments
    Should Be True    ${n} >= ${MIN_SEGMENTS}    ${n} pieces of the take, want at least ${MIN_SEGMENTS}

Nothing Is Said Twice
    [Arguments]    ${harness}
    ${s}=    Metric    ${OUT}    ${harness}    comp.media_reuse_s
    ${n}=    Metric    ${OUT}    ${harness}    comp.segments
    Should Be True    ${n} > 0 and ${s} <= ${MAX_REUSE_S}    ${s}s of the take used more than once (${n} pieces)

No Cut Lands Mid Word
    [Arguments]    ${harness}
    ${pct}=    Metric    ${OUT}    ${harness}    comp.clean_cut_pct
    ${bad}=    Metric    ${OUT}    ${harness}    comp.mid_word_cut_times
    Should Be True    ${pct} >= ${MIN_CLEAN_CUT_PCT}    ${pct}% of cuts on a gap; mid-word at ${bad}

Picture Stays In Sync With Voice
    [Arguments]    ${harness}
    ${pct}=    Metric    ${OUT}    ${harness}    comp.lip_sync_pct
    Should Be True    $pct is not None and $pct >= ${MIN_LIP_SYNC_PCT}    lip sync ${pct}%

Opens On A Title Card
    [Arguments]    ${harness}
    ${ok}=    Metric    ${OUT}    ${harness}    comp.title_in_first_10s
    Should Be True    ${ok}    no large type in the first ten seconds

Has Section Cards
    [Arguments]    ${harness}
    ${n}=    Metric    ${OUT}    ${harness}    comp.section_cards
    Should Be True    ${n} >= ${MIN_SECTION_CARDS}    ${n} section cards, want ${MIN_SECTION_CARDS}

Is Dense With Graphics
    [Arguments]    ${harness}
    ${n}=    Metric    ${OUT}    ${harness}    comp.visual_nodes
    ${kinds}=    Metric    ${OUT}    ${harness}    comp.graphic_kinds
    ${k}=    Get Length    ${kinds}
    Should Be True    ${n} >= ${MIN_VISUAL_NODES} and ${k} >= ${MIN_GRAPHIC_KINDS}    ${n} graphic nodes of ${k} kinds ${kinds}

Type Is On Screen Much Of The Time
    [Arguments]    ${harness}
    ${pct}=    Metric    ${OUT}    ${harness}    comp.text_on_screen_pct
    Should Be True    ${pct} >= ${MIN_TEXT_PCT}    type on screen ${pct}% of the time, want ${MIN_TEXT_PCT}%

Judge Rates It Competent
    [Arguments]    ${harness}
    ${mean}=    Metric    ${OUT}    ${harness}    judge.mean
    ${scores}=    Metric    ${OUT}    ${harness}    judge.scores
    Should Be True    ${mean} >= ${MIN_JUDGE_MEAN}    judge mean ${mean}: ${scores}
