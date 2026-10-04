# Protocol

The mock implements the SOLO serial protocol from the Operation Manual (Rev. 1.09b,
chapter 4) for a SOLO-50.

## Commands

| Cmd | Bytes sent | Behavior | Reply |
|---|---|---|---|
| `c` / `C` | 1 | read current position | u32 position + CR |
| `h` | 1 | move to stored home | CR after the move |
| `w` | 1 | move to stored work | CR after the move |
| `H` | 1 + u32 | store target as home, then move there | CR after the move |
| `W` | 1 + u32 | store target as work, then move there | CR after the move |
| `x` / `X` | 1 + u32 | move to target | CR after the move |
| `v` | 1 + u16 | accepted, **no effect** (the SOLO-50 has one speed) | CR |

There are no terminators. Every command finishes with a single CR (`0x0D`), sent when
its action completes. Positions are in µsteps.

## Byte order

Multi-byte integers are **least-significant byte first**. The manual is inconsistent
on this; the mock follows LSB-first throughout.

| Exchange | Bytes (hex) |
|---|---|
| host sends `c` | `63` |
| mock replies 10,667 µsteps (0x29AB) | `AB 29 00 00 0D` |
| host sends `x` to 20,000 µsteps (0x4E20) | `78 20 4E 00 00` |
| mock replies when the move ends | `0D` |

## Timing

All moves are straight-line at 3000 µm/s. A move of `d` µm takes `d / 3000 / timescale`
seconds of wall time, and its CR is sent at the end. `timescale` is set in
`MockSOLO.start(; timescale)`. It must be > 0, and `Inf` makes moves instant.

## Behavior where the manual is silent

| Situation | Mock behavior |
|---|---|
| Target > 533,334 µsteps | clamped to 533,334; the move proceeds and CR is sent |
| Bytes sent during a move | queued, processed in order after the move's CR (a mid-move `c` is answered after the move) |
| Unknown command byte | dropped with no reply (still in the traffic log) |
| Partial frame | waits indefinitely for the remaining bytes |
| `H` / `W` | store the target (clamped) as home / work, then move there |
| Serial move during a front-panel move | takes over from the current position and clears any pause |

## Device constants

| Constant | Value |
|---|---|
| µsteps → µm | 0.09375 |
| µm → µsteps | 10.66666666667, rounded to an integer |
| Range | 0 – 533,334 µsteps (0 – 50,000 µm) |
| Speed | 3000 µm/s for all moves |
| Startup position | 1000 µm = 10,667 µsteps |
| Default home / work | 10,667 µsteps each |
| Pulse step | 30 µsteps = 2.8125 µm (manual: nominal 2.85 µm) |

## Traffic log

[`traffic`](@ref) returns a vector of `(t, dir, bytes)` named tuples, where `t` is
seconds since `start`. `dir` is `:in` for one chunk read from the host and `:out` for
one reply. Unknown bytes appear as `:in` entries with no matching `:out`.
