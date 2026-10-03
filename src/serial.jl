# Virtual serial port: a POSIX pty whose master side is served by two tasks. The
# reader timestamps incoming bytes into the traffic log; the executor parses and
# runs commands in order, sleeping through moves so later bytes queue up as they
# would on the real device.

const F = Base.Filesystem
const TrafficEntry = @NamedTuple{t::Float64, dir::Symbol, bytes::Vector{UInt8}}

# Wrap an fd in a libuv stream so reads yield to other tasks instead of blocking
# the thread.
function libuv_stream(fd::Cint)
    p = Base.PipeEndpoint()
    # ponytail: Base.open_pipe! is internal (present since Julia 1.0); switch if
    # Julia ever exposes a public fd-wrapping API.
    Base.open_pipe!(p, RawFD(fd))
    return p
end

"""
    open_port(path) -> IO

Open the host side of the pty at `path` as a non-blocking stream. Use this to talk to
the mock from the same Julia process: blocking I/O (`open`, IOStream, ccall reads)
starves the mock's tasks and hangs.
"""
function open_port(path::AbstractString)
    fd = ccall(:open, Cint, (Cstring, Cint), path, F.JL_O_RDWR | F.JL_O_NOCTTY)
    systemerror("open $path", fd < 0)
    return libuv_stream(fd)
end

function open_pty()
    flags = F.JL_O_RDWR | F.JL_O_NOCTTY
    m = ccall(:posix_openpt, Cint, (Cint,), flags)
    systemerror("posix_openpt", m < 0)
    systemerror("grantpt", ccall(:grantpt, Cint, (Cint,), m) != 0)
    systemerror("unlockpt", ccall(:unlockpt, Cint, (Cint,), m) != 0)
    name = unsafe_string(ccall(:ptsname, Cstring, (Cint,), m))
    s = ccall(:open, Cint, (Cstring, Cint), name, flags)
    systemerror("open $name", s < 0)
    # Raw mode on the slave so hosts that never configure the port still get
    # untouched bytes. 512 bytes over-allocates struct termios on every platform.
    tio = zeros(UInt8, 512)
    systemerror("tcgetattr", ccall(:tcgetattr, Cint, (Cint, Ptr{UInt8}), s, tio) != 0)
    ccall(:cfmakeraw, Cvoid, (Ptr{UInt8},), tio)
    TCSANOW = Cint(0)
    systemerror("tcsetattr",
                ccall(:tcsetattr, Cint, (Cint, Cint, Ptr{UInt8}), s, TCSANOW, tio) != 0)
    return m, s, name
end

"""
Handle to a running mock SOLO-50. Create with `MockSOLO.start`; point host software
at `portname(m)`.
"""
mutable struct MockSOLO50
    const dev::SOLO50
    const master::Base.PipeEndpoint
    const slave_fd::Cint     # held open so hosts can close and reopen the port
    const portname::String
    const t0::Float64
    # ponytail: the log grows without bound (~MBs/hour at high poll rates); a cap or
    # opt-out is the upgrade path.
    const log::Vector{TrafficEntry}
    const loglock::ReentrantLock
    const inbox::Channel{Vector{UInt8}}
    stopped::Bool
    reader::Task
    executor::Task
    function MockSOLO50(dev, master, slave_fd, portname)
        return new(dev, master, slave_fd, portname, time(), TrafficEntry[],
                   ReentrantLock(), Channel{Vector{UInt8}}(Inf), false)
    end
end

function record!(m::MockSOLO50, dir::Symbol, bytes::Vector{UInt8})
    lock(m.loglock) do
        push!(m.log, (t = time() - m.t0, dir = dir, bytes = bytes))
    end
    return nothing
end

function read_loop(m::MockSOLO50)
    while true
        bytes = try
            readavailable(m.master)
        catch e
            e isa Base.IOError ? UInt8[] : rethrow()
        end
        isempty(bytes) && break      # master closed by stop()
        record!(m, :in, bytes)
        put!(m.inbox, bytes)
    end
    close(m.inbox)
end

function exec_loop(m::MockSOLO50)
    buf = UInt8[]
    for chunk in m.inbox
        append!(buf, chunk)
        for (cmd, arg) in parse!(buf)
            reply, dt = execute!(m.dev, cmd, arg)
            if dt > 0
                sleep(dt)
                settle!(m.dev)
            end
            isopen(m.master) || return
            try
                write(m.master, reply)
            catch e
                e isa Base.IOError || rethrow()
                return               # stop() closed the port mid-write
            end
            record!(m, :out, reply)
        end
    end
end

# Run a server loop, sending failures through the logger; rethrow so stop/wait see them.
function logged(name, f, m)
    try
        f(m)
    catch e
        @error "MockSOLO $name failed" exception = (e, catch_backtrace())
        rethrow()
    end
end

"""
    MockSOLO.start(; timescale = 1.0) -> MockSOLO50

Open a pty, serve the SOLO-50 serial protocol on it and return the handle. Point
host software at `portname(dev)`. `timescale` speeds moves up (`Inf` = instant).
"""
function start(; timescale::Real = 1.0)
    Sys.iswindows() &&
        error("MockSOLO needs a POSIX pty (macOS/Linux); Windows is not supported")
    dev = SOLO50(; timescale)        # validate before opening any fd
    mfd, sfd, name = open_pty()
    m = MockSOLO50(dev, libuv_stream(mfd), sfd, name)
    m.reader = @async logged("reader", read_loop, m)
    bind(m.inbox, m.reader)          # a failed reader must not strand the executor
    m.executor = @async logged("executor", exec_loop, m)
    return m
end

"""
    stop(m)

Close the port and end the server. Returns promptly even mid-move; calling it again
is a no-op. Rethrows if a server task failed.
"""
function stop(m::MockSOLO50)
    m.stopped && return nothing
    m.stopped = true
    close(m.master)
    ccall(:close, Cint, (Cint,), m.slave_fd)
    wait(m.reader)                                # rethrows if it failed
    istaskfailed(m.executor) && wait(m.executor)  # a sleeping executor exits on its own
    return nothing
end

"""
Block until the server is stopped (or its reader fails). Rethrows if a server task
failed.
"""
function Base.wait(m::MockSOLO50)
    wait(m.reader)
    istaskfailed(m.executor) && wait(m.executor)
    return nothing
end

portname(m::MockSOLO50) = m.portname
traffic(m::MockSOLO50) = lock(() -> copy(m.log), m.loglock)

for f in (:position_usteps, :screen, :press_home!, :hold_home!, :press_work!, :hold_work!,
          :pulse!, :press_relative!, :hold_relative!, :press_speed!, :turn_knob!)
    @eval function $f(m::MockSOLO50, args...)
        m.stopped && error("MockSOLO50 on $(m.portname) is stopped")
        return $f(m.dev, args...)
    end
end
