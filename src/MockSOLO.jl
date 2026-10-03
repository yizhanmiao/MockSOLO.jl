"""
Mock of a Sutter SOLO-50 single-axis micromanipulator served on a virtual serial
port. See `MockSOLO.start`.
"""
module MockSOLO

export MockSOLO50, portname, traffic, stop
export position_usteps, screen, press_home!, hold_home!, press_work!, hold_work!,
       pulse!, press_relative!, hold_relative!, press_speed!, turn_knob!

include("device.jl")
include("serial.jl")

end
