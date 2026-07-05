class_name CameraShake
extends RefCounted

## Trauma-based camera shake for impact/landing feedback.
##
## This is a pure logic helper with no knowledge of the camera node, the physics
## body or the scene tree — the car owns one, feeds it "trauma" when something
## jarring happens (a crash, a hard landing), and each frame asks it for a small
## positional + rotational offset to add on top of the smooth follow camera.
## Keeping it standalone makes the decay curve easy to tune and unit-test.
##
## The model follows the well-known "trauma" pattern (Squirrel Eiserloh, GDC):
##   - Callers ADD trauma (0..1) on an event; it never sets the offset directly.
##   - Shake magnitude is trauma SQUARED (or cubed), so small trauma is subtle and
##     large trauma is dramatic — this non-linearity is what makes it feel good.
##   - Trauma decays linearly toward zero every frame, so the shake always settles.
##   - The offset itself is driven by smooth noise (not raw random) so successive
##     frames are coherent and the camera swishes rather than buzzing like static.
##
## The offset is returned as small translation + euler rotation values in the
## camera's local space; the caller composes them onto the pivot however it likes.

## Maximum positional offset (metres) at full trauma, per axis. Small — a camera
## shake that physically moves the eye more than a few cm reads as a bug, not juice.
var max_offset: float = 0.25

## Maximum rotational offset (radians) at full trauma, per axis. ~0.05 rad ≈ 3°,
## which is plenty; roll (z) is the most visible and is weighted up in get_offset.
var max_roll: float = 0.06

## How fast trauma bleeds off (units of trauma per second). 1.0 means a full-trauma
## shake fully settles in one second; higher = snappier, lower = lingering rumble.
var decay_rate: float = 1.6

## Exponent applied to trauma to get shake amplitude. 2.0 (squared) is the classic
## value: it keeps tiny bumps subtle while letting big hits slam. 3.0 is punchier.
var trauma_power: float = 2.0

## How quickly the underlying noise sweeps. Higher = faster, buzzier shake; lower =
## slower, floatier sway. Tuned so an impact reads as a sharp rattle.
var frequency: float = 18.0

## Current trauma in [0, 1]. Never read directly by callers — use add_trauma / the
## returned offset — but exposed for tests and debug HUDs.
var trauma: float = 0.0

## Internal clock (seconds) advanced by tick(), used to sample the noise. Phase
## offsets per axis keep x/y/roll from moving in lockstep.
var _time: float = 0.0

## Deterministic pseudo-noise source seeded once so a given (time, axis) always
## yields the same value — important for reproducible tests. Real Godot noise
## objects are avoided so this class stays a pure RefCounted with no resources.
var _noise := FastNoiseLite.new()


func _init() -> void:
	_noise.noise_type = FastNoiseLite.TYPE_PERLIN
	_noise.seed = 1337
	# A moderate frequency on the noise field itself; the sweep speed is applied
	# via `frequency` when we sample, so this just sets the spatial roughness.
	_noise.frequency = 1.0


## Add trauma from an event. `amount` is added (not set) and the total is clamped
## to 1.0, so several hits in quick succession stack toward a maximal shake rather
## than resetting each other. Negative amounts are ignored.
func add_trauma(amount: float) -> void:
	if amount <= 0.0:
		return
	trauma = clampf(trauma + amount, 0.0, 1.0)


## Advance the shake by `delta` seconds, decaying trauma. Call once per frame
## before get_offset(). Returns the (possibly zero) remaining trauma for convenience.
func tick(delta: float) -> float:
	if delta <= 0.0:
		return trauma
	_time += delta
	trauma = maxf(0.0, trauma - decay_rate * delta)
	return trauma


## True while there is any shake left to apply. Lets the caller skip composing the
## offset entirely (and restore the resting camera) once things have settled.
func is_active() -> bool:
	return trauma > 0.0


## Current shake amplitude in [0, 1]: trauma raised to `trauma_power`. Exposed so
## callers can also drive secondary effects (e.g. a subtle FOV punch) off the same
## curve, and so tests can assert the non-linearity.
func amplitude() -> float:
	return pow(trauma, trauma_power)


## The shake offset for this frame. Returns a dictionary with:
##   "position": Vector3  — local-space translation (metres) to add to the camera
##   "rotation": Vector3  — local-space euler angles (radians) to add (x=pitch,
##                          y=yaw, z=roll)
## Both are zero when trauma is zero. The values are driven by coherent noise
## scaled by amplitude(), so they sweep smoothly and always fade out with trauma.
func get_offset() -> Dictionary:
	var amp := amplitude()
	if amp <= 0.0:
		return {"position": Vector3.ZERO, "rotation": Vector3.ZERO}
	var t := _time * frequency
	# Distinct large phase offsets per channel so no two axes ever correlate.
	var nx := _sample(t, 0.0)
	var ny := _sample(t, 100.0)
	var nz := _sample(t, 200.0)
	var npitch := _sample(t, 300.0)
	var nyaw := _sample(t, 400.0)
	var pos := Vector3(nx, ny, nz) * (max_offset * amp)
	# Roll is the strongest, most cinematic component; pitch/yaw add a little jitter.
	var rot := Vector3(
		npitch * (max_roll * 0.5 * amp),
		nyaw * (max_roll * 0.5 * amp),
		nx * (max_roll * amp),
	)
	return {"position": pos, "rotation": rot}


## Sample the noise field in [-1, 1] at a time coordinate with a per-axis offset.
func _sample(t: float, axis_offset: float) -> float:
	return _noise.get_noise_2d(t + axis_offset, axis_offset)
