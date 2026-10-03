# SOLO-50 device model: constants, wire codec, frame parser, kinematics, serial
# command execution and front panel. No I/O in this file.

const USTEP_UM = 0.09375           # µm per µstep (manual Table 4-2)
const UM_USTEP = 10.66666666667    # µsteps per µm
const MAX_USTEPS = 533_334         # SOLO-50 end of travel (Table 4-3)
const SPEED_UM_S = 3000.0          # the only speed; 'v' has no effect on SOLO-50
const STARTUP_USTEPS = 10_667      # 1000 µm, after calibration homing
const PULSE_USTEPS = 30            # 2.85 µm
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
