*** Settings ***
Documentation    Does the harness work on every model route it offers (core/host/models.lua)? Local: an Ollama model on
...              this Mac (only qwen3.5:0.8b, qwen3:0.6b and gemma3:270m fit; 2.6 GB of disk free). MiniMax direct: the
...              api.minimax.io route, which needs a key this machine does not have yet. Job routes.

*** Test Cases ***
The Harness Runs End To End On A Local Writer
    [Documentation]    A local-writer trial runs every step and the oracle without dying. Kill: it died.
    [Tags]    level:consistent    predict:holds@0.85
    Use Runs    routes
    Route Ran    local:%

A Local Writer Passes The Gate
    [Documentation]    At least one local-writer trial passes lint + check. Kill: none does.
    [Tags]    level:useful    predict:KILLED@0.8
    Use Runs    routes
    Route Passes    local:%

The Harness Runs On MiniMax Direct
    [Documentation]    A trial with a minimax:<model> writer (api.minimax.io) runs end to end. Kill: it died.
    [Tags]    level:consistent    predict:holds@0.6
    Use Runs    routes
    Route Ran    minimax:%

The Harness Runs End To End On A Local Writer (red)
    Use Fixture    insert into ms_trial (job, trial, writer, ended) values ('j','a','local:x','died: no route')
    Route Ran    local:%

A Local Writer Passes The Gate (red)
    Use Fixture    insert into ms_trial (job, trial, writer, gate) values ('j','a','local:x',0),('j','b','local:x',0)
    Route Passes    local:%

The Harness Runs On MiniMax Direct (red)
    Use Fixture    insert into ms_trial (job, trial, writer, ended) values ('j','a','minimax:MiniMax-M3','died: 401')
    Route Ran    minimax:%

*** Keywords ***
Route Ran
    [Arguments]    ${route}
    ${n}=    Value Of    select count(*) from ms_trial where writer like '${route}'
    Needs At Least    ${n}    1    trials on ${route}
    ${died}=    Value Of    select count(*) from ms_trial where writer like '${route}' and ended like 'died%'
    Should Be True    ${died} == 0    ${died} of ${n} died

Route Passes
    [Arguments]    ${route}
    ${n}=    Value Of    select count(*) from ms_trial where writer like '${route}'
    Needs At Least    ${n}    1    trials on ${route}
    ${p}=    Value Of    select coalesce(sum(gate), 0) from ms_trial where writer like '${route}'
    Should Be True    ${p} >= 1    ${p} of ${n} passed
