using MockSOLO: encode_u32, decode_u32, parse!, um2us

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

using MockSOLO: SOLO50, execute!, settle!, MAX_USTEPS, STARTUP_USTEPS, position_usteps,
               screen, press_home!, hold_home!, press_work!, hold_work!, pulse!,
               press_relative!, hold_relative!, press_speed!, turn_knob!

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

@testset "settle! leaves a front-panel move alone" begin
    d, now = fake_device()
    turn_knob!(d, 3000)
    press_home!(d)
    now[] = 0.5
    before = d.move
    settle!(d)
    @test d.move === before
end

@testset "HOME/WORK buttons: move, pause, resume" begin
    d, now = fake_device()
    turn_knob!(d, 3000)                  # 10,667 → 42,667 instantly
    @test position_usteps(d) == 42_667
    press_home!(d)                       # back to 10,667: 32,000 µsteps = 1 s
    now[] = 0.5
    @test position_usteps(d) == 26_667
    @test screen(d).color === :red
    press_work!(d)                       # the other move button is ignored
    @test !d.paused
    press_home!(d)                       # pause
    now[] = 2.0
    @test position_usteps(d) == 26_667
    @test screen(d).color === :red       # paused still counts as a move
    press_home!(d)                       # resume: 16,000 µsteps left = 0.5 s
    now[] = 2.25
    @test position_usteps(d) == 18_667
    now[] = 2.5
    @test position_usteps(d) == 10_667
    @test screen(d).color === :green

    turn_knob!(d, 500)                   # 10,667 + 5,333 = 16,000
    hold_work!(d)
    @test d.work == 16_000
    turn_knob!(d, -500)
    press_work!(d)
    now[] += 1.0
    @test position_usteps(d) == 16_000
end

@testset "front panel ignored during a serial move" begin
    d, now = fake_device()
    run!(d, 'x', 42_667)
    now[] = 0.5
    for f! in (press_home!, press_work!, hold_home!, hold_work!, pulse!,
               press_relative!, hold_relative!, press_speed!)
        f!(d)
    end
    turn_knob!(d, 100)
    @test d.move.kind === :serial
    @test !d.paused
    @test (d.home, d.work, d.rel_origin, d.relative, d.knob_speed) ==
          (STARTUP_USTEPS, STARTUP_USTEPS, 0, false, 0)
    now[] = 1.0
    @test position_usteps(d) == 42_667
end

@testset "serial move takes over a front-panel move" begin
    d, now = fake_device()
    turn_knob!(d, 3000)
    press_home!(d)
    now[] = 0.5
    press_home!(d)                       # paused at 26,667
    _, wait = run!(d, 'x', 0)
    @test !d.paused
    @test d.move.kind === :serial
    @test d.move.from == 26_667
    @test wait ≈ 26_667 * 0.09375 / 3000

    d, now = fake_device()               # a running (unpaused) move too
    turn_knob!(d, 3000)
    press_home!(d)
    now[] = 0.25
    run!(d, 'x', 50_000)
    @test (d.move.from, d.move.to) == (34_667, 50_000)
end

@testset "pulse, knob, hold, relative, speed, screen" begin
    d, now = fake_device()
    @test screen(d) == (absolute_um = 1000, relative_um = 1000, color = :green)
    pulse!(d)
    @test d.move.to == STARTUP_USTEPS + 30
    now[] = 1.0
    hold_home!(d)
    @test d.home == STARTUP_USTEPS + 30
    turn_knob!(d, -5000)                 # clamps at beginning of travel
    @test position_usteps(d) == 0
    turn_knob!(d, 60_000)                # clamps at end of travel
    @test position_usteps(d) == MAX_USTEPS
    pulse!(d)                            # at the limit: stays put
    @test position_usteps(d) == MAX_USTEPS

    turn_knob!(d, -49_000)               # 533,334 − 522,667 = 10,667
    @test screen(d) == (absolute_um = 1000, relative_um = 1000, color = :green)
    turn_knob!(d, 100)                   # 11,734 µsteps
    hold_relative!(d)
    press_relative!(d)
    @test screen(d) == (absolute_um = 1100, relative_um = 0, color = :blue)
    turn_knob!(d, -50)
    @test screen(d).relative_um == -50
    press_relative!(d)
    @test screen(d).color === :green

    for _ in 1:3
        press_speed!(d)
    end
    @test d.knob_speed == 3
    press_speed!(d)
    @test d.knob_speed == 0
end
