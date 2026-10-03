# MockSOLO — design spec

Date: 2026-10-03
Source: Sutter SOLO Operation Manual Rev. 1.09b (FW v2.55+), `spec/SOLO_OpMan.pdf`

## Purpose

A Julia package that impersonates a Sutter **SOLO-50** single-axis micromanipulator
on a virtual serial port, so any host software (Python/pyserial, LabVIEW, …) can be tested without hardware. Julia test code that
owns the mock can additionally simulate a human at the front panel and inspect a
log of all serial traffic.

### Success criteria

- An external program opening `portname(dev)` and speaking the manual's chapter-4
  protocol gets byte-exact replies with realistic (optionally sped-up) timing.
- Front-panel actions performed from Julia are visible to the host via `c`.
- Every byte in/out is recorded with a timestamp.

### Out of scope

- Windows (no POSIX pty; would need com0com).
- libserialport-based hosts and DTR/RTS control (a pty has no modem-control lines).
- SOLO-25 / MP-285 devices, DIP-switch configuration (fixed: SOLO/M, 50 mm,
  calibration homing enabled).
- Fault injection (silence, garbage, dropped CR).
- Baud-rate enforcement (a pty has none; 57600 8N1 is accepted implicitly).

## Device constants

| Constant | Value |
|---|---|
| µsteps → µm | 0.09375 |
| µm → µsteps | 10.66666666667, result `round`ed to integer |
| Range | 0 – 533,334 µsteps (0 – 50,000 µm) |
| Speed | 3000 µm/s, all moves |
| Startup position | 1000 µm = 10,667 µsteps |
| Default home / work | 10,667 µsteps each |
| Pulse step | 2.85 µm → 30 µsteps |

## Serial protocol

No terminators; every command finishes with a single CR (0x0D) sent when its action
completes. Multi-byte integers are **least-significant byte first**.

| Cmd | Tx bytes | Behavior | Rx |
|---|---|---|---|
| `c` / `C` | 1 | read current position | u32 position + CR |
| `h` | 1 | move to stored home | CR after move |
| `w` | 1 | move to stored work | CR after move |
| `H` | 1 + u32 | store target as home, move there | CR after move |
| `W` | 1 + u32 | store target as work, move there | CR after move |
| `x` / `X` | 1 + u32 | move to target | CR after move |
| `v` | 1 + u16 | accepted, **no effect** (SOLO-50 has one speed) | CR |

Rules:

1. Targets above 533,334 are **clamped** to 533,334; the move proceeds and CR is sent.
2. Commands are processed strictly in order. Bytes arriving while a serial move runs
   are queued and handled after that move's CR (so a mid-move `c` is answered only
   after the move ends).
3. An unknown command byte is discarded with no reply (still in the traffic log).
4. A partial frame waits indefinitely for its remaining bytes; no inter-byte timeout.
5. A serial move issued while a front-panel move is running or paused **takes over**
   from the current position and clears the pause.

## Kinematics and time

- All moves are linear at 3000 µm/s. Position is computed lazily from the active move
  (`from`, `to`, start time) and the clock; there is no tick loop.
- `timescale` (default `1.0`) divides real durations: a move of `d` µm takes
  `d / 3000 / timescale` wall seconds. `timescale = Inf` makes moves instant.
- The device reads time through an injectable `clock` function (default `time`),
  so unit tests can drive a fake clock.
- Pausing freezes the position; resuming starts a new move segment from it to the
  same target.
- After the server has slept through a serial move it snaps the position to the
  target, so a `c` sent right after the CR reads the target exactly despite timer jitter.

## Front panel (Julia API)

State is either **idle** or **in a move** (running or paused). A move has a kind:
`:serial`, `:home`, `:work`, or `:pulse`.

| Function | Idle | During a move (running or paused) |
|---|---|---|
| `press_home!` | start home move | if kind `:home`: toggle pause; else ignored |
| `press_work!` | start work move | if kind `:work`: toggle pause; else ignored |
| `hold_home!` / `hold_work!` | store current position as home / work | ignored |
| `pulse!` | +30 µsteps move (clamped) | ignored |
| `turn_knob!(dev, Δum)` | instant jump by `Δum` µm, clamped to range | ignored |
| `press_relative!` | toggle relative display mode | ignored |
| `hold_relative!` | relative origin := current position | ignored |
| `press_speed!` | cycle knob speed 0→1→2→3→0 (stored only) | ignored |

The front panel never affects the serial protocol's coordinates (always absolute).

## Screen

`screen(dev)` returns `(absolute_um, relative_um, color)`:

- `absolute_um = round(Int, pos * 0.09375)`
- `relative_um = round(Int, (pos - rel_origin) * 0.09375)` (may be negative; origin 0 at startup)
- `color`: `:red` while in a move (running or paused), else `:blue` in relative mode,
  else `:green`.

## Architecture

```
src/MockSOLO.jl   module, exports, start/stop/wait
src/device.jl     pure model: constants, state + lock, lazy kinematics,
                  front-panel ops, byte-stream frame parser, screen
src/serial.jl     openpty + raw termios via ccall, server task, traffic log
test/runtests.jl  unit tests (fake clock) + pty integration tests
README.md         usage, incl. standalone one-liner
```

Data flow: pty master → server task reads bytes → appended to traffic log (`:in`) →
parser emits complete commands → device executes (moves get a duration) → server
sleeps the scaled duration → writes reply + CR → traffic log (`:out`).

### pty details

- `openpty` (libc on macOS; libutil/libc on Linux), then `cfmakeraw` + `tcsetattr`
  on the slave so hosts that don't configure the port still get raw bytes. The termios
  struct is passed as an oversized byte buffer to avoid per-platform layouts.
- The mock keeps its own slave fd open for its lifetime, so hosts can open/close the
  port repeatedly without the master seeing a hangup.
- The master fd must be read without blocking the Julia thread (libuv-backed handle),
  so a single-threaded test can talk to the port and the server at once.
  **Risk:** verify this first with a throwaway spike; fallback is a dedicated thread.

## Public API

```julia
dev = MockSOLO.start(; timescale = 1.0)  # -> MockSOLO50
portname(dev)          # "/dev/ttysNNN"
position_usteps(dev)   # UInt32, live
screen(dev)            # (absolute_um, relative_um, color)
press_home!(dev); hold_home!(dev); press_work!(dev); hold_work!(dev)
pulse!(dev); press_relative!(dev); hold_relative!(dev); press_speed!(dev)
turn_knob!(dev, Δum)
traffic(dev)           # Vector{@NamedTuple{t::Float64, dir::Symbol, bytes::Vector{UInt8}}}
stop(dev)              # close pty, end server task
wait(dev)              # block until stopped
```

`traffic` entries: `t` = seconds since `start`, `dir` ∈ `:in` (host→mock), `:out`
(mock→host); one entry per read chunk / per reply.

Standalone use (e.g. pytest harness), documented in README:

```
julia --project -e 'using MockSOLO; d = MockSOLO.start(); println(portname(d)); flush(stdout); wait(d)'
```

## Error handling

- `start` on Windows: error explaining a POSIX pty is required.
- `openpty` / termios failures: `SystemError` via `systemerror`.
- Server task exception: logged with `@error`, rethrown from `stop` / `wait`.
- Front-panel calls, `position_usteps` and `screen` after `stop`: error.
  `traffic` and `portname` stay readable for post-mortems.

## Testing

Dependencies: `Test` stdlib only.

Unit (fake clock, no pty):
- parser framing: frames split across chunks, unknown bytes dropped, `v` consumes 2 bytes
- LSB-first encode/decode of u32
- mid-move interpolated position; clamping; `H`/`W` store home/work
- pause/resume of home and work moves; non-matching buttons ignored during moves
- serial takeover of running and paused front-panel moves
- pulse = 30 µsteps; knob jump + clamp; hold_* store; relative origin; screen colors
- speed button cycles 0–3

Integration (real pty, host side opened from Julia):
- `c` returns 4 bytes + CR with correct byte order
- each move command returns CR and `c` afterwards reports the target
- `timescale = 10`: CR for a 5000 µm move arrives after ≈ 0.167 s (with tolerance)
- command sent during a move is answered after the move's CR
- host close + reopen still works
- traffic log matches the bytes exchanged
