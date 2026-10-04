# SOLO-50 device model: constants, wire codec, frame parser, kinematics, serial
# command execution and front panel. No I/O in this file.

const USTEP_UM = 0.09375           # µm per µstep (manual Table 4-2)
const UM_USTEP = 10.66666666667    # µsteps per µm
const MAX_USTEPS = 533_334         # SOLO-50 end of travel (Table 4-3)
const SPEED_UM_S = 3000.0          # the only speed; 'v' has no effect on SOLO-50
const STARTUP_USTEPS = 10_667      # 1000 µm, after calibration homing
const PULSE_USTEPS = 30            # 2.8125 µm (manual: nominal 2.85 µm)
const CR = 0x0d

um2us(um::Real) = round(Int, um * UM_USTEP)
clamp_us(x::Integer) = clamp(Int(x), 0, MAX_USTEPS)

# Multi-byte integers on the wire are least-significant byte first.
encode_u32(x::Integer) = UInt8[(x >> (8i)) & 0xff for i in 0:3]
decode_u32(b) = UInt32(b[1]) | UInt32(b[2]) << 8 | UInt32(b[3]) << 16 | UInt32(b[4]) << 24

# Frame length per command byte; any other byte is unknown and dropped.
const FRAME_LEN = Dict{UInt8,Int}(
    UInt8('c') => 1, UInt8('C') => 1, UInt8('h') => 1, UInt8('w') => 1,
    UInt8('H') => 5, UInt8('W') => 5, UInt8('x') => 5, UInt8('X') => 5,
    UInt8('v') => 3,
)

"""
    parse!(buf) -> Vector{Tuple{UInt8,UInt32}}

Consume every complete frame from the front of `buf` and return `(cmd, arg)` pairs.
Unknown command bytes are dropped; a trailing partial frame stays in `buf`.
"""
function parse!(buf::Vector{UInt8})
    cmds = Tuple{UInt8,UInt32}[]
    while !isempty(buf)
        n = get(FRAME_LEN, buf[1], 0)
        if n == 0
            popfirst!(buf)
            continue
        end
        length(buf) < n && break
        arg = n == 5 ? decode_u32(@view buf[2:5]) :
              n == 3 ? UInt32(buf[2]) | UInt32(buf[3]) << 8 : UInt32(0)
        push!(cmds, (buf[1], arg))
        deleteat!(buf, 1:n)
    end
    return cmds
end

# One straight-line move segment. Position is computed from it lazily; there is
# no tick loop. `kind` is :idle, :serial, :home, :work, :pulse or :knob.
struct Move
    kind::Symbol
    from::Int
    to::Int
    t0::Float64    # clock time the segment started
end

mutable struct SOLO50{C}
    const lock::ReentrantLock
    const clock::C
    const timescale::Float64
    move::Move
    paused::Bool   # when true, position is frozen at move.from
    home::Int
    work::Int
    rel_origin::Int
    relative::Bool
    knob_speed::Int
end

function SOLO50(; timescale::Real = 1.0, clock = time)
    timescale > 0 || throw(ArgumentError("timescale must be > 0, got $timescale"))
    p = STARTUP_USTEPS
    return SOLO50(ReentrantLock(), clock, Float64(timescale), Move(:idle, p, p, clock()),
                  false, p, p, 0, false, 0)
end

# Wall seconds a segment takes; an Inf timescale makes it 0.
duration(d::SOLO50, m::Move) = abs(m.to - m.from) * USTEP_UM / SPEED_UM_S / d.timescale

function pos_at(d::SOLO50, t)
    m = d.move
    d.paused && return m.from
    dur = duration(d, m)
    f = dur == 0 ? 1.0 : clamp((t - m.t0) / dur, 0.0, 1.0)
    return m.from + round(Int, (m.to - m.from) * f)
end

busy(d::SOLO50, t) = d.paused || t < d.move.t0 + duration(d, d.move)

function start_move!(d::SOLO50, kind::Symbol, target::Integer, t)
    d.move = Move(kind, pos_at(d, t), clamp_us(target), t)
    d.paused = false
    return duration(d, d.move)
end

"""
    execute!(d, cmd, arg) -> (reply, wait)

Run one parsed serial command. The caller sends `reply` after `wait` seconds.
Move commands take over any front-panel move, running or paused.
"""
function execute!(d::SOLO50, cmd::UInt8, arg::UInt32)
    lock(d.lock) do
        t = d.clock()
        c = Char(cmd)
        if c in ('c', 'C')
            return [encode_u32(pos_at(d, t)); CR], 0.0
        elseif c == 'h'
            return [CR], start_move!(d, :serial, d.home, t)
        elseif c == 'w'
            return [CR], start_move!(d, :serial, d.work, t)
        elseif c == 'H'
            d.home = clamp_us(arg)
            return [CR], start_move!(d, :serial, d.home, t)
        elseif c == 'W'
            d.work = clamp_us(arg)
            return [CR], start_move!(d, :serial, d.work, t)
        elseif c in ('x', 'X')
            return [CR], start_move!(d, :serial, arg, t)
        else # 'v': accepted, no effect on SOLO-50
            return [CR], 0.0
        end
    end
end

# Called once the server has slept through a serial move: snap to the target so a
# 'c' right after the CR reads it exactly despite timer jitter. Safe because the
# front panel cannot change a running serial move.
function settle!(d::SOLO50)
    lock(d.lock) do
        m = d.move
        m.kind === :serial && (d.move = Move(:serial, m.to, m.to, d.clock()))
        return nothing
    end
end

"""
    position_usteps(dev) -> UInt32

Current position in µsteps (0.09375 µm each), interpolated live while a move runs.
"""
position_usteps(d::SOLO50) = lock(() -> UInt32(pos_at(d, d.clock())), d.lock)

# Front panel. While a move runs or is paused every input is ignored, except the
# button that started a HOME/WORK move, which toggles its pause.

function toggle_pause!(d::SOLO50, t)
    m = d.move
    if d.paused
        d.move = Move(m.kind, m.from, m.to, t)
        d.paused = false
    else
        d.move = Move(m.kind, pos_at(d, t), m.to, t)
        d.paused = true
    end
    return nothing
end

function press_move_button!(d::SOLO50, kind::Symbol)
    lock(d.lock) do
        t = d.clock()
        if !busy(d, t)
            start_move!(d, kind, kind === :home ? d.home : d.work, t)
        elseif d.move.kind === kind
            toggle_pause!(d, t)
        end
        return nothing
    end
end

"""
    press_home!(dev)

Press HOME. When idle, start moving to the stored home position. During a HOME move,
toggle pause/resume. Ignored during any other move.
"""
press_home!(d::SOLO50) = press_move_button!(d, :home)

"""
    press_work!(dev)

Press WORK. When idle, start moving to the stored work position. During a WORK move,
toggle pause/resume. Ignored during any other move.
"""
press_work!(d::SOLO50) = press_move_button!(d, :work)

# Run `f(t)` under the lock only if the device is idle.
function when_idle(f, d::SOLO50)
    lock(d.lock) do
        t = d.clock()
        busy(d, t) || f(t)
        return nothing
    end
end

"""
    hold_home!(dev)

Hold HOME: store the current position as home. Ignored during a move.
"""
hold_home!(d::SOLO50) = when_idle(t -> d.home = pos_at(d, t), d)

"""
    hold_work!(dev)

Hold WORK: store the current position as work. Ignored during a move.
"""
hold_work!(d::SOLO50) = when_idle(t -> d.work = pos_at(d, t), d)

"""
    hold_relative!(dev)

Hold RELATIVE: zero the relative display at the current position. Ignored during a
move.
"""
hold_relative!(d::SOLO50) = when_idle(t -> d.rel_origin = pos_at(d, t), d)

"""
    press_relative!(dev)

Press RELATIVE: toggle the screen between absolute (green) and relative (blue) mode.
Display only; serial coordinates stay absolute. Ignored during a move.
"""
press_relative!(d::SOLO50) = when_idle(_ -> d.relative = !d.relative, d)

"""
    press_speed!(dev)

Press SPEED: cycle the stored knob speed 0 → 1 → 2 → 3 → 0. Stored only; it does not
change `turn_knob!`. Ignored during a move.
"""
press_speed!(d::SOLO50) = when_idle(_ -> d.knob_speed = mod(d.knob_speed + 1, 4), d)

"""
    pulse!(dev)

Press PULSE: move +30 µsteps (2.8125 µm), clamped to the end of travel. Ignored during
a move.
"""
pulse!(d::SOLO50) =
    when_idle(t -> start_move!(d, :pulse, pos_at(d, t) + PULSE_USTEPS, t), d)

"""
    turn_knob!(dev, Δum)

Turn the knob: jump instantly by `Δum` µm (rounded to µsteps, clamped to 0–50,000 µm).
Ignored during a move.
"""
function turn_knob!(d::SOLO50, Δum::Real)
    when_idle(d) do t
        p = clamp_us(pos_at(d, t) + um2us(Δum))
        d.move = Move(:knob, p, p, t)
    end
end

"""
    screen(dev) -> (absolute_um, relative_um, color)

What the controller's screen shows: absolute and relative position in whole µm and the
color, which is `:red` during a move (running or paused), otherwise `:blue` in relative
mode or `:green`.
"""
function screen(d::SOLO50)
    lock(d.lock) do
        t = d.clock()
        p = pos_at(d, t)
        color = busy(d, t) ? :red : d.relative ? :blue : :green
        return (absolute_um = round(Int, p * USTEP_UM),
                relative_um = round(Int, (p - d.rel_origin) * USTEP_UM),
                color = color)
    end
end
