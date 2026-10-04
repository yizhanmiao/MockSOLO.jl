# Host software

Any program that can open a serial port can drive the mock. Run the mock in its own
Julia process, read the port path it prints, and point your software at that path.

## Standalone mock

```sh
julia --project=/path/to/MockSOLO -e 'using MockSOLO; d = MockSOLO.start(); println(portname(d)); flush(stdout); wait(d)'
```

This prints the port path, for example `/dev/ttys004`, then serves until the process is
killed. The path changes on every start, so read it from stdout rather than
hard-coding it. Add `timescale = 100` inside `start(...)` to speed moves up.

## pytest / pyserial

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
s.write(b"x" + (20000).to_bytes(4, "little"))  # move to 20,000 µsteps
assert s.read(1) == b"\r"                       # CR when the move ends
s.close()
proc.terminate()
```

Wrap the `Popen` … `terminate` pair in a session-scoped fixture so Julia's startup time
is paid once.

## What a host must do

- **Send raw bytes.** Commands have no terminator. Multi-byte arguments are
  least-significant byte first. See [Protocol](@ref).
- **Read the full reply.** `c` replies with 5 bytes; every other command replies with
  a single CR (`0x0D`) when its action completes.
- **Purge input after opening.** The mock keeps the port open between host sessions,
  so replies a previous host never read are still queued. The manual (§4.2 note 3)
  recommends this purge for the real device too.
- **Leave DTR/RTS alone.** A pty has no modem-control lines; see [Limitations](@ref).
- **Pick a timescale.** `timescale = 1` is real time (a 5000 µm move takes 1.67 s).
  For test suites use 100 or more. `Inf` makes moves instant, but then you cannot
  observe a move in progress.

## LabVIEW and others

Any software that opens the port path as a plain serial device at 57600 8N1 should
work. Only Julia and pyserial hosts have been tested.
