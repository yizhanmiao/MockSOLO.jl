# Front panel

Julia code that owns the mock can act as a person at the controller. Front-panel
actions move the device, and the host sees the result through `c`. The front panel
never changes the serial protocol's coordinates, which are always absolute.

## Actions

The device is either **idle** or **in a move**. A move counts as in progress whether it
is running or paused.

| Function | Idle | During a move |
|---|---|---|
| [`press_home!`](@ref) | start moving to home | in a HOME move: toggle pause; otherwise ignored |
| [`press_work!`](@ref) | start moving to work | in a WORK move: toggle pause; otherwise ignored |
| [`hold_home!`](@ref) / [`hold_work!`](@ref) | store the current position as home / work | ignored |
| [`pulse!`](@ref) | move +30 µsteps (clamped) | ignored |
| [`turn_knob!`](@ref)`(dev, Δum)` | jump instantly by `Δum` µm, clamped to range | ignored |
| [`press_relative!`](@ref) | toggle relative display mode | ignored |
| [`hold_relative!`](@ref) | set the relative origin to the current position | ignored |
| [`press_speed!`](@ref) | cycle knob speed 0→1→2→3→0 (stored only) | ignored |

A serial move command sent during a front-panel move takes over from the current
position and clears any pause. During a serial move, every front-panel input is
ignored.

## Screen

[`screen`](@ref) returns `(absolute_um, relative_um, color)`:

- `absolute_um` is the position in whole µm.
- `relative_um` is the position relative to the origin set by `hold_relative!`
  (origin 0 at startup), and may be negative.
- `color` is `:red` during a move (running or paused), otherwise `:blue` in relative
  mode, otherwise `:green`.

## Example

```julia
using MockSOLO
dev = MockSOLO.start()

turn_knob!(dev, 2000)    # jump from 1000 µm to 3000 µm
hold_relative!(dev)      # zero the relative display here
press_relative!(dev)     # relative mode: the screen turns blue
press_home!(dev)         # start the 2000 µm move back to home (about 0.67 s)
press_home!(dev)         # pause it
screen(dev).color        # :red, since a paused move still counts as moving
press_home!(dev)         # resume
sleep(1)
screen(dev)              # (absolute_um = 1000, relative_um = -2000, color = :blue)
stop(dev)
```
