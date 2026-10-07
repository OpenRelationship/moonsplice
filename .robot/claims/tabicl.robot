*** Settings ***
Documentation    Is the Candle TabICL in Moonsplice's binary (tabicl/, host.tabicl) the TabICLv2 that tablua's server ran
...              (tabicl 2.2.0, scikit-learn 1.9.1, scipy 1.18.1)? Measured against tablua-local's parity fixtures
...              (tl/tabicl_parity.py): three tables (toy, steps, scores), each with 1 and 4 ensemble members.
...              Level 1 is the network alone, level 2 the preprocessing and ensemble, level 3 raw rows to probas.

*** Variables ***
${FIXTURES}    ~/tablua-local/data/tabicl-parity
${SHEETS}      tablua/.robot/runs/studio-s*.sqlite

*** Test Cases ***
The Network Matches TabICL's Forward Pass
    [Documentation]    Every fixture's forward calls, inputs to logits: max |Δlogit| ≤ 1e-3 (float32 on two
    ...    libraries; logits run to about 12). Kill: any fixture above it.
    [Tags]    level:consistent    predict:holds@0.9
    Use TabICL Parity    ${FIXTURES}
    Parity Within    level1    1e-3

The Ensemble Matches TabICL's Preprocessing
    [Documentation]    Every member's input table (encoding, scaling, Yeo-Johnson, outlier clipping, Latin-square
    ...    feature order, class shift) matches one of the fixture's forward calls to 1e-5. Kill: a member
    ...    matches none, or any above it.
    [Tags]    level:consistent    predict:holds@0.85
    Use TabICL Parity    ${FIXTURES}
    Members Match    1e-5

Raw Rows Give TabICL's Probabilities
    [Documentation]    The whole call, tablua's raw rows to predict_proba: max |Δp| ≤ 1e-4. Kill: any above it.
    [Tags]    level:useful    predict:holds@0.85
    Use TabICL Parity    ${FIXTURES}
    Parity Within    level3    1e-4

TabICL Predicts Step Outcomes Better Than Logistic
    [Documentation]    On tablua's studio steps (one sheet per trial, rows as its ranker sees them), each trial
    ...    held out in turn: TabICL's Brier score on whether a step completes is below a logistic regression's
    ...    and below the base rate's. Kill: it is not below both. Needs 2 trials and 20 labelled steps.
    [Tags]    level:useful    predict:holds@0.55
    ${b}=    Brier Held Out By Trial    ${SHEETS}    min=20
    ${m}=    TabICL Margin    ${b}
    Should Be True    ${m} > 0    TabICL's Brier is not below both logistic's and the base rate's (${b})

TabICL Predicts Step Outcomes Better Than Logistic (red)
    ${b}=    Brier Scores    0.24    0.20    0.21
    ${m}=    TabICL Margin    ${b}
    Should Be True    ${m} > 0    TabICL's Brier is not below both logistic's and the base rate's (${b})

The Network Matches TabICL's Forward Pass (red)
    Use Fixture    insert into ms_parity values ('toy-e1', 0.4, 0, 0, 1, 1, 0.01), ('a', 0, 0, 0, 1, 1, 0), ('b', 0, 0, 0, 1, 1, 0), ('c', 0, 0, 0, 1, 1, 0), ('d', 0, 0, 0, 1, 1, 0), ('e', 0, 0, 0, 1, 1, 0)
    Parity Within    level1    1e-3

The Ensemble Matches TabICL's Preprocessing (red)
    Use Fixture    insert into ms_parity values ('toy-e4', 0, 0, 0, 3, 4, 0)
    Members Match    1e-5

Raw Rows Give TabICL's Probabilities (red)
    Use Fixture    insert into ms_parity values ('toy-e1', 0, 0, 0, 1, 1, 0.003), ('a', 0, 0, 0, 1, 1, 0), ('b', 0, 0, 0, 1, 1, 0), ('c', 0, 0, 0, 1, 1, 0), ('d', 0, 0, 0, 1, 1, 0), ('e', 0, 0, 0, 1, 1, 0)
    Parity Within    level3    1e-4

*** Keywords ***
Parity Within
    [Arguments]    ${level}    ${tol}
    ${n}=    Value Of    select count(*) from ms_parity
    Needs At Least    ${n}    6    fixtures measured
    ${worst}=    Value Of    select max(${level}) from ms_parity
    Should Be True    ${worst} <= ${tol}    worst ${level} ${worst} over ${n} fixtures

Members Match
    [Arguments]    ${tol}
    ${n}=    Value Of    select count(*) from ms_parity
    Needs At Least    ${n}    1    fixtures measured
    ${short}=    Value Of    select count(*) from ms_parity where matched < members
    Should Be True    ${short} == 0    ${short} fixtures with a member that matches no forward call
    ${worst}=    Value Of    select max(max(encoded, member_x)) from ms_parity
    Should Be True    ${worst} <= ${tol}    worst input difference ${worst}
