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
