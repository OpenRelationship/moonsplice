*** Settings ***
Documentation    Is tablua the right harness for Moonsplice? Two arms do the same twelve asks (six videos, six games,
...              core/host/asks.lua) with the same writer, critic and moves (core/host/work.lua): ms-tablua, where tablua's
...              agent decides each move (Jev, with a logistic learner ranking moves in rank mode from earlier trials'
...              rows), and ms-plain, the Studio producer's fixed schedule. Job ab1. The oracle is independent of both
...              arms (core/host/run.lua): the gate again (moonsplice lint + check), a render, a critic blind to arm and
...              treatment scoring a contact sheet on six 1-5 items, and per-frame hashes taken twice. Kill numbers were
...              written before ab1 ran. If the gate, critic and cost claims are all killed, or the learner claim is,
...              tablua is a logging layer here, not the harness.

*** Test Cases ***
Tablua Passes The Gate More Often
    [Documentation]    Kill: tablua's gate pass rate is below plain's (needs 10 trials per arm).
    [Tags]    level:useful    predict:holds@0.55
    Use Runs    ab1
    Gate Rate Not Below Plain

The Critic Scores Tablua No Lower
    [Documentation]    Mean oracle critic score over gate-passing trials. Kill: tablua's mean is below plain's by more
    ...    than 0.1 (needs 6 passing trials per arm).
    [Tags]    level:useful    predict:holds@0.5
    Use Runs    ab1
    Critic Not Below Plain

Passing Pieces Cost No More
    [Documentation]    Agent USD per gate-passing trial (all trials' cost over the passes). Kill: tablua's is more than
    ...    1.5 times plain's.
    [Tags]    level:useful    predict:holds@0.4
    Use Runs    ab1
    Cost Per Pass Within    1.5

The Harness Never Reaches f(t)
    [Documentation]    Every gate-passing piece renders the same per-frame md5 twice. Kill: any passing trial unstable.
    [Tags]    level:consistent    predict:holds@0.9
    Use Runs    ab1
    All Passing Stable

Every Trial Ends
    [Documentation]    No trial dies (an error out of the arm itself, not a failed gate). Kill: any died.
    [Tags]    level:consistent    predict:holds@0.8
    Use Runs    ab1
    None Died

The Learner Beats The Base Rate
    [Documentation]    The logistic learner's p for the move taken (tablua_prediction, head step) against whether that
    ...    step's outcome was complete, on ab1's tablua steps. Kill: its Brier score is not below the base rate's
    ...    (the share of complete steps, predicted for every step). Needs 20 predicted steps.
    [Tags]    level:informative    predict:holds@0.35
    Use Runs    ab1
    Learner Brier Below Base Rate

Tablua Passes The Gate More Often (red)
    Use Fixture    insert into ms_trial (job, trial, arm, gate) values ${PLAIN_10_OF_10}, ${TABLUA_5_OF_10}
    Gate Rate Not Below Plain

The Critic Scores Tablua No Lower (red)
    Use Fixture    insert into ms_trial (job, trial, arm, gate, critic) values ('j','p1','plain',1,4),('j','p2','plain',1,4),('j','p3','plain',1,4),('j','p4','plain',1,4),('j','p5','plain',1,4),('j','p6','plain',1,4),('j','t1','tablua',1,3),('j','t2','tablua',1,3),('j','t3','tablua',1,3),('j','t4','tablua',1,3),('j','t5','tablua',1,3),('j','t6','tablua',1,3)
    Critic Not Below Plain

Passing Pieces Cost No More (red)
    Use Fixture    insert into ms_trial (job, trial, arm, gate, cost) values ('j','p1','plain',1,0.1),('j','p2','plain',1,0.1),('j','t1','tablua',1,0.5),('j','t2','tablua',0,0.5)
    Cost Per Pass Within    1.5

The Harness Never Reaches f(t) (red)
    Use Fixture    insert into ms_trial (job, trial, arm, gate, stable) values ('j','t1','tablua',1,1),('j','t2','tablua',1,0)
    All Passing Stable

Every Trial Ends (red)
    Use Fixture    insert into ms_trial (job, trial, arm, ended) values ('j','t1','tablua','answered'),('j','t2','tablua','died: boom')
    None Died

The Learner Beats The Base Rate (red)
    Use Fixture    ${CONFIDENTLY_WRONG}
    Learner Brier Below Base Rate

*** Variables ***
${PLAIN_10_OF_10}    ('j','p1','plain',1),('j','p2','plain',1),('j','p3','plain',1),('j','p4','plain',1),('j','p5','plain',1),('j','p6','plain',1),('j','p7','plain',1),('j','p8','plain',1),('j','p9','plain',1),('j','p10','plain',1)
${TABLUA_5_OF_10}    ('j','t1','tablua',1),('j','t2','tablua',1),('j','t3','tablua',1),('j','t4','tablua',1),('j','t5','tablua',1),('j','t6','tablua',0),('j','t7','tablua',0),('j','t8','tablua',0),('j','t9','tablua',0),('j','t10','tablua',0)
${CONFIDENTLY_WRONG}    insert into tablua_decision (todo, n, chosen, by) select 'x', value, 'write', 'jev' from (with recursive k(value) as (select 1 union all select value + 1 from k where value < 24) select value from k); insert into tablua_prediction (todo, n, head, move, p) select todo, n, 'step', 'write', case when n % 2 = 0 then 0.95 else 0.05 end from tablua_decision; insert into tablua_outcome (todo, n, verb, outcome, progress) select todo, n, 'write', case when n % 2 = 0 then 'broken' else 'complete' end, case when n % 2 = 0 then 0 else 1 end from tablua_decision

*** Keywords ***
Gate Rate Not Below Plain
    ${np}=    Value Of    select count(*) from ms_trial where arm = 'plain'
    ${nt}=    Value Of    select count(*) from ms_trial where arm = 'tablua'
    Needs At Least    ${np}    10    plain trials
    Needs At Least    ${nt}    10    tablua trials
    ${p}=    Value Of    select avg(gate) from ms_trial where arm = 'plain'
    ${t}=    Value Of    select avg(gate) from ms_trial where arm = 'tablua'
    Should Be True    ${t} >= ${p}    tablua passes ${t} of the time, plain ${p}

Critic Not Below Plain
    ${np}=    Value Of    select count(*) from ms_trial where arm = 'plain' and gate = 1 and critic is not null
    ${nt}=    Value Of    select count(*) from ms_trial where arm = 'tablua' and gate = 1 and critic is not null
    Needs At Least    ${np}    6    passing plain trials with a critic score
    Needs At Least    ${nt}    6    passing tablua trials with a critic score
    ${p}=    Value Of    select avg(critic) from ms_trial where arm = 'plain' and gate = 1 and critic is not null
    ${t}=    Value Of    select avg(critic) from ms_trial where arm = 'tablua' and gate = 1 and critic is not null
    Should Be True    ${t} >= ${p} - 0.1    tablua's mean critic ${t}, plain's ${p}

Cost Per Pass Within
    [Arguments]    ${ratio}
    ${pp}=    Value Of    select count(*) from ms_trial where arm = 'plain' and gate = 1
    ${tp}=    Value Of    select count(*) from ms_trial where arm = 'tablua' and gate = 1
    Needs At Least    ${pp}    1    passing plain trials
    Needs At Least    ${tp}    1    passing tablua trials
    ${p}=    Value Of    select sum(cost) / sum(gate) from ms_trial where arm = 'plain'
    ${t}=    Value Of    select sum(cost) / sum(gate) from ms_trial where arm = 'tablua'
    Should Be True    ${t} <= ${ratio} * ${p}    tablua $${t} per pass, plain $${p}

All Passing Stable
    ${n}=    Value Of    select count(*) from ms_trial where gate = 1
    Needs At Least    ${n}    1    passing trials
    ${bad}=    Value Of    select count(*) from ms_trial where gate = 1 and coalesce(stable, 0) != 1
    Should Be True    ${bad} == 0    ${bad} of ${n} passing pieces hashed differently twice

None Died
    ${n}=    Value Of    select count(*) from ms_trial
    Needs At Least    ${n}    1    trials
    ${died}=    Value Of    select count(*) from ms_trial where ended like 'died%'
    Should Be True    ${died} == 0    ${died} of ${n} trials died

Learner Brier Below Base Rate
    ${n}=    Value Of    select count(*) from tablua_prediction p join tablua_decision d on d.todo = p.todo and d.n = p.n and d.chosen = p.move join tablua_outcome o on o.todo = p.todo and o.n = p.n where p.head = 'step'
    Needs At Least    ${n}    20    steps with a prediction for the move taken
    ${model}=    Value Of    select avg((p.p - (o.outcome = 'complete')) * (p.p - (o.outcome = 'complete'))) from tablua_prediction p join tablua_decision d on d.todo = p.todo and d.n = p.n and d.chosen = p.move join tablua_outcome o on o.todo = p.todo and o.n = p.n where p.head = 'step'
    ${base}=    Value Of    with y as (select (o.outcome = 'complete') as y from tablua_prediction p join tablua_decision d on d.todo = p.todo and d.n = p.n and d.chosen = p.move join tablua_outcome o on o.todo = p.todo and o.n = p.n where p.head = 'step') select avg((y - (select avg(y) from y)) * (y - (select avg(y) from y))) from y
    Should Be True    ${model} < ${base}    the learner's Brier ${model}, the base rate's ${base}
