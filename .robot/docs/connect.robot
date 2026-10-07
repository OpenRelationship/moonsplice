*** Settings ***
Documentation    Connecting other people's APIs
...
...    The agent should be able to use any service in connectory (submodules/connectory: 853 services, and
...    for those whose makers publish an API, every call it accepts, one Lua file per API) the moment a
...    piece needs it: a chart from a spreadsheet, captions from a speech service, footage from a stock
...    library, a post to a channel when the render is done. Connecting a service should take the person
...    one step, asked for at the moment it is needed, and the agent must never see the secret.
...
...    Built 2026-10-07 (owner's goal): connectory's port (lua/connect.lua, lua/http.lua, its card lua/library.md),
...    Tablua's connect tool (core/studio/connect.lua, schema 27), Moonsplice's host (core/connect/), the command
...    line (./moonsplice connect, ./moonsplice studio) and the editor's sheet (editor/src/connect/,
...    src-tauri/src/connections.rs). suites/connect runs it end to end. Where this page says plan, it says so.
Metadata    Status    built; multiple accounts per service, OAuth and spending are not

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
    ...    - **macOS:** the login Keychain, service `moonsplice`, account the field's name (`ELEVENLABS_API_KEY`;
    ...    one account per service for now). Both the editor and the command line write through `security -i`,
    ...    the value on its stdin and never an argument, so the item trusts `security` and the command line,
    ...    which signs every call, reads it with `security find-generic-password` and no prompt.
    ...    `MOONSPLICE_KEYCHAIN` names a keychain file instead (the tests use a throwaway one). Other platforms
    ...    are a plan: their own keychain (Secret Service, Windows Credential Manager) behind the same names.
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
    ...    - In Moonsplice's state (`~/.moonsplice/connect.json`, or `$MOONSPLICE_STATE`): `ask` (kind, service,
    ...    the call, the fields' names and labels, the docs, why, open or settled), `approval` (service, call,
    ...    once, always or deny, when, and when a once was used) and `connection` (service, field names, when).
    ...    - In the run's Tablua file: `tablua_connect` (each call a step made: service, op, method, status,
    ...    seconds, outcome) and `tablua_ask` (what the step asked the person for, and what they were told).
    ...
    ...    The agent reads these like any other rows, so "is Stripe connected?" is a query, not a question. A
    ...    connection's check result is not a row yet; `--record` returns it.
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
    ...    or deny. The editor shows it as a sheet; the command line asks at the terminal, and a driving agent gets
    ...    "waiting" with the command a person runs to answer. The terminal check keeps an agent from approving
    ...    its own call on the default path; the editor answers with `--approve ... --from-app`, which an agent
    ...    with a shell could also reach, so it is a guard, not a boundary (an open question below). Saved
    ...    answers are `approval` rows.
    [Tags]    doc
    Skip    prose

The command line
    [Documentation]    ```
    ...    ./moonsplice connect SERVICE \ \ connect: asks for each missing field, a secret without echo
    ...    ./moonsplice connect --list | --asks \ \ connections, and what agents wait on the person for
    ...    ./moonsplice connect --find WORDS | --calls SERVICE | --needs SERVICE \ \ the directory
    ...    ./moonsplice connect --check SERVICE \ \ \ \ \ \ \ \ \ \ \ the directory's test call
    ...    ./moonsplice connect --approve SERVICE OP [--once|--always|--deny]
    ...    ./moonsplice connect --call OP [ARGS.json] \ \ \ \ \ \ \ \ one call, for an agent driving the command line
    ...    ./moonsplice connect --forget SERVICE
    ...    ./moonsplice studio --comp COMP --ask TEXT \ \ a Tablua run with connect; its JSON line lists the asks
    ...    ```
    ...
    ...    When stdin is not a terminal (an agent is driving), `connect SERVICE` and `--approve` do not read
    ...    from it: they print the command for the person to run and exit 3. `--call` exits 4 while it waits on
    ...    the person, with what they must do. A secret is never piped through an agent.
    [Tags]    doc
    Skip    prose

What is not built yet
    [Documentation]    - More than one account per service (work and personal): one keychain item per field name today.
    ...    - OAuth for the services that need it (a loopback redirect from the editor); API keys work now.
    ...    - Other platforms' keychains.
    ...    - The editor's own agent: it still waits on its move from malleable to Tablua (port/done.robot), so in
    ...    the app the sheet answers asks raised by a run from the command line (`./moonsplice studio`) or any
    ...    other agent using `./moonsplice connect`.
    [Tags]    doc
    Skip    prose

Open questions
    [Documentation]    - Do some services belong to the project rather than the person (a team's shared key)? If so, the
    ...    store needs a project scope, still outside the project's files.
    ...    - Which calls count as reads when a pack does not say? The method is a start; some POSTs only read.
    ...    - Spending: does a connection carry a budget (a cap on calls or cost per run), and is hitting it a
    ...    finding?
    ...    - An approval only the person can give: the app's answer goes through a path an agent with a shell
    ...    could also take. A keychain-guarded or app-signed approval would make it a boundary.
    [Tags]    doc
    Skip    prose
