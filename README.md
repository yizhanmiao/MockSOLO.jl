# MockSOLO

[![Docs: dev](https://img.shields.io/badge/docs-dev-blue.svg)](https://yizhanmiao.github.io/MockSOLO.jl/dev/)

A mock **Sutter SOLO-50** micromanipulator for testing host software without
hardware. It serves the SOLO's USB/serial protocol (Operation Manual Rev. 1.09b,
chapter 4) on a virtual serial port (POSIX pty), so anything that can open a COM
port — pyserial, LabVIEW — can talk to it. From Julia you can also
press the front-panel buttons and read a log of every byte exchanged.

macOS and Linux only.

> **AI disclosure:** Most of this package was written by Claude (Anthropic's AI model)
> using Claude Code: the code, tests and documentation. The author directed and
> reviewed the work. Treat it as you would any young, lightly tested package.

## Quick start (Julia)

```julia
using MockSOLO
dev = MockSOLO.start(timescale = 100)   # moves run 100× faster; Inf = instant
portname(dev)                           # e.g. "/dev/ttys004" — give this to the host
host = open_port(portname(dev))         # host side, in the same process
write(host, UInt8('c')); read(host, 5)  # position reply: 4 bytes LSB first + CR
press_home!(dev)                        # simulate a person at the controller
position_usteps(dev)                    # live position in microsteps
screen(dev)                             # (absolute_um = …, relative_um = …, color = …)
traffic(dev)                            # [(t, dir = :in/:out, bytes), …]
stop(dev)
```

In the same process, open the host side with `open_port`; blocking I/O (`open`,
IOStream, ccall reads) starves the mock's tasks and hangs.

Front panel: `press_home!`, `hold_home!`, `press_work!`, `hold_work!`, `pulse!`,
`press_relative!`, `hold_relative!`, `press_speed!`, `turn_knob!(dev, Δum)`.

## Standalone (e.g. pytest)

```sh
julia --project=/path/to/MockSOLO -e 'using MockSOLO; d = MockSOLO.start(); println(portname(d)); flush(stdout); wait(d)'
```

prints the port path, then serves until killed.

```python
import subprocess, serial

proc = subprocess.Popen(
    ["julia", "--project=/path/to/MockSOLO", "-e",
     "using MockSOLO; d = MockSOLO.start(timescale=100); "
     "println(portname(d)); flush(stdout); wait(d)"],
    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
port = proc.stdout.readline().strip()
s = serial.Serial(port, 57600, timeout=5)
s.reset_input_buffer()
s.write(b"c")
# reply is 4 position bytes (LSB first) + CR
pos = int.from_bytes(s.read(5)[:4], "little")   # 10667 µsteps = 1000 µm
s.close()
proc.terminate()
```

## Behavior where the manual is silent

| Situation | Mock behavior |
|---|---|
| Byte order of u32/u16 | least-significant byte first |
| `v` (set velocity) | accepted, no effect — SOLO-50 has one speed (3000 µm/s) |
| Target > 533,334 µsteps | clamped to 533,334 |
| `H` / `W` | store the target as home / work, then move there |
| Bytes sent during a move | queued, answered after the move's CR |
| Unknown command byte | dropped silently |
| Serial move during a front-panel move | takes over from the current position |
| Front panel during any move | ignored, except HOME/WORK pausing their own move |
| Startup / default home / default work | 1000 µm (10,667 µsteps) |

## Limitations

- The mock holds the port open between host sessions, so replies a host never read
  are still queued when the next host opens the port. Purge the input buffer after
  opening (as manual §4.2 note 3 recommends).
- Baud rate and framing are not enforced (a pty has none).
- No modem-control lines: libserialport-based hosts (e.g. LibSerialPort.jl) fail to
  open the port, and setting DTR/RTS (TIOCM* ioctls) raises ENOTTY (with pyserial,
  don't touch `.dtr`/`.rts`).
- Windows is not supported (would need com0com).

## Documentation

Online: https://yizhanmiao.github.io/MockSOLO.jl/dev/

Build and browse the docs locally (from the repo root):

```sh
julia --project=docs -e 'using Pkg; Pkg.instantiate()'   # once
julia --project=docs docs/make.jl                        # build into docs/build/
julia --project=docs -e 'using LiveServer; servedocs()'  # live-reload server; prints its URL
```
