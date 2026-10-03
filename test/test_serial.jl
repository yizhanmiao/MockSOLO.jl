using MockSOLO: open_port, encode_u32, decode_u32, um2us, MAX_USTEPS

# Read exactly n bytes, failing after `timeout` s instead of hanging the suite.
function readn(io, n; timeout = 5.0)
    t = @async read(io, n)
    timedwait(() -> istaskdone(t), timeout) === :ok || error("timed out reading $n bytes")
    return fetch(t)
end

frame(cmd::Char, arg) = [UInt8(cmd); encode_u32(arg)]

@testset "pty: protocol over a real port" begin
    dev = MockSOLO.start(timescale = Inf)
    host = open_port(portname(dev))
    sent = UInt8[]
    got = UInt8[]
    send(bytes) = (append!(sent, bytes); write(host, bytes))
    recv(n) = (b = readn(host, n); append!(got, b); b)
    try
        @test startswith(portname(dev), "/dev/")

        send([UInt8('c')])
        @test recv(5) == UInt8[0xab, 0x29, 0x00, 0x00, 0x0d]   # 10,667 LSB first

        for (cmd, target) in (('x', 20_000), ('X', 30_000), ('H', 40_000), ('W', 50_000))
            send(frame(cmd, target))
            @test recv(1) == [0x0d]
            send([UInt8('C')])
            @test decode_u32(recv(5)) == target
        end
        send([UInt8('h')])
        @test recv(1) == [0x0d]
        @test position_usteps(dev) == 40_000
        send([UInt8('w')])
        @test recv(1) == [0x0d]
        @test position_usteps(dev) == 50_000
        send(UInt8[UInt8('v'), 0x34, 0x12])
        @test recv(1) == [0x0d]

        send(UInt8[0x00, UInt8('c')])                 # unknown byte dropped
        @test recv(5)[end] == 0x0d

        send(UInt8[UInt8('c'), UInt8('c')])           # pipelined, no wait for CR
        r = recv(10)
        @test r[5] == 0x0d && r[10] == 0x0d

        send([UInt8('x')])                            # frame split over slow writes
        for b in encode_u32(12_345)
            sleep(0.02)
            send([b])
        end
        @test recv(1) == [0x0d]
        @test position_usteps(dev) == 12_345

        log = traffic(dev)
        @test all(e -> e.dir in (:in, :out), log)
        @test issorted([e.t for e in log])
        @test reduce(vcat, [e.bytes for e in log if e.dir === :in]) == sent
        @test reduce(vcat, [e.bytes for e in log if e.dir === :out]) == got

        close(host)                                   # host closes and reopens
        host2 = open_port(portname(dev))
        write(host2, UInt8('c'))
        @test decode_u32(readn(host2, 5)) == 12_345
        close(host2)
    finally
        close(host)
        stop(dev)
    end
end

@testset "pty: move timing, queueing, front panel during serial move" begin
    dev = MockSOLO.start(timescale = 10)
    host = open_port(portname(dev))
    try
        target = 10_667 + um2us(5000)                 # 5000 µm: 1.667 s / 10
        t = time()
        write(host, [frame('x', target); UInt8('c')]) # 'c' queues behind the move
        @test readn(host, 1) == [0x0d]
        @test 0.15 < time() - t < 0.5
        @test decode_u32(readn(host, 5)) == target    # exact despite timer jitter

        write(host, frame('x', 10_667))
        sleep(0.05)
        press_home!(dev)                              # ignored: serial move running
        turn_knob!(dev, 100)
        @test screen(dev).color === :red
        @test readn(host, 1) == [0x0d]
        @test position_usteps(dev) == 10_667
    finally
        close(host)
        stop(dev)
    end
end

@testset "pty: stop mid-move returns promptly; stop twice is a no-op" begin
    dev = MockSOLO.start()                            # real time: ~16 s full travel
    host = open_port(portname(dev))
    write(host, frame('x', MAX_USTEPS))
    sleep(0.1)
    t = time()
    @test stop(dev) === nothing
    @test time() - t < 1
    @test stop(dev) === nothing
    @test_throws ErrorException screen(dev)
    @test_throws ErrorException press_home!(dev)
    @test !isempty(traffic(dev))
    @test startswith(portname(dev), "/dev/")
    close(host)
end
