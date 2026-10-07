*** Settings ***
Documentation    Connecting other people's APIs
...
...    The agent should be able to use any service in connectory (submodules/connectory: 853 services, and
...    for those whose makers publish an API, every call it accepts, one Lua file per API) the moment a
...    piece needs it: a chart from a spreadsheet, captions from a speech service, footage from a stock
...    library, a post to a channel when the render is done. Connecting a service should take the person
...    one step, asked for at the moment it is needed, and the agent must never see the secret.
...
...    This page is the plan (owner, 2026-10-07). Nothing here is built in Moonsplice yet. connectory
...    already has the half that matters most: its connect port never holds a credential.
Metadata    Status    plan

*** Test Cases ***
What we take from Grok Bot
    [Documentation]    xAI's Grok Bot (docs.x.ai/grok-bot) is the model to follow. Four of its choices carry over:
    ...
    ...    - **A secret has its own field, never the conversation.** A connector that needs a key asks for it in
    ...    a secure input: masked, kept out of the transcript and never shown to the model. The agent can ask
    ...    for that input mid-conversation, but what is typed into it goes to the store, not to the agent.
    ...    - **The secret belongs to the connector.** It is stored apart and handed only to the calls of the
    ...    service it is for. The agent names the service; the host signs the call.
    ...    - **Actions with consequences are approved.** Sending, publishing, paying, deleting and changing
    ...    permissions wait for the person: allow once, always allow (a saved rule), or deny. An approval
    ...    covers the action proposed; it cannot undo one already done.
    ...    - **Least privilege, many accounts.** Connect only what a piece needs, prefer scoped keys, allow more
    ...    than one account per service (work and personal), and make revoking one as easy as adding it.
    ...
    ...    One choice we do not take: Grok Bot's Bots share one computer, so a secret written to its workspace
    ...    is visible to every Bot. Here a secret is never a file in the project.
    [Tags]    doc
    Skip    prose

What connectory already does
    [Documentation]    `submodules/connectory/lua/connect.lua` is the port. A pack (`providers/<id>/<id>.lua`) is
    ...    data loaded with no globals, and its `auth` names the credential by the environment variable it
    ...    would live in (`STRIPE_SECRET_KEY`), never the value. The port:
    ...
    ...    - `find(words)` and `operations(service, words)` let the agent discover a service and its calls;
    ...    - `needs(service)` lists the fields a connection takes (`{ name, label, secret }`) and which are
    ...    missing;
    ...    - `call(op, args)` signs the call with `secret(name)`, a function the host gives it, and returns the
    ...    value and a record (service, op, method, status, seconds) that is safe to log: never the address,
    ...    never a header;
    ...    - a call with no credential, or one the service refuses, fails with `needs`: what the person must
    ...    give, and where they get it (`docs`), so the agent can ask then and there.
    ...
    ...    So Moonsplice has three things to build: the store behind `secret(name)`, the ask, and the approval.
    [Tags]    doc
    Skip    prose

The flow
    [Documentation]    ```
    ...    agent: connect.find("speech to text") -> elevenlabs
    ...    agent: connect.call("elevenlabs.speech_to_text", args)
    ...    \ \ -> fails: needs { ELEVENLABS_API_KEY (secret) }, docs = where to get one
    ...    agent: ask_connection("elevenlabs") \ \ \ \ \ \ \ \ \ \ \ \ -- the agent asks; it never receives the answer
    ...    \ \ -> editor: a sheet with the service's logo, a masked field per secret, a link to its docs
    ...    \ \ -> cli, a person at the terminal: a prompt that does not echo
    ...    \ \ -> cli, driven by an agent: "run ./moonsplice connect elevenlabs" for the person to type
    ...    \ \ -> the value goes from the field straight to the store
    ...    agent: sees one row: connection elevenlabs, account "default", ok
    ...    agent: retries the call, signed by the host
    ...    ```
    [Tags]    doc
    Skip    prose

The store
    [Documentation]    One store for the editor and the command line, so connecting once works everywhere:
    ...
    ...    - **macOS:** the login Keychain, service `moonsplice`, account `<SERVICE>/<account>/<FIELD>`
    ...    (`elevenlabs/default/ELEVENLABS_API_KEY`). The editor reads it through Tauri; the command line
    ...    through `security find-generic-password`, so no daemon is needed. Other platforms use their own
    ...    keychain (Secret Service, Windows Credential Manager) behind the same names.
    ...    - **Environment second:** an environment variable of the field's name is used when the store has none,
    ...    so CI and a one-off shell need no keychain. The store never writes the environment.
    ...    - **Never a file in the project, never a row, never a log line.** AGENTS.md's convention (keys and
    ...    tokens are never logged, printed or written to files or rows) is the law here; a test should grep
    ...    the rows and logs of a run that used a connection for the value it was given.
    ...    - `secret(name)` is the only reader. The agent's tools get a signed call, never the function.
    [Tags]    doc
    Skip    prose

Connections and calls are rows
    [Documentation]    The bet (design.robot) says every fact has a row, and a connection is a fact. What is
    ...    stored as rows is everything but the value:
    ...
    ...    - `connection`: service, account, the field names present, when connected, the last check
    ...    (`connect.check(service)`, the directory's own test call) and its result.
    ...    - `call`: the record connectory returns, keyed to the step that made it, so a learner can see which
    ...    calls helped.
    ...    - `approval`: service, operation (or a pattern of them), the answer (once, always, denied), by
    ...    whom and when.
    ...
    ...    The agent reads these like any other rows, so "is Stripe connected?" is a query, not a question.
    [Tags]    doc
    Skip    prose

Calls never run at render
    [Documentation]    A comp is a pure function of time (P6), and an API answer is not. So a comp never calls an
    ...    API while rendering. A call runs in the resolve phase, or as an agent step, and its answer becomes an
    ...    asset: content-addressed, cached, and named in the comp's rows by its hash. Rendering again renders
    ...    the same answer; asking for a fresh one is a move that records a new asset. This is how footage and
    ...    generated speech already work (core/runtime/resolve/).
    [Tags]    doc
    Skip    prose

Approvals
    [Documentation]    A read (GET, and the calls a pack marks as reads) runs once the service is connected. Anything
    ...    else waits for the person the first time: allow once, always allow this operation (or this service),
    ...    or deny. The editor shows it beside the agent's message; the command line asks at the terminal, and a
    ...    driving agent gets "waiting for approval" with the command a person runs to answer. An agent can
    ...    never approve its own call. Saved rules are `approval` rows the person can see and revoke.
    [Tags]    doc
    Skip    prose

The command line
    [Documentation]    ```
    ...    ./moonsplice connect SERVICE [--account NAME] \ \ connect: asks for each missing field, without echo
    ...    ./moonsplice connect --list \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ \ every connection, as rows (names only)
    ...    ./moonsplice connect --check SERVICE \ \ \ \ \ \ \ \ \ \ \ the directory's test call
    ...    ./moonsplice connect --forget SERVICE [--account NAME]
    ...    ./moonsplice connect --find WORDS \ \ \ \ \ \ \ \ \ \ \ \ \ \ services and their calls
    ...    ```
    ...
    ...    When stdin is not a terminal (an agent is driving), `connect SERVICE` does not read a secret from it:
    ...    it prints the command for the person to run and exits 3. A secret is never piped through an agent.
    [Tags]    doc
    Skip    prose

Order of work
    [Documentation]    1. The store: `core/host/secrets.lua` (keychain through `security`, then environment), with
    ...    a test that a value never reaches rows or logs.
    ...    2. `./moonsplice connect` on the command line, with the no-echo prompt and the driven-by-an-agent
    ...    refusal.
    ...    3. The agent's tools in tablua: find, operations, call, and `ask_connection`, which returns only
    ...    whether the person connected.
    ...    4. `connection`, `call` and `approval` rows in rows.robot (P10: the schema first), then approvals.
    ...    5. The editor's sheet: the service's logo and name, masked fields, the docs link, and the approval
    ...    prompt in the agent panel.
    ...    6. OAuth for the services whose packs say `kind = "oauth"` and that need it (a loopback redirect
    ...    from the editor). API keys come first; many services take either.
    [Tags]    doc
    Skip    prose

Open questions
    [Documentation]    - Do some services belong to the project rather than the person (a team's shared key)? If so, the
    ...    store needs a project scope, still outside the project's files.
    ...    - Which calls count as reads when a pack does not say? The method is a start; some POSTs only read.
    ...    - Spending: does a connection carry a budget (a cap on calls or cost per run), and is hitting it a
    ...    finding?
    [Tags]    doc
    Skip    prose
