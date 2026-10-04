# MockSOLO.jl

A mock **Sutter SOLO-50** single-axis micromanipulator for testing host software
without hardware. MockSOLO serves the SOLO's serial protocol (Operation Manual
Rev. 1.09b, chapter 4) on a virtual serial port (a POSIX pty). Anything that can open
a serial port, such as pyserial, can talk to it as if it were the real controller.

- **Realistic timing.** Moves run at the real 3000 µm/s, and the end-of-move CR arrives
  when the move finishes. Use `timescale` to speed this up in tests.
- **Front panel.** From Julia you can press HOME, WORK, PULSE and the other buttons,
  turn the knob, and read the screen, as a person at the controller would.
- **Traffic log.** Every byte in each direction is recorded with a timestamp.

macOS and Linux only.

## Install

MockSOLO is not registered. Install it from a local clone:

```julia
using Pkg
Pkg.develop(path = "/path/to/MockSOLO")
```

or with `Pkg.add(url = ...)` and the repository URL once it is hosted.

## Quick start

```julia
using MockSOLO

dev = MockSOLO.start(timescale = 100)    # moves run 100× faster; Inf = instant
portname(dev)                            # e.g. "/dev/ttys004", give this to a host

host = open_port(portname(dev))          # host side, in this same process
write(host, UInt8('c'))                  # ask for the position
r = read(host, 5)                        # 4 bytes, least-significant first, then CR
ltoh(only(reinterpret(UInt32, r[1:4])))  # 0x000029ab == 10667 µsteps = 1000 µm

write(host, UInt8('x'), htol(UInt32(20_000)))  # move to 20,000 µsteps
read(host, 1)                            # CR arrives when the move is done
position_usteps(dev)                     # 0x00004e20 == 20000

traffic(dev)                             # every byte exchanged, timestamped
close(host)
stop(dev)
```

!!! warning "Use `open_port` in the same process"
    The mock runs as tasks inside your Julia process. Blocking I/O on the port, such as
    `open(path)`, an `IOStream` or `ccall` reads, stops those tasks from running and
    hangs. External programs can open the port however they like.

## Where next

- [Host software](@ref) covers driving the mock from Python or another program.
- [Protocol](@ref) is the byte-level command reference and what the mock does where
  the manual is silent.
- [Front panel](frontpanel.md) simulates a person at the controller.
- [Limitations](@ref) lists what a pty can't do.
- [API reference](@ref) documents every function.
