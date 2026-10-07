*** Settings ***
Documentation    Is the work any good? The bar from .robot/docs/direction.robot §3.3: a blind critic (MiniMax M3, looking at a
...              contact sheet, not told the arm or the treatment) scores six items 1-5: rule, relationship, defaults,
...              rhythm, memory, craft. "Uniquely capable and quality" is set here as a mean of 4 with no item under 3,
...              on pieces that also pass the gate and hash the same twice. Two sets: the tablua arm across the twelve
...              asks (ab1), and the showcase (job showcase): the video eval (Tide Table) and the game eval (Harbour
...              Run), each made by the tablua agent with a larger budget, judged separately.

*** Test Cases ***
The Agent's Work Clears The Bar On Average
    [Documentation]    ab1, tablua arm, gate-passing trials. Kill: mean critic below 3.5.
    [Tags]    level:useful    predict:KILLED@0.55
    Use Runs    ab1
    Arm Mean At Least    tablua    3.5

The Video Eval Is Uniquely Good
    [Documentation]    showcase, the video eval. Kill: it fails the gate, hashes differently, has a mean under 4 or any
    ...    item under 3.
    [Tags]    level:useful    predict:holds@0.4
    Use Runs    showcase
    Showcase Clears    video

The Game Eval Is Uniquely Good
    [Documentation]    showcase, the game eval. Kill: as for the video.
    [Tags]    level:useful    predict:holds@0.35
    Use Runs    showcase
    Showcase Clears    game

The Agent's Work Clears The Bar On Average (red)
    Use Fixture    insert into ms_trial (job, trial, arm, gate, critic) values ('j','a','tablua',1,3.0),('j','b','tablua',1,3.2),('j','c','tablua',1,3.4),('j','d','tablua',0,null)
    Arm Mean At Least    tablua    3.5

The Video Eval Is Uniquely Good (red)
    Use Fixture    insert into ms_trial (job, trial, kind, arm, gate, stable, critic, critic_low) values ('j','v','video','tablua',1,1,4.2,2)
    Showcase Clears    video

The Game Eval Is Uniquely Good (red)
    Use Fixture    insert into ms_trial (job, trial, kind, arm, gate, stable, critic, critic_low) values ('j','g','game','tablua',1,0,4.5,4)
    Showcase Clears    game

*** Keywords ***
Arm Mean At Least
    [Arguments]    ${arm}    ${bar}
    ${n}=    Value Of    select count(*) from ms_trial where arm = '${arm}' and gate = 1 and critic is not null
    Needs At Least    ${n}    3    passing trials with a critic score
    ${m}=    Value Of    select avg(critic) from ms_trial where arm = '${arm}' and gate = 1 and critic is not null
    Should Be True    ${m} >= ${bar}    mean critic ${m} over ${n} passing ${arm} trials

Showcase Clears
    [Arguments]    ${kind}
    ${n}=    Value Of    select count(*) from ms_trial where kind = '${kind}'
    Needs At Least    ${n}    1    showcase ${kind} trials
    ${gate}=    Value Of    select gate from ms_trial where kind = '${kind}' order by at desc limit 1
    ${stable}=    Value Of    select coalesce(stable, 0) from ms_trial where kind = '${kind}' order by at desc limit 1
    ${mean}=    Value Of    select coalesce(critic, 0) from ms_trial where kind = '${kind}' order by at desc limit 1
    ${low}=    Value Of    select coalesce(critic_low, 0) from ms_trial where kind = '${kind}' order by at desc limit 1
    Should Be True    ${gate} == 1 and ${stable} == 1 and ${mean} >= 4 and ${low} >= 3    gate ${gate}, stable ${stable}, mean ${mean}, lowest ${low}
