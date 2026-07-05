class_name CarAudioTriggers
extends RefCounted

## Decides WHEN the car should screech its tyres and HOW LOUD an impact should be.
##
## This is a pure logic helper with no knowledge of AudioStreamPlayers, the
## physics body or the scene tree — the car feeds it a per-frame snapshot (slip
## angle, speed, whether the tyres are gripping) plus discrete crash severities,
## and it answers with a target screech level and impact one-shot volumes. The
## thin scene-side player in car_controller turns those numbers into actual sound,
## and degrades gracefully when the sound files are absent.
##
## Keeping the decision logic here makes the "does this feel right?" curve easy to
## tune and unit-test without spinning up audio hardware or a running game.

## ── Screech ──────────────────────────────────────────────────────────────────

## Slip angle (radians) below which the tyres are considered to be tracking
## cleanly — no screech at all. Parking jitter and gentle cornering stay silent.
var screech_slip_threshold: float = 0.20

## Slip angle (radians) at which the screech reaches full volume. Between the
## threshold and this the level ramps up linearly.
var screech_slip_full: float = 0.6

## Speed (m/s) below which tyres never screech, however sideways they are — a car
## being nudged while nearly stopped shouldn't squeal. ~11 km/h.
var screech_min_speed: float = 3.0

## Speed (m/s) at which the speed contribution to screech saturates. Tuned to this
## car's arcade range (top speed ~15 m/s / 55 km/h): a proper drift happens around
## 8–12 m/s, so the squeal must reach full strength there, not at some 65 km/h the
## car can never hit. (The old value of 18 kept every drift near-silent.)
var screech_full_speed: float = 10.0

## How fast the screech level RISES toward its target (per-second lerp weight).
## Fast so a squeal starts promptly when the tyres break loose.
var screech_attack: float = 12.0

## How fast the screech level FALLS toward its target (per-second lerp weight).
## Deliberately slow: during a drift the slip angle dips below the threshold for a
## frame or two constantly, which zeroes the target; a slow release holds the
## squeal through those dips instead of stuttering on and off (which restarted the
## sample every few frames and produced no audible sound).
var screech_release: float = 3.0

## Current smoothed screech level in [0, 1]. 0 = silent, 1 = full squeal. The
## scene-side player maps this onto volume (and can pitch it) and starts/stops the
## loop based on whether it is above ~0.
var screech_level: float = 0.0

## ── Impact ───────────────────────────────────────────────────────────────────

## Crash severity (the absolute kudos penalty) at or below which an impact is a
## soft "tap" — audible but quiet. Scales up to `impact_full_severity`.
var impact_min_severity: float = 5.0

## Crash severity at which the impact one-shot plays at full volume.
var impact_full_severity: float = 120.0

## Minimum spacing (seconds) between impact one-shots, so a multi-frame crash
## (which can emit several penalty events in a row) fires ONE thump, not a burst.
var impact_cooldown: float = 0.15

## Seconds since the last impact fired, counted up by update_screech()'s delta.
var _time_since_impact: float = 999.0


## Advance the screech decision by one frame.
##
##   slip_angle:  radians between nose heading and travel (car_controller already
##                computes this for kudos; reuse it).
##   speed:       unsigned car speed (m/s).
##   gripping:    false when the tyres have broken traction (handbrake drift, or a
##                spin). When gripping cleanly a small slip still shouldn't squeal
##                as loudly as a full breakaway, so this gates the top end.
##   delta:       frame time (s), used to ease the level and advance the cooldown.
##
## Returns the new smoothed screech_level for convenience.
func update_screech(slip_angle: float, speed: float, gripping: bool, delta: float) -> float:
	_time_since_impact += maxf(0.0, delta)
	var target := _screech_target(slip_angle, speed, gripping)
	# Asymmetric smoothing: rise fast (attack), fall slow (release). The slow
	# release is what keeps the loop audible through the constant sub-threshold slip
	# dips that happen mid-drift.
	var rate := screech_attack if target > screech_level else screech_release
	var w := clampf(delta * rate, 0.0, 1.0)
	screech_level = lerpf(screech_level, target, w)
	# Snap tiny residuals to zero so the loop can be fully stopped.
	if screech_level < 0.001 and target <= 0.0:
		screech_level = 0.0
	return screech_level


## The instantaneous (un-smoothed) screech target for a given state, in [0, 1].
## Exposed for testing the raw curve independent of the easing.
func _screech_target(slip_angle: float, speed: float, gripping: bool) -> float:
	if speed < screech_min_speed:
		return 0.0
	var slip_factor := clampf(
		(absf(slip_angle) - screech_slip_threshold)
			/ maxf(0.0001, screech_slip_full - screech_slip_threshold),
		0.0, 1.0)
	if slip_factor <= 0.0:
		return 0.0
	var speed_factor := clampf(
		(speed - screech_min_speed) / maxf(0.0001, screech_full_speed - screech_min_speed),
		0.0, 1.0)
	var level := slip_factor * speed_factor
	# A clean-gripping tyre is a touch quieter than a full handbrake breakaway, but
	# only slightly — a hard cornering drift should still squeal clearly. (The old
	# 0.6 multiplier, stacked on mis-tuned speed thresholds, made grip drifts silent.)
	if gripping:
		level *= 0.85
	return clampf(level, 0.0, 1.0)


## Decide whether a crash of the given severity should fire an impact one-shot,
## and at what volume. Call once per crash penalty event.
##
## Returns a dictionary:
##   "play":   bool   — true if the one-shot should trigger (false if on cooldown
##                      or the severity is negligible)
##   "volume": float  — linear volume in [0, 1] scaled by severity (only meaningful
##                      when "play" is true)
##
## The cooldown is consumed only when "play" is true, so a rejected (too-soon) hit
## doesn't reset the timer and swallow a later, legitimately-spaced impact.
func register_impact(severity: float) -> Dictionary:
	if severity < impact_min_severity:
		return {"play": false, "volume": 0.0}
	if _time_since_impact < impact_cooldown:
		return {"play": false, "volume": 0.0}
	_time_since_impact = 0.0
	var volume := clampf(
		(severity - impact_min_severity)
			/ maxf(0.0001, impact_full_severity - impact_min_severity),
		0.0, 1.0)
	# Even a minimal qualifying tap is audible: floor the volume so it isn't silent.
	volume = maxf(0.15, volume)
	return {"play": true, "volume": volume}
