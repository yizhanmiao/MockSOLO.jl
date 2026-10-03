using MockSOLO
using Test

@testset "MockSOLO" begin
    include("test_device.jl")
    include("test_serial.jl")
end
