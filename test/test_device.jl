using MockSOLO: encode_u32, decode_u32, parse!, um2us, SOLO50, execute!, settle!, MAX_USTEPS, STARTUP_USTEPS, position_usteps

@testset "wire codec" begin
    @test encode_u32(10_667) == UInt8[0xab, 0x29, 0x00, 0x00]
    @test decode_u32(UInt8[0xab, 0x29, 0x00, 0x00]) === 0x000029ab
    @test decode_u32(encode_u32(0xffffffff)) === 0xffffffff
    @test um2us(1000) == 10_667
    @test um2us(2.85) == 30
end

@testset "frame parser" begin
    buf = UInt8[UInt8('x'), 0x01, 0x02]
    @test isempty(parse!(buf))                 # partial frame waits for more bytes
    @test length(buf) == 3
    append!(buf, [0x03, 0x04, UInt8('c')])
    @test parse!(buf) == [(UInt8('x'), 0x04030201), (UInt8('c'), UInt32(0))]
    @test isempty(buf)

    # unknown bytes dropped; 'v' consumes two argument bytes
    buf = UInt8[0x00, 0xff, UInt8('C'), UInt8('v'), 0x34, 0x12, UInt8('h')]
    @test parse!(buf) == [(UInt8('C'), UInt32(0)), (UInt8('v'), UInt32(0x1234)),
                          (UInt8('h'), UInt32(0))]

    buf = UInt8[UInt8('v'), 0x01]
    @test isempty(parse!(buf))
    @test buf == UInt8[UInt8('v'), 0x01]

    buf = UInt8[UInt8(c) for c in "hwHWxX"]   # H/W/x/X are 5-byte frames
    @test parse!(buf) == [(UInt8('h'), UInt32(0)), (UInt8('w'), UInt32(0))]
    @test length(buf) == 4
end

# A device driven by a hand-set clock: assign `now[]` to move time forward.
function fake_device(; timescale = 1.0)
    now = Ref(0.0)
    return SOLO50(; clock = () -> now[], timescale), now
end
run!(d, cmd::Char, arg = 0) = execute!(d, UInt8(cmd), UInt32(arg))

@testset "serial commands" begin
    d, now = fake_device()
    @test run!(d, 'c') == (UInt8[0xab, 0x29, 0x00, 0x00, 0x0d], 0.0)
    @test position_usteps(d) === UInt32(STARTUP_USTEPS)

    reply, wait = run!(d, 'x', 42_667)         # 32,000 µsteps = 3000 µm = 1 s
    @test reply == [0x0d]
    @test wait ≈ 1.0
    now[] = 0.5
    @test position_usteps(d) == 26_667          # interpolated mid-move
    now[] = 1.0
    @test position_usteps(d) == 42_667
    @test run!(d, 'C')[1] == [encode_u32(42_667); 0x0d]

    _, wait = run!(d, 'H', 20_000)
    @test d.home == 20_000
    now[] += wait
    @test position_usteps(d) == 20_000
    _, wait = run!(d, 'W', 30_000)
    now[] += wait
    @test d.work == 30_000
    @test position_usteps(d) == 30_000
    _, wait = run!(d, 'h')
    now[] += wait
    @test position_usteps(d) == 20_000
    _, wait = run!(d, 'w')
    now[] += wait
    @test position_usteps(d) == 30_000
    _, wait = run!(d, 'X', 1_000)
    now[] += wait
    @test position_usteps(d) == 1_000

    @test run!(d, 'v', 0x1234) == ([0x0d], 0.0)   # accepted, no effect
    _, wait = run!(d, 'x', 1_000 + 32_000)
    @test wait ≈ 1.0                               # speed unchanged by 'v'
end

@testset "out-of-range target clamps (0xFFFFFFFF)" begin
    d, now = fake_device()
    _, wait = run!(d, 'X', 0xffffffff)
    @test wait ≈ (MAX_USTEPS - STARTUP_USTEPS) * 0.09375 / 3000
    now[] += wait
    @test position_usteps(d) == MAX_USTEPS
    run!(d, 'H', 0xffffffff)
    @test d.home == MAX_USTEPS
    run!(d, 'W', 0xffffffff)
    @test d.work == MAX_USTEPS
    _, wait = run!(d, 'x', 0)
    now[] += wait
    @test position_usteps(d) == 0
end

@testset "timescale and settle!" begin
    d, now = fake_device(timescale = 10)
    _, wait = run!(d, 'x', 42_667)
    @test wait ≈ 0.1
    settle!(d)                      # executor finished sleeping: snap to target
    @test position_usteps(d) == 42_667
    @test run!(SOLO50(timescale = Inf), 'x', MAX_USTEPS)[2] == 0.0
    @test_throws ArgumentError SOLO50(timescale = 0)
    @test_throws ArgumentError SOLO50(timescale = -1)
end
