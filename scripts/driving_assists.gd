class_name DrivingAssists
extends RefCounted

## The electronic driver aids a modern car (and every Forza-style racer) runs
## between the pedals and the tyres: traction control, ABS, and stability control.
##
## These are what let a player mash the throttle out of a corner and have the car
## simply go, instead of lighting up the rears and spinning. Without them an
## arcade car is either grippy-but-lifeless (grip so high nothing ever slides) or
## spiky-and-unfair (realistic slip the player has no tools to catch). The assists
## give the third option — a car that lets you drive at the limit and quietly
## saves you when you cross it.
##
## Each aid is an independent toggle so they can be switched off for a "pro" feel
## (and profiled one at a time), exactly like Forza's assist menu:
##
##   * **TCS** (traction control) — cuts engine torque when the driven wheels are
##     spinning faster than the car is actually travelling. Stops wheelspin off
##     the line and mid-corner power-on snap.
##   * **ABS** (anti-lock braking) — releases brake pressure when a wheel is about
##     to lock. A locked wheel has no lateral grip at all, so ABS is what keeps
##     the car steerable under emergency braking.
##   * **Stability control** — applies a corrective yaw torque when the car starts
##     rotating faster than the driver's steering asked for. Catches the tank-slapper
##     after a kerb strike or a bumpy landing.
##
## This is a pure data/logic helper: it takes numbers and returns numbers, with no
## knowledge of the physics body. The car owns one, asks it to filter the throttle
## and brake it was about to apply, and applies the corrective torque it returns.
## That keeps the tuning testable and out of the physics code.
##
## All aids deliberately intervene *smoothly and partially*. A binary "cut all
## power" TCS feels like the engine died; these ramp their intervention with how
## far past the limit the car is, and never take 100% control away from the driver.


# ─── Toggles ─────────────────────────────────────────────────────────────────

## Traction control: cut throttle on wheelspin.
var traction_control_enabled: bool = true
## Anti-lock braking: release brakes on impending lock-up.
var abs_enabled: bool = true
## Stability control: corrective yaw torque on oversteer/understeer.
var stability_control_enabled: bool = true


# ─── Traction control tunables ───────────────────────────────────────────────

## Slip ratio at which TCS starts cutting power. Slip ratio is
## (wheel_surface_speed - car_speed) / car_speed, so 0.15 means the driven wheels
## are turning 15% faster than the ground is passing underneath — the edge of
## useful traction. A little slip is FASTER than none (peak grip sits around
## 0.1-0.2 for a real tyre), so intervening before this would be slow, not safe.
var tcs_slip_threshold: float = 0.15

## Slip ratio at which TCS applies its maximum cut. Between the threshold and
## here the cut ramps in proportionally.
var tcs_slip_full: float = 0.6

## The largest fraction of engine torque TCS may remove. Kept below 1.0 so there
## is always *some* drive — a full cut feels like a stall, and it also makes
## deliberate smoky burnouts impossible, which is no fun.
var tcs_max_cut: float = 0.8

## How quickly the TCS cut ramps in and out (per second). Real traction control
## modulates in milliseconds; smoothing here stops the throttle from chattering
## frame-to-frame as slip oscillates around the threshold.
var tcs_response: float = 12.0

## Minimum speed (m/s) before TCS engages. Slip ratio divides by speed, so it is
## numerically explosive near zero — and pulling away from a standstill always
## involves brief slip that should not be punished.
var tcs_min_speed: float = 2.0


# ─── ABS tunables ────────────────────────────────────────────────────────────

## How much slower than the car a wheel may be turning before ABS releases. 0.25
## means the wheel is turning 25% slower than the road surface is moving, i.e.
## deep into the lock-up zone where lateral grip has collapsed.
var abs_lock_threshold: float = 0.25

## Lock slip at which ABS applies its maximum release.
var abs_lock_full: float = 0.7

## The largest fraction of brake force ABS may remove. Not 1.0: the car must still
## slow down under ABS, just without the wheels stopping dead.
var abs_max_release: float = 0.75

## How quickly the ABS release ramps in and out (per second). Faster than TCS
## because braking events are shorter and the driver expects an immediate bite.
var abs_response: float = 20.0

## Minimum speed (m/s) before ABS engages. Below this, locking the wheels is
## exactly what you want — it is how the car comes to a complete stop and stays
## still. ABS in a real car disengages at walking pace for the same reason.
var abs_min_speed: float = 2.5


# ─── Stability control tunables ──────────────────────────────────────────────

## Yaw-rate error (rad/s) that the car is allowed to deviate from the driver's
## intent before stability control steps in. Some deviation is normal (and is what
## makes a car feel alive), so this is not zero.
var stability_yaw_deadzone: float = 0.35

## Corrective torque (N·m) per rad/s of yaw error beyond the deadzone. The car
## multiplies this by its own scale, so it is a coefficient rather than an
## absolute figure.
var stability_strength: float = 3000.0

## Ceiling on the corrective torque (N·m) so a wild spin cannot produce an absurd
## snap-back that throws the car the other way.
var stability_max_torque: float = 9000.0

## Minimum speed (m/s) before stability control engages. Spinning on the spot at
## walking pace (or doing donuts deliberately) should not be fought.
var stability_min_speed: float = 5.0

## How much of the correction still applies while the handbrake is held. The
## handbrake is an explicit "I want to slide" request, so stability control mostly
## gets out of the way — but not entirely, or the car becomes uncatchable.
var stability_handbrake_factor: float = 0.15


# ─── State ───────────────────────────────────────────────────────────────────

## Current smoothed TCS cut, 0..1 (0 = no intervention, 1 = tcs_max_cut applied).
## Exposed so the HUD can show a traction-control telltale like a real dashboard.
var tcs_cut: float = 0.0

## Current smoothed ABS release, 0..1. Exposed for the HUD telltale.
var abs_release: float = 0.0

## Last corrective yaw torque magnitude applied, for the HUD telltale and tests.
var stability_intervention: float = 0.0


## Filter the engine force the driver asked for through traction control.
##
##   engine_force  the force the throttle would apply with no assist (N).
##   wheel_speed   surface speed of the driven wheels (m/s) — how fast the tyres
##                 are turning, expressed as the ground speed they would produce.
##   car_speed     how fast the car is actually travelling (m/s).
##   delta         physics frame time, seconds.
##
## Returns the force to actually apply. Never increases the force: an assist can
## only take away.
func filter_engine_force(
	engine_force: float,
	wheel_speed: float,
	car_speed: float,
	delta: float
) -> float:
	var target_cut := 0.0
	if traction_control_enabled and absf(car_speed) >= tcs_min_speed:
		var slip := slip_ratio(wheel_speed, car_speed)
		# Only positive slip (wheels outrunning the car) is wheelspin. Negative
		# slip under power is not a thing TCS handles — that is ABS's job.
		if slip > tcs_slip_threshold and tcs_slip_full > tcs_slip_threshold:
			target_cut = clampf(
				(slip - tcs_slip_threshold) / (tcs_slip_full - tcs_slip_threshold),
				0.0,
				1.0
			)
	tcs_cut = _approach(tcs_cut, target_cut, tcs_response, delta)
	return engine_force * (1.0 - tcs_cut * tcs_max_cut)


## Filter the brake force the driver asked for through ABS.
##
##   brake_force  the force the brake pedal would apply with no assist (N).
##   wheel_speed  surface speed of the braked wheels (m/s).
##   car_speed    how fast the car is actually travelling (m/s).
##   delta        physics frame time, seconds.
##
## Returns the force to actually apply. Never increases the force.
func filter_brake_force(
	brake_force: float,
	wheel_speed: float,
	car_speed: float,
	delta: float
) -> float:
	var target_release := 0.0
	if abs_enabled and absf(car_speed) >= abs_min_speed:
		# Lock slip is the mirror of wheelspin: the wheel turning SLOWER than the
		# road. Expressed positive so the ramp reads the same way as TCS.
		var lock := -slip_ratio(wheel_speed, car_speed)
		if lock > abs_lock_threshold and abs_lock_full > abs_lock_threshold:
			target_release = clampf(
				(lock - abs_lock_threshold) / (abs_lock_full - abs_lock_threshold),
				0.0,
				1.0
			)
	abs_release = _approach(abs_release, target_release, abs_response, delta)
	return brake_force * (1.0 - abs_release * abs_max_release)


## The corrective yaw torque (N·m, signed) stability control wants to apply.
##
##   yaw_rate         the car's actual rotation rate about its up axis (rad/s).
##   desired_yaw_rate the rotation rate the driver's steering asked for (rad/s).
##                    The car derives this from steering angle and speed; see
##                    CarController._desired_yaw_rate.
##   speed            current speed magnitude (m/s).
##   handbrake        true while the handbrake is held (deliberate slide).
##
## Returns 0.0 when the aid is off, the car is slow, or the yaw error is inside
## the deadzone. The sign opposes the excess rotation.
func stability_torque(
	yaw_rate: float,
	desired_yaw_rate: float,
	speed: float,
	handbrake: bool
) -> float:
	stability_intervention = 0.0
	if not stability_control_enabled or speed < stability_min_speed:
		return 0.0

	# How much more (or less) the car is rotating than the driver asked for.
	var error := yaw_rate - desired_yaw_rate
	if absf(error) <= stability_yaw_deadzone:
		return 0.0

	# Only the portion beyond the deadzone is corrected, so the intervention
	# fades in from nothing rather than stepping on at the threshold.
	var excess := (absf(error) - stability_yaw_deadzone) * signf(error)
	var torque := -excess * stability_strength
	if handbrake:
		torque *= stability_handbrake_factor
	torque = clampf(torque, -stability_max_torque, stability_max_torque)
	stability_intervention = absf(torque)
	return torque


## Slip ratio between the tyres and the road: positive when the wheels are
## outrunning the car (wheelspin under power), negative when the car is outrunning
## the wheels (lock-up under braking).
##
## Guarded against the divide-by-zero at a standstill, which is why callers also
## gate on a minimum speed.
static func slip_ratio(wheel_speed: float, car_speed: float) -> float:
	var reference := maxf(absf(car_speed), 0.001)
	return (wheel_speed - car_speed) / reference


## Frame-rate-independent exponential approach of `current` toward `target`.
## Used to smooth the assist interventions so they ramp instead of chattering.
static func _approach(current: float, target: float, response: float, delta: float) -> float:
	if response <= 0.0 or delta <= 0.0:
		return target
	var weight := clampf(response * delta, 0.0, 1.0)
	return lerpf(current, target, weight)


## Turn every aid off (the "pro / simulation" preset) or on (the "assisted"
## default). Convenience for a settings menu toggle.
func set_all_enabled(enabled: bool) -> void:
	traction_control_enabled = enabled
	abs_enabled = enabled
	stability_control_enabled = enabled


## Clear the smoothed intervention state. Called on respawn so a mid-slide
## correction does not carry into the new position.
func reset() -> void:
	tcs_cut = 0.0
	abs_release = 0.0
	stability_intervention = 0.0
