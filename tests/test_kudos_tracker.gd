extends GdUnitTestSuite

## Unit tests for KudosTracker, the style/fun scorer.
##
## KudosTracker is a pure data/logic helper (no physics body, no scene tree):
## given a per-frame Telemetry snapshot it integrates a "kudos" score, awarding
## cool driving (drifts, airtime, near misses, fast clean driving) and penalising
## mistakes (crashes, off-road, flips, spin-outs). Because the whole point of the
## feature is the *feel* of the scoring curve, these tests pin the contract that
## future tuning must not silently break:
##
##   1. A fresh tracker starts at zero and never goes negative.
##   2. Each cool move actually adds kudos; each mistake subtracts it.
##   3. Latching: a sustained bad state (flip/spin) penalises once, not per frame.
##   4. The combo multiplier grows on cool moves and resets on any mistake.
##   5. Discrete events are reported for the HUD with the right sign/penalty flag.

const KudosTracker := preload("res://scripts/kudos_tracker.gd")

## A generous step so per-second rates produce easily-asserted amounts.
const STEP := 1.0 / 60.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _make() -> KudosTracker:
	return KudosTracker.new()

## A neutral telemetry snapshot: moving forward at a healthy clip, level, all
## wheels down, on road, nothing nearby, tracking straight. Individual tests
## tweak only the field they care about.
func _cruising() -> KudosTracker.Telemetry:
	var t := KudosTracker.Telemetry.new()
	t.forward_speed = 20.0
	t.speed = 20.0
	t.slip_angle = 0.0
	t.yaw_rate = 0.0
	t.uprightness = 1.0
	t.wheels_on_ground = 4
	t.on_road = true
	t.nearest_obstacle_dist = 999.0
	return t

## Run the same telemetry for `seconds` worth of fixed steps. Returns every event
## that fired across all frames, flattened, so tests can assert on labels.
func _run(tracker: KudosTracker, t: KudosTracker.Telemetry, seconds: float) -> Array[KudosTracker.KudosEvent]:
	var all_events: Array[KudosTracker.KudosEvent] = []
	var elapsed := 0.0
	while elapsed < seconds:
		var evs := tracker.update(t, STEP)
		all_events.append_array(evs)
		elapsed += STEP
	return all_events


## Count how many events in a list carry the given label. Avoids inline lambdas
## (which infer Variant element types and trip the strict warnings-as-errors).
func _count_label(events: Array[KudosTracker.KudosEvent], label: String) -> int:
	var n := 0
	for e: KudosTracker.KudosEvent in events:
		if e.label == label:
			n += 1
	return n


## Return the first event with the given label, or null if none.
func _first_with_label(events: Array[KudosTracker.KudosEvent], label: String) -> KudosTracker.KudosEvent:
	for e: KudosTracker.KudosEvent in events:
		if e.label == label:
			return e
	return null


# ─── Baseline ────────────────────────────────────────────────────────────────

func test_starts_at_zero() -> void:
	var k := _make()
	assert_int(k.get_kudos()) \
		.override_failure_message("A fresh tracker starts at 0 kudos").is_equal(0)
	assert_float(k.get_combo()) \
		.override_failure_message("A fresh tracker starts at combo x1").is_equal(1.0)


func test_never_goes_negative() -> void:
	var k := _make()
	# Slam a huge crash into an empty score; it must clamp at 0, not go negative.
	var t := _cruising()
	# Prime _prev_speed with one normal frame, then drop speed hard next frame.
	k.update(t, STEP)
	t.speed = 0.0
	k.update(t, STEP)
	assert_int(k.get_kudos()) \
		.override_failure_message("Kudos clamps at 0 and never goes negative") \
		.is_greater_equal(0)


func test_idle_stationary_earns_nothing() -> void:
	var k := _make()
	var t := _cruising()
	t.forward_speed = 0.0
	t.speed = 0.0
	_run(k, t, 1.0)
	assert_int(k.get_kudos()) \
		.override_failure_message("Sitting still earns no kudos").is_equal(0)


# ─── Cool moves add kudos ────────────────────────────────────────────────────

func test_drift_earns_kudos() -> void:
	var k := _make()
	var t := _cruising()
	# A wide slip angle with wheels down at speed = a drift.
	t.slip_angle = 0.6
	var events := _run(k, t, 1.0)
	assert_int(k.get_kudos()) \
		.override_failure_message("Sustained drifting earns kudos").is_greater(0)
	# The HUD should have been told about the drift exactly once (one slide).
	assert_int(_count_label(events, "DRIFT")) \
		.override_failure_message("One continuous drift reports a single DRIFT event") \
		.is_equal(1)


func test_airtime_earns_kudos() -> void:
	var k := _make()
	var t := _cruising()
	t.wheels_on_ground = 0  # All four wheels off the deck = a jump.
	_run(k, t, 1.0)
	assert_int(k.get_kudos()) \
		.override_failure_message("Airtime earns kudos").is_greater(0)


func test_near_miss_rewarded_once_within_cooldown() -> void:
	var k := _make()
	var t := _cruising()
	t.nearest_obstacle_dist = 1.0  # Brushing right past an obstacle.
	# Run only briefly — shorter than the near-miss cooldown — so it can only fire once.
	var events := _run(k, t, 0.5)
	assert_int(_count_label(events, "NEAR MISS")) \
		.override_failure_message("A single pass within the cooldown fires one NEAR MISS") \
		.is_equal(1)
	assert_int(k.get_kudos()) \
		.override_failure_message("A near miss adds kudos").is_greater(0)


func test_fast_clean_driving_trickles_kudos() -> void:
	var k := _make()
	var t := _cruising()
	t.speed = 28.0  # Well above the speed-bonus threshold.
	t.forward_speed = 28.0
	_run(k, t, 1.0)
	assert_int(k.get_kudos()) \
		.override_failure_message("Holding high speed on-road trickles kudos") \
		.is_greater(0)


# ─── Mistakes subtract kudos ─────────────────────────────────────────────────

func _bank_kudos(k: KudosTracker, amount_seconds: float) -> void:
	# Drift for a while to build a comfortable balance to spend on penalties.
	var t := _cruising()
	t.slip_angle = 0.6
	_run(k, t, amount_seconds)


func test_crash_penalises() -> void:
	var k := _make()
	_bank_kudos(k, 2.0)
	var before := k.get_kudos()
	# One normal frame to set _prev_speed, then a sudden stop = crash.
	var t := _cruising()
	k.update(t, STEP)
	t.speed = 2.0  # Lost ~18 m/s in one frame.
	var events := k.update(t, STEP)
	assert_int(k.get_kudos()) \
		.override_failure_message("A crash reduces kudos").is_less(before)
	assert_int(_count_label(events, "CRASH")) \
		.override_failure_message("A crash reports a CRASH event").is_equal(1)
	var crash := _first_with_label(events, "CRASH")
	assert_bool(crash.is_penalty) \
		.override_failure_message("CRASH is flagged as a penalty").is_true()
	assert_int(crash.amount) \
		.override_failure_message("CRASH amount is negative").is_less(0)


func test_handbrake_stop_is_not_a_crash() -> void:
	# Slamming the handbrake locks the wheels and drops speed hard in one frame —
	# the same signature as an impact. With t.braking set, that must NOT register as
	# a crash (this is the bug where a handbrake slam fired the crash sound + shake).
	var k := _make()
	var t := _cruising()
	k.update(t, STEP)  # seed _prev_speed at 20 m/s
	# A hard handbrake decel: lose ~10 m/s in one frame (above the normal 6.0
	# threshold, below the 14.0 braking threshold) with braking commanded.
	t.speed = 10.0
	t.braking = true
	var events := k.update(t, STEP)
	assert_int(_count_label(events, "CRASH")) \
		.override_failure_message("a handbrake stop must not be scored as a crash").is_equal(0)


func test_hard_impact_while_braking_still_crashes() -> void:
	# Braking must not make the car invincible: a genuine high-speed collision
	# (a huge single-frame drop past the raised braking threshold) still crashes,
	# even if the driver happened to be on the brakes at the moment of impact.
	var k := _make()
	var t := _cruising()
	t.forward_speed = 30.0
	t.speed = 30.0
	k.update(t, STEP)  # seed _prev_speed at 30 m/s
	t.speed = 5.0      # lost 25 m/s in one frame = a real wall hit
	t.braking = true
	var events := k.update(t, STEP)
	assert_int(_count_label(events, "CRASH")) \
		.override_failure_message("a real impact still crashes even while braking").is_equal(1)


func test_moderate_stop_without_braking_still_crashes() -> void:
	# Guard the discriminator from the other side: the SAME moderate decel that a
	# handbrake produces, but with no braking commanded, is a genuine impact and
	# must still register (e.g. clipping something that stopped you without input).
	var k := _make()
	var t := _cruising()
	k.update(t, STEP)  # seed _prev_speed at 20 m/s
	t.speed = 10.0     # lose 10 m/s (> normal 6.0 threshold)
	t.braking = false
	var events := k.update(t, STEP)
	assert_int(_count_label(events, "CRASH")) \
		.override_failure_message("a hard decel with no braking input is still a crash").is_equal(1)


func test_offroad_bleeds_kudos() -> void:
	var k := _make()
	_bank_kudos(k, 2.0)
	var before := k.get_kudos()
	var t := _cruising()
	t.on_road = false  # Driving on grass at speed.
	t.slip_angle = 0.0
	_run(k, t, 1.0)
	assert_int(k.get_kudos()) \
		.override_failure_message("Driving off-road bleeds kudos over time") \
		.is_less(before)


func test_flip_penalises_once() -> void:
	var k := _make()
	_bank_kudos(k, 3.0)
	var before := k.get_kudos()
	var t := _cruising()
	t.uprightness = -0.8  # On its roof.
	t.slip_angle = 0.0
	var events := _run(k, t, 1.0)
	assert_int(_count_label(events, "FLIPPED")) \
		.override_failure_message("A sustained flip penalises exactly once, not per frame") \
		.is_equal(1)
	assert_int(k.get_kudos()) \
		.override_failure_message("A flip reduces kudos").is_less(before)


func test_spinout_penalises_once() -> void:
	var k := _make()
	_bank_kudos(k, 3.0)
	var before := k.get_kudos()
	var t := _cruising()
	t.yaw_rate = 4.0  # Spinning fast and uncommanded.
	t.slip_angle = 0.0
	var events := _run(k, t, 1.0)
	assert_int(_count_label(events, "SPIN OUT")) \
		.override_failure_message("A sustained spin penalises exactly once") \
		.is_equal(1)
	assert_int(k.get_kudos()) \
		.override_failure_message("A spin-out reduces kudos").is_less(before)


# ─── Combo multiplier ────────────────────────────────────────────────────────

func test_combo_grows_with_cool_moves() -> void:
	var k := _make()
	var t := _cruising()
	t.slip_angle = 0.6
	# First slide bumps the combo.
	_run(k, t, 0.3)
	var combo_after_first := k.get_combo()
	# Break the drift (straighten out) then drift again to bump the combo a second time.
	t.slip_angle = 0.0
	_run(k, t, 0.1)
	t.slip_angle = 0.6
	_run(k, t, 0.3)
	assert_float(k.get_combo()) \
		.override_failure_message("Stringing cool moves grows the combo multiplier") \
		.is_greater(combo_after_first)


func test_mistake_resets_combo() -> void:
	var k := _make()
	var t := _cruising()
	t.slip_angle = 0.6
	_run(k, t, 1.0)
	assert_float(k.get_combo()) \
		.override_failure_message("Drifting builds some combo first").is_greater(1.0)
	# Now flip the car: any hard mistake must reset the combo to x1.
	t.slip_angle = 0.0
	t.uprightness = -0.8
	k.update(t, STEP)
	assert_float(k.get_combo()) \
		.override_failure_message("A mistake resets the combo to x1").is_equal(1.0)


func test_combo_decays_after_timeout() -> void:
	var k := _make()
	var t := _cruising()
	t.slip_angle = 0.6
	_run(k, t, 1.0)
	assert_float(k.get_combo()) \
		.override_failure_message("Drifting builds combo").is_greater(1.0)
	# Coast cleanly (no cool moves) past the combo timeout; it should decay to x1.
	var idle := _cruising()
	idle.speed = 3.0  # Below scoring speed so nothing is earned.
	idle.forward_speed = 3.0
	_run(k, idle, k.combo_timeout + 0.5)
	assert_float(k.get_combo()) \
		.override_failure_message("The combo decays back to x1 after the idle timeout") \
		.is_equal(1.0)


func test_zero_delta_is_a_noop() -> void:
	var k := _make()
	var t := _cruising()
	t.slip_angle = 0.6
	var events := k.update(t, 0.0)
	assert_int(events.size()) \
		.override_failure_message("A zero-length frame does nothing").is_equal(0)
	assert_int(k.get_kudos()) \
		.override_failure_message("A zero-length frame earns no kudos").is_equal(0)
