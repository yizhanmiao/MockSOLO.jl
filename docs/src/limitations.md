# Limitations

- **No modem-control lines.** A pty has no DTR/RTS/CTS/DSR.
  - libserialport-based hosts, including LibSerialPort.jl, fail to open the port
    (ENOTTY).
  - In pyserial, don't set `.dtr` or `.rts`; the underlying ioctls fail.
- **Stale bytes between sessions.** The mock holds the port open while hosts come
  and go, so replies a host never read are delivered to the next host. Purge the
  input buffer after opening, and allow for a late CR from a move the previous
  host left running (see [Host software](@ref)).
- **No baud-rate or framing enforcement.** A pty has neither, so any setting works,
  including a wrong one. The real device needs 57600 8N1.
- **POSIX only.** macOS and Linux. Windows would need a virtual COM-port pair such as
  com0com, which is not supported.
- **Blocking I/O in the same process hangs.** Use [`open_port`](@ref) to open the host
  side from Julia.
- **Unbounded traffic log.** Every exchange is kept in memory for the mock's lifetime,
  which matters only for very long, high-rate runs.
- **Not modelled.** Fault injection (silence, garbage, dropped CR), DIP-switch
  settings, the SOLO-25 and the MP-285.
