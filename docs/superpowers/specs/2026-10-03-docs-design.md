# MockSOLO documentation site — design spec

Date: 2026-10-03
Package spec: `docs/superpowers/specs/2026-10-03-mocksolo-design.md`

## Purpose

A Documenter.jl site for MockSOLO, built and served locally now, structured so it can
later be published to GitHub Pages with only additive changes.

Readers: both Julia users and developers of host software (Python, LabVIEW, …) that
talk to the mock over its serial port. Content is guide-first, API reference last.

### Success criteria

- `julia --project=docs docs/make.jl` builds with zero warnings/errors on a fresh clone
  (after `Pkg.instantiate`).
- `julia --project=docs -e 'using LiveServer; servedocs()'` serves the site at
  `http://localhost:8000` and rebuilds on edits.
- Every exported name, plus `MockSOLO.start`, has a docstring rendered on the API page;
  the build fails if one is missing.
- Package tests still pass (111/111); `src/` changes are docstrings only.

### Out of scope

- `deploydocs`, GitHub Actions workflow, `repo=`/source links, docs badge (added when a
  git remote exists).
- Doctests and `@example` blocks (examples open ptys and are timing-dependent).
- Trimming the README (revisit when the site is hosted).
- DocumenterVitepress or custom themes.

## Layout

```
docs/
  Project.toml     [deps] Documenter, LiveServer, MockSOLO
                   [sources] MockSOLO = {path = ".."}
                   [compat] Documenter = "1"
  make.jl          makedocs(...) only
  src/
    index.md       overview, install, quick start (Julia host via open_port)
    hosts.md       driving the mock from other software
    protocol.md    serial protocol and behavior reference
    frontpanel.md  front-panel simulation and screen
    limitations.md known limitations
    api.md         API reference
  superpowers/     (existing design docs; not part of the site)
```

`.gitignore` gains `docs/build/`. `docs/Manifest.toml` is already ignored by the
existing `Manifest.toml` pattern. `[sources]` requires Julia ≥ 1.11 for building the
docs only; the package's own compat (`julia = "1.10"`) is unchanged.

## `make.jl`

```julia
using Documenter, MockSOLO

makedocs(;
    sitename = "MockSOLO.jl",
    modules = [MockSOLO],
    remotes = nothing,          # no git remote yet
    checkdocs = :exports,
    format = Documenter.HTML(; prettyurls = get(ENV, "CI", nothing) == "true"),
    pages = [
        "Home" => "index.md",
        "Host software" => "hosts.md",
        "Protocol" => "protocol.md",
        "Front panel" => "frontpanel.md",
        "Limitations" => "limitations.md",
        "API reference" => "api.md",
    ],
)
```

Default `warnonly = false`: missing docstrings, broken `@ref` links and unlisted
docstrings fail the build.

## Page content

Source of truth for behavior is the package spec and the code; the README supplies
existing prose and recipes to reuse (not copied verbatim where the page needs more).

- **index.md** — one-paragraph pitch (SOLO-50 on a virtual serial port, real-time
  with `timescale`, front panel, traffic log); install via `Pkg.develop(path=…)` /
  `Pkg.add(url=…)`; quick start: `MockSOLO.start`, `open_port`, send `c`, read 5
  bytes, decode, `stop`; warning that a blocking `open()` in the same process hangs;
  links to the other pages.
- **hosts.md** — standalone one-liner with `flush(stdout)`; pytest fixture recipe
  (from README); what a host must do: raw 8N1 bytes, purge stale input after open
  (manual §4.2 note 3), don't touch DTR/RTS; `timescale` advice for tests.
- **protocol.md** — command table (bytes, behavior, reply); LSB-first u32/u16 with a
  worked byte example; CR-on-completion timing and the move-duration formula
  `d / 3000 / timescale` s; strict in-order queueing (mid-move `c` answered after the
  CR); clamping to 533,334; unknown bytes dropped; partial frames wait; `v` accepted
  with no effect; device constants table; `traffic` entry format.
- **frontpanel.md** — front-panel action table (idle vs during a move); pause/resume
  via repeated HOME/WORK; serial takeover; knob and pulse clamping; relative mode and
  origin; `screen` tuple and colors; a short Julia example.
- **limitations.md** — pty has no modem-control lines (LibSerialPort.jl/libserialport
  fail with ENOTTY; pyserial DTR/RTS setters fail); stale bytes; no baud enforcement;
  POSIX only (no Windows); traffic log unbounded.
- **api.md** — `@docs` blocks grouped as: Lifecycle (`MockSOLO.start`, `stop`,
  `Base.wait(::MockSOLO50)`, `MockSOLO50`, `portname`, `open_port`); Inspection
  (`position_usteps`, `screen`, `traffic`); Front panel (`press_home!`, `hold_home!`,
  `press_work!`, `hold_work!`, `pulse!`, `press_relative!`, `hold_relative!`,
  `press_speed!`, `turn_knob!`).

## Docstrings to add

On the existing definitions (device-level functions in `src/device.jl` carry the
front-panel and inspection docstrings; the generic function is shared with the
`MockSOLO50` forwards), written in terms of a `dev::MockSOLO50` argument:

`portname`, `traffic`, `position_usteps`, `screen`, `press_home!`, `hold_home!`,
`press_work!`, `hold_work!`, `pulse!`, `press_relative!`, `hold_relative!`,
`press_speed!`, `turn_knob!`. Existing docstrings stay; each new one is a signature
line plus one to three sentences matching the package spec's behavior.

## README

Add a short "Documentation" section with the build and serve commands.

## Verification

1. `julia --project=docs -e 'using Pkg; Pkg.instantiate()'` then
   `julia --project=docs docs/make.jl` — exits 0, no warnings.
2. Temporarily delete one new docstring → build fails (confirms `checkdocs`), restore.
3. `servedocs()` serves; pages render and the sidebar lists all six pages.
4. `julia --project -e 'using Pkg; Pkg.test()'` — 111/111.
