class_name KudosTracker
extends RefCounted

## Scores how stylishly the car is being driven and accumulates a running "kudos"
## total — the game's fun metric. Cool moves (drifts, big air, near misses, fast
## clean driving) add kudos; mistakes (crashes, going off-road, flipping, spinning
## out) take it away.
##
## This is a pure data/logic helper with no knowledge of the physics body or the
## HUD. Each physics frame the car hands it a Telemetry snapshot (speed, slip
## angle, wheel contact, etc.); the tracker integrates that into a score and
## reports discrete "events" (named scoring moments) so the HUD can pop up
## "DRIFT! +120" style feedback. Keeping it standalone makes the scoring curve
## easy to tune and unit-test, and means the car/HUD never embed magic numbers.
##
## Sign convention: kudos is clamped at >= 0 (you can't go into debt). A combo
## multiplier rewards stringing cool moves together without a mistake; any
## penalty resets the combo.

## A single scoring moment worth showing the player, e.g. "DRIFT", "NEAR MISS",
## "CRASH". Emitted from update() so the HUD can flash a label. `amount` is the
## kudos delta already applied (positive = earned, negative = lost).
class KudosEvent:
	extends RefCounted
	var label: String
	var amount: int
	## True for mistakes (so the HUD can colour them red), false for cool moves.
	var is_penalty: bool

	func _init(p_label: String, p_amount: int, p_is_penalty: bool) -> void:
		label = p_label
		amount = p_amount
		is_penalty = p_is_penalty


## Everything the tracker needs to score one physics frame. The car fills this in
## from its physics state and hands it to update(); the tracker never reads the
## body itself. All speeds in m/s, angles in radians.
class Telemetry:
	extends RefCounted
	## Forward speed along the car's nose (signed; negative = reversing), m/s.
	var forward_speed: float = 0.0
	## Overall speed magnitude, m/s.
	var speed: float = 0.0
	## Sideways slip angle: angle between where the car points and where it's
	## actually moving, in radians (0 = going straight, ~PI/2 = fully sideways).
	var slip_angle: float = 0.0
	## Yaw rate (rotation about the up axis), rad/s. Used to detect spin-outs.
	var yaw_rate: float = 0.0
	## How upright the car is: dot(car_up, world_up). 1 = level, 0 = on its side,
	## -1 = on its roof.
	var uprightness: float = 1.0
	## How many of the four wheels are touching the ground (0..4).
	var wheels_on_ground: int = 4
	## True if the car is (mostly) over a road surface this frame.
	var on_road: bool = true
	## Distance (m) to the nearest solid obstacle along the travel direction this
	## frame, or a large sentinel if nothing is close. Used for near-miss scoring.
	var nearest_obstacle_dist: float = 999.0


# ─── Tunables ────────────────────────────────────────────────────────────────

## Minimum speed (m/s) before any style scoring happens. Crawling around can't
## earn kudos — about 18 km/h.
var min_scoring_speed: float = 5.0

## Slip angle (radians) past which the car counts as drifting. ~14 degrees.
var drift_slip_threshold: float = 0.25
## Kudos per second of sustained drift, before the speed and combo multipliers.
var drift_rate: float = 60.0

## Kudos per second for sustained fast, clean, on-road driving (the "in the zone"
## trickle). Scales with how close to top speed you are.
var speed_rate: float = 8.0
## Fraction of max speed you must exceed to start earning the speed trickle.
var speed_bonus_fraction: float = 0.6

## Kudos per second of airtime (all four wheels off the ground at speed).
var airtime_rate: float = 90.0

## Distance (m) under which passing an obstacle at speed counts as a near miss.
var near_miss_distance: float = 3.0
## Flat kudos awarded for a near miss (scaled by speed).
var near_miss_reward: float = 50.0
## Cooldown (s) after a near miss before another can fire, so one obstacle does
## not machine-gun rewards frame after frame.
var near_miss_cooldown: float = 0.8

## Off-road bleed: kudos lost per second while driving on grass at speed.
var offroad_penalty_rate: float = 25.0

## Spin-out: yaw rate (rad/s) past which an uncommanded slide counts as losing
## control. ~115 deg/s.
var spinout_yaw_threshold: float = 2.0
## One-off penalty when a spin-out is first detected. Kept modest: a spin is a
## loss of control but not a wreck, so it should sting without wiping a small
## score. A drift gone slightly too far shouldn't cost more than the drift earned.
var spinout_penalty: float = 30.0

## Flip/roll: uprightness below this means the car is on its side or roof.
var flip_uprightness_threshold: float = 0.3
## One-off penalty when the car tips over.
var flip_penalty: float = 150.0

## Crash detection: a drop in speed (m/s) within a single frame larger than this
## is treated as an impact. Hard braking is gentler than this per-frame.
var crash_decel_threshold: float = 6.0
## Penalty per m/s of speed lost in a crash (a fast head-on hurts more).
var crash_penalty_per_ms: float = 20.0

## Combo: each cool move without a mistake bumps the multiplier by this much,
## up to combo_max. A penalty resets it to 1.0.
var combo_step: float = 0.25
var combo_max: float = 5.0
## How long (s) the combo survives with no cool move before decaying back to 1.0.
var combo_timeout: float = 4.0


# ─── State ───────────────────────────────────────────────────────────────────

## Running total. Never negative.
var _kudos: float = 0.0
## Current combo multiplier (1.0 .. combo_max).
var _combo: float = 1.0
## Seconds since the last cool move; resets the combo once it passes the timeout.
var _combo_idle: float = 0.0
## Seconds left on the near-miss cooldown.
var _near_miss_timer: float = 0.0
## Speed last frame, for per-frame deceleration (crash) detection.
var _prev_speed: float = -1.0
## Latching flags so a sustained bad state only penalises once, not every frame.
var _was_flipped: bool = false
var _was_spinning: bool = false
## True while a drift is ongoing, so the HUD only gets one "DRIFT" event per slide.
var _was_drifting: bool = false
## Most recent frame delta, captured in update() so the off-road bleed helper can
## use it without threading delta through every internal signature. Defaults to a
## 60 Hz step so a direct unit-test call still behaves sanely.
var _delta_for_bleed: float = 1.0 / 60.0


## Returns the current kudos total (rounded, never negative) for the HUD.
func get_kudos() -> int:
	return int(round(_kudos))


## Returns the current combo multiplier for the HUD (e.g. show "x2.5").
func get_combo() -> float:
	return _combo


## Integrate one physics frame of telemetry. Returns the list of discrete
## KudosEvents that fired this frame (usually empty; the drift/airtime trickle
## emits one event when the move *starts* so the HUD does not spam). The running
## total is updated in place — read it back with get_kudos().
func update(t: Telemetry, delta: float) -> Array[KudosEvent]:
	var events: Array[KudosEvent] = []
	if delta <= 0.0:
		return events

	_delta_for_bleed = delta
	_tick_timers(delta)

	# Mistakes first: a crash/flip/spin this frame both penalises and kills the
	# combo, and we don't want to award style points on the same frame you wreck.
	var penalised := _score_mistakes(t, events)

	# Cool moves only count when moving with intent and the right way up.
	var can_style := t.speed >= min_scoring_speed and t.uprightness > flip_uprightness_threshold
	if can_style and not penalised:
		_score_cool_moves(t, delta, events)
	else:
		# Stopped drifting (slowed, wrecked, or stopped) — clear the latch so the
		# next slide registers as a fresh drift.
		_was_drifting = false

	_prev_speed = t.speed
	_kudos = maxf(0.0, _kudos)
	return events


# ─── Internals ───────────────────────────────────────────────────────────────

func _tick_timers(delta: float) -> void:
	if _near_miss_timer > 0.0:
		_near_miss_timer = maxf(0.0, _near_miss_timer - delta)
	# Decay the combo if no cool move has happened for a while.
	_combo_idle += delta
	if _combo_idle >= combo_timeout:
		_combo = 1.0


## Apply penalties for crashes, flips, spin-outs and off-road bleed. Appends any
## discrete events. Returns true if a hard, combo-breaking mistake occurred this
## frame (crash/flip/spin) — off-road bleed alone does not count as "penalised".
func _score_mistakes(t: Telemetry, events: Array[KudosEvent]) -> bool:
	var hard_mistake := false

	# Crash: a large single-frame speed drop. _prev_speed < 0 means "first frame",
	# skip it so spawning doesn't read as a crash.
	if _prev_speed >= 0.0:
		var decel := _prev_speed - t.speed
		if decel >= crash_decel_threshold:
			var penalty := decel * crash_penalty_per_ms
			_apply_penalty("CRASH", penalty, events)
			hard_mistake = true

	# Flip/roll: only fire once when the car first tips past the threshold.
	var flipped := t.uprightness < flip_uprightness_threshold
	if flipped and not _was_flipped:
		_apply_penalty("FLIPPED", flip_penalty, events)
		hard_mistake = true
	_was_flipped = flipped

	# Spin-out: uncommanded high yaw rate while sliding. Fire once per spin.
	var spinning := absf(t.yaw_rate) > spinout_yaw_threshold and t.speed > min_scoring_speed
	if spinning and not _was_spinning:
		_apply_penalty("SPIN OUT", spinout_penalty, events)
		hard_mistake = true
	_was_spinning = spinning

	# Off-road bleed: a steady drain while driving on grass at speed. This is a
	# soft penalty — it does not break the combo or block style scoring (you can
	# still earn a drift bonus on dirt), it just costs you over time.
	if not t.on_road and t.speed > min_scoring_speed:
		_kudos -= offroad_penalty_rate * _delta_for_bleed
		# Reset the combo timer so sitting off-road quietly times the combo out.
		# (We intentionally do not emit a per-frame event for the bleed.)

	return hard_mistake


## Award style points for drifting, airtime, near misses and fast clean driving.
func _score_cool_moves(t: Telemetry, delta: float, events: Array[KudosEvent]) -> void:
	var earned_this_frame := false

	# Drift: sustained slip while keeping speed. Faster, wider drifts pay more.
	var drifting := t.slip_angle > drift_slip_threshold and t.wheels_on_ground >= 2
	if drifting:
		var slip_factor: float = clampf(t.slip_angle / (PI * 0.5), 0.0, 1.0)
		var gain := drift_rate * delta * (0.5 + slip_factor) * _speed_factor(t)
		_kudos += gain * _combo
		earned_this_frame = true
		if not _was_drifting:
			_bump_combo()
			events.append(KudosEvent.new("DRIFT", int(round(gain * _combo)), false))
	_was_drifting = drifting

	# Airtime: all four wheels off the deck. Big jumps feel great, so pay well.
	if t.wheels_on_ground == 0:
		var gain := airtime_rate * delta
		_kudos += gain * _combo
		earned_this_frame = true

	# Near miss: brushed past an obstacle at speed without hitting it.
	if _near_miss_timer <= 0.0 and t.nearest_obstacle_dist < near_miss_distance \
			and t.speed > min_scoring_speed:
		var reward := near_miss_reward * _speed_factor(t)
		_kudos += reward * _combo
		_near_miss_timer = near_miss_cooldown
		_bump_combo()
		events.append(KudosEvent.new("NEAR MISS", int(round(reward * _combo)), false))
		earned_this_frame = true

	# Speed trickle: a quiet reward for holding high speed cleanly on the road.
	if t.on_road and t.forward_speed > 0.0:
		var over := _speed_over_fraction(t)
		if over > 0.0:
			_kudos += speed_rate * delta * over * _combo
			earned_this_frame = true

	if earned_this_frame:
		_combo_idle = 0.0


## A 0..1 factor for how fast the car is going relative to a reference top speed,
## used to scale rewards so fast moves pay more than slow ones.
func _speed_factor(t: Telemetry) -> float:
	# Reference ~30 m/s (~108 km/h). Clamp so very fast does not over-reward.
	return clampf(t.speed / 30.0, 0.2, 1.5)


## How far above the speed-bonus threshold the car is, as a 0..1 fraction of the
## remaining speed range. Only used for the clean-driving speed trickle.
func _speed_over_fraction(t: Telemetry) -> float:
	var ref := 30.0
	var threshold := ref * speed_bonus_fraction
	if t.speed <= threshold:
		return 0.0
	return clampf((t.speed - threshold) / (ref - threshold), 0.0, 1.0)


func _bump_combo() -> void:
	_combo = minf(combo_max, _combo + combo_step)
	_combo_idle = 0.0


func _apply_penalty(label: String, amount: float, events: Array[KudosEvent]) -> void:
	var before := _kudos
	_kudos = maxf(0.0, _kudos - amount)
	var lost := int(round(before - _kudos))
	# Any hard mistake wipes the combo — that's the risk/reward tension.
	_combo = 1.0
	_combo_idle = 0.0
	events.append(KudosEvent.new(label, -lost, true))
