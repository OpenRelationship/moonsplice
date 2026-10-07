*** Settings ***
Documentation    Moonsplice examples
...
...    Run examples from the `moonsplice/` root so relative assets resolve consistently:
...
...    ```bash
...    moonsplice render comps/examples/basics/hello.lua -o comps/examples/out/hello.mp4
...    ```
...
...    | directory | purpose |
...    |---|---|
...    | `basics/` | authored API spots (no product footage) |
...    | `clips/` | simple stock-footage compositions |
...    | `demos/` | capture-, font-, or external-service-dependent product demos |
...    | `assets/` | source media shared by the examples |
...    | `out/` | local render output; intentionally ignored |
...
...    `basics/` spots for the newer APIs:
...
...    ```bash
...    moonsplice render comps/examples/basics/palette.lua -o comps/examples/out/palette.mp4
...    moonsplice render comps/examples/basics/chart.lua \ \ -o comps/examples/out/chart.mp4
...    moonsplice render comps/examples/basics/bumper.lua \ -o comps/examples/out/bumper.mp4
...    moonsplice render comps/examples/basics/grade.lua \ \ -o comps/examples/out/grade.mp4
...    moonsplice render comps/examples/basics/captions.lua -o comps/examples/out/captions.mp4
...    moonsplice render comps/examples/basics/pulse.lua \ \ -o comps/examples/out/pulse.mp4
...    moonsplice render comps/examples/basics/onair.lua \ \ -o comps/examples/out/onair.mp4
...    moonsplice render comps/examples/basics/bounce.lua \ -o comps/examples/out/bounce.mp4
...    moonsplice render comps/examples/basics/wave.lua \ \ \ -o comps/examples/out/wave.mp4
...    moonsplice render comps/examples/basics/world3d.lua -o comps/examples/out/world3d.mp4
...    moonsplice render comps/examples/basics/page.lua \ \ \ -o comps/examples/out/page.mp4
...    ```
...
...    `assets/` also contains legacy media retained for reproducibility. It is not a
...    guarantee that every asset is used by a current composition.
...
...    Public renderer testing lives in `evals/`, not here. Run `moonsplice eval --open` from
...    the `moonsplice/` root to fetch Wikimedia/public fixtures, render the suite, and
...    overwrite `evals/out/eval.html`.
Metadata    Source    cadence@56ddad1:examples/README.md

*** Test Cases ***
