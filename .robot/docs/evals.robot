*** Settings ***
Documentation    Moonsplice renderer eval
...
...    Public visual suite for the headless renderer. The compositions are original
...    fixtures. The media they decode is from Wikimedia Commons (NASA public domain
...    video/image/audio, CC SVGs) and an Apache-2.0 Lottie sample. This is not
...    product-demo content from other projects.
...
...    ```bash
...    cd moonsplice
...    moonsplice eval --open
...    ```
...
...    That command:
...
...    1. Fetches missing files listed in `.robot/eval/assets.json`
...    2. Renders every case in `.robot/eval/manifest.json` through the headless renderer
...    3. Overwrites `evals/out/eval.html` with every passing MP4 inlined as a data URI
...
...    | path | purpose |
...    |---|---|
...    | `comps/cases/` | original compositions covering primitives, type, compositing, decode, encode |
...    | `.robot/eval/assets.json` | URLs, licenses, and credits for downloaded media |
...    | `comps/assets/` | local copies (fetched on demand) |
...    | `evals/out/` | render artifacts + `eval.html`; gitignored |
...
...    Media cases cover WebM video, JPEG, SVG, Lottie, and Ogg audio mix. Geometry
...    cases cover shapes, eases, kinetic type, blend modes, clip masks, vector,
...    effects, HTML fragments, HTML pages (linked CSS/images/woff2), script-baked
...    pages, flex, exploded UI perspective, focus-pull perspective, a shared plane
...    camera, and a glTF world layer.
Metadata    Source    cadence@56ddad1:evals/README.md

*** Test Cases ***
Public media used by the Moonsplice renderer eval
    [Documentation]    Downloaded on demand from `.robot/eval/assets.json`. These are not Moonsplice product
    ...    demos; they exist so the public renderer can be tested against real decode and
    ...    encode paths.
    ...
    ...    | file | source | license | credit |
    ...    |---|---|---|---|
    ...    | `earth_night.webm` | [Wikimedia: Animation of Rotating Earth at Night](https://commons.wikimedia.org/wiki/File:Animation_of_Rotating_Earth_at_Night.webm) | Public domain (NASA) | NASA / Suomi NPP |
    ...    | `galileo.webm` | [Wikimedia: Earth rotation during Galileo flyby](https://commons.wikimedia.org/wiki/File:Earth_rotation_during_Galileo_flyby_(ap070514).webm) | Public domain (NASA/JPL) | NASA/JPL / Doug Ellison |
    ...    | `apollo17.jpg` | [Wikimedia: The Earth seen from Apollo 17](https://commons.wikimedia.org/wiki/File:The_Earth_seen_from_Apollo_17.jpg) (1280px thumb) | Public domain (NASA) | NASA / Apollo 17 crew |
    ...    | `nasa_worm.svg` | [Wikimedia: NASA Worm logo](https://commons.wikimedia.org/wiki/File:NASA_Worm_logo.svg) | Public domain (NASA) | Danne & Blackburn for NASA |
    ...    | `compass.svg` | [Wikimedia: Simple compass rose](https://commons.wikimedia.org/wiki/File:Simple_compass_rose.svg) | CC BY 3.0 | Brosen / Howcheng |
    ...    | `helium_atom.svg` | [Wikimedia: Helium atom (not to scale)](https://commons.wikimedia.org/wiki/File:Helium_atom_(not_to_scale).svg) | CC BY-SA 3.0 | Wikimedia Commons contributors |
    ...    | `piano.ogg` | [Wikimedia: Pleasant Moments Piano Roll](https://commons.wikimedia.org/wiki/File:Pleasant_Moments_Piano_Roll.ogg) | Public domain | Scott Joplin |
    ...    | `android_wave.json` | [Airbnb lottie-android sample](https://github.com/airbnb/lottie-android) | Apache-2.0 | AndroidWave.json |
    ...    | `fonts/Roboto-*.ttf` | [googlefonts/roboto-2](https://github.com/googlefonts/roboto-2) | Apache-2.0 | Christian Robertson |
    ...    | `fonts/JetBrainsMono-Regular.ttf` | [JetBrains Mono](https://github.com/JetBrains/JetBrainsMono) | OFL-1.1 | JetBrains |
    ...    | `fonts/PlayfairDisplay.ttf` | [google/fonts Playfair](https://github.com/google/fonts/tree/main/ofl/playfairdisplay) | OFL-1.1 | Claus Eggers Sørensen |
    ...    | `fonts/Fraunces.ttf` | [google/fonts Fraunces](https://github.com/google/fonts/tree/main/ofl/fraunces) | OFL-1.1 | Undercase Type |
    ...
    ...    `chart.svg` is an original synthetic fixture, not third-party media.
    ...    `walk.png` / `walk.json` are original Aseprite-format fixtures for the spritesheet eval (not third-party media).
    [Tags]    doc    source:cadence@56ddad1:evals/SOURCES.md
    Skip    prose

