*** Settings ***
Documentation    Other people's apps, end to end (.robot/docs/connect.robot): a Tablua run, an agent driving the command
...    line and the person, against a real HTTP service on 127.0.0.1 (.robot/fixtures/connect/server.py) with a
...    throwaway keychain, the person's typing through a pseudo-terminal. Only the model is scripted. Run it:
...    luajit .robot/run.lua suites/connect
Test Tags    connect

*** Test Cases ***
The agent asks, the person connects and approves, and the key goes nowhere else
    [Documentation]    An unconnected service becomes an ask the run's result and `./moonsplice connect --asks` show;
    ...    an agent cannot connect a service or approve a call; the person connects at a terminal, the key never
    ...    echoed and kept only in the keychain; the run's call is then signed; a write waits for approval, runs once
    ...    approved once, and waits again; the key is in no message, row or log, and the login keychain is untouched.
    Command Succeeds    luajit .robot/fixtures/connect/e2e.lua

Connectory's own tests pass
    Command Succeeds    cd submodules && luajit -e 'package.path = "./?.lua;tablua/core/?.lua;" .. package.path' connectory/lua/http_test.lua
    Command Succeeds    cd submodules && luajit -e 'package.path = "./?.lua;tablua/core/?.lua;" .. package.path' connectory/lua/connect_test.lua

Tablua's connect tool passes its tests
    Command Succeeds    cd submodules/tablua && luajit test/run.lua connect
