extends GdUnitTestSuite

## Unit tests for the DrivingAssists driver aids (TCS / ABS / stability control).
##
## DrivingAssists is a pure logic helper: it takes the throttle, brake and yaw the
## car was about to apply and hands back filtered versions. Because it sits between
## the player's input and the tyres, a sign error or a runaway gain here would make
## the car undriveable in ways that are hard to spot by eye — so these tests pin
## the safety-critical contracts:
##
##   1. An aid may only ever REDUCE force, never add to it.
##   2. Interventions scale with how far past the limit the car is, and are capped.
##   3. Stability control OPPOSES excess rotation (a sign error would amplify spins).
##   4. Every aid can be switched off and then does nothing at all.
##   5. The maths is safe at zero/near-zero speed, where slip ratio divides by ~0.

const DrivingAssists := preload("res://scripts/driving_assists.gd")

## A typical physics step (60 Hz).
const STEP := 1.0 / 60.0

## A representative engine force (N), matching the car's tuning.
const ENGINE_FORCE := 3200.0
## A representative brake force (N).
const BRAKE_FORCE := 65.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _make() -> DrivingAssists:
	return DrivingAssists.new()


## Run the throttle filter repeatedly so the smoothed intervention converges,
## and return the final filtered force.
func _settle_engine(
	a: DrivingAssists,
	force: float,
	wheel_speed: float,
	car_speed: float,
	frames: int = 120
) -> float:
	var out := force
	for _i in frames:
		out = a.filter_engine_force(force, wheel_speed, car_speed, STEP)
	return out


## Run the brake filter repeatedly so the smoothed intervention converges.
func _settle_brake(
	a: DrivingAssists,
	force: float,
	wheel_speed: float,
	car_speed: float,
	frames: int = 120
) -> float:
	var out := force
	for _i in frames:
		out = a.filter_brake_force(force, wheel_speed, car_speed, STEP)
	return out


# ─── Slip ratio ──────────────────────────────────────────────────────────────

func test_slip_ratio_zero_when_wheels_match_car() -> void:
	# Rolling without slipping: the tyre surface speed equals the road speed.
	assert_float(DrivingAssists.slip_ratio(20.0, 20.0)) \
		.override_failure_message("matched speeds -> no slip").is_equal_approx(0.0, 0.0001)


func test_slip_ratio_positive_on_wheelspin() -> void:
	# Wheels turning faster than the car is moving is wheelspin.
	assert_float(DrivingAssists.slip_ratio(30.0, 20.0)) \
		.override_failure_message("wheels outrunning the car -> positive slip") \
		.is_equal_approx(0.5, 0.0001)


func test_slip_ratio_negative_on_lockup() -> void:
	# Wheels turning slower than the car is moving is lock-up.
	assert_float(DrivingAssists.slip_ratio(10.0, 20.0)) \
		.override_failure_message("wheels lagging the car -> negative slip") \
		.is_equal_approx(-0.5, 0.0001)


func test_slip_ratio_survives_zero_speed() -> void:
	# The formula divides by speed, so a standstill must not produce INF/NAN.
	var slip := DrivingAssists.slip_ratio(0.0, 0.0)
	assert_bool(is_finite(slip)) \
		.override_failure_message("slip ratio stays finite at a standstill").is_true()


# ─── Traction control ────────────────────────────────────────────────────────

func test_tcs_leaves_gripping_throttle_alone() -> void:
	var a := _make()
	# Driving with the tyres hooked up: the aid must be completely invisible.
	var out := _settle_engine(a, ENGINE_FORCE, 20.0, 20.0)
	assert_float(out) \
		.override_failure_message("no wheelspin -> full throttle passes through") \
		.is_equal_approx(ENGINE_FORCE, 0.001)


func test_tcs_allows_useful_slip() -> void:
	var a := _make()
	# Peak tyre grip happens at a little slip, so intervening below the threshold
	# would make the car SLOWER, not safer.
	var slight := 20.0 * (1.0 + a.tcs_slip_threshold * 0.5)
	var out := _settle_engine(a, ENGINE_FORCE, slight, 20.0)
	assert_float(out) \
		.override_failure_message("slip below the threshold is left alone") \
		.is_equal_approx(ENGINE_FORCE, 0.001)


func test_tcs_cuts_throttle_on_wheelspin() -> void:
	var a := _make()
	# Wheels well past the slip threshold: power must come down.
	var spinning := 20.0 * (1.0 + a.tcs_slip_full)
	var out := _settle_engine(a, ENGINE_FORCE, spinning, 20.0)
	assert_float(out) \
		.override_failure_message("wheelspin cuts throttle").is_less(ENGINE_FORCE)


func test_tcs_cut_scales_with_slip() -> void:
	var mild := _make()
	var wild := _make()
	# More slip -> more intervention, so the aid is proportionate rather than binary.
	var mild_out := _settle_engine(
		mild, ENGINE_FORCE, 20.0 * (1.0 + mild.tcs_slip_threshold * 1.5), 20.0
	)
	var wild_out := _settle_engine(
		wild, ENGINE_FORCE, 20.0 * (1.0 + wild.tcs_slip_full), 20.0
	)
	assert_float(wild_out) \
		.override_failure_message("more wheelspin -> deeper cut").is_less(mild_out)


func test_tcs_never_cuts_all_power() -> void:
	var a := _make()
	# A total cut feels like the engine died (and makes burnouts impossible).
	var out := _settle_engine(a, ENGINE_FORCE, 20.0 * 10.0, 20.0)
	assert_float(out) \
		.override_failure_message("some drive always remains").is_greater(0.0)
	assert_float(out) \
		.override_failure_message("the cut is bounded by tcs_max_cut") \
		.is_greater_equal(ENGINE_FORCE * (1.0 - a.tcs_max_cut) - 0.001)


func test_tcs_never_increases_force() -> void:
	var a := _make()
	# An aid may only take away. This must hold at every slip level.
	for i in range(0, 20):
		var wheel_speed := 20.0 * (1.0 + float(i) * 0.1)
		var out := a.filter_engine_force(ENGINE_FORCE, wheel_speed, 20.0, STEP)
		assert_float(out) \
			.override_failure_message("TCS never adds power (slip step %d)" % i) \
			.is_less_equal(ENGINE_FORCE + 0.001)


func test_tcs_inactive_below_minimum_speed() -> void:
	var a := _make()
	# Pulling away always involves brief slip; punishing it would stall launches.
	var out := _settle_engine(a, ENGINE_FORCE, 20.0, a.tcs_min_speed - 0.1)
	assert_float(out) \
		.override_failure_message("TCS stays out at launch speeds") \
		.is_equal_approx(ENGINE_FORCE, 0.001)


func test_tcs_can_be_disabled() -> void:
	var a := _make()
	a.traction_control_enabled = false
	var out := _settle_engine(a, ENGINE_FORCE, 20.0 * 5.0, 20.0)
	assert_float(out) \
		.override_failure_message("disabled TCS passes throttle through untouched") \
		.is_equal_approx(ENGINE_FORCE, 0.001)


func test_tcs_intervention_decays_when_grip_returns() -> void:
	var a := _make()
	# Once the tyres hook up again the cut must fade out, or the car would stay
	# gutless after a single moment of wheelspin.
	_settle_engine(a, ENGINE_FORCE, 20.0 * 5.0, 20.0)
	assert_float(a.tcs_cut).override_failure_message("cut is engaged").is_greater(0.5)
	_settle_engine(a, ENGINE_FORCE, 20.0, 20.0)
	assert_float(a.tcs_cut) \
		.override_failure_message("cut releases when grip returns") \
		.is_equal_approx(0.0, 0.01)


func test_tcs_preserves_reverse_direction() -> void:
	var a := _make()
	# Reverse uses a negative engine force; the filter must scale it, never flip it.
	var out := a.filter_engine_force(-ENGINE_FORCE, -20.0 * 5.0, -20.0, STEP)
	assert_float(out) \
		.override_failure_message("reverse force stays negative").is_less(0.0)


# ─── ABS ─────────────────────────────────────────────────────────────────────

func test_abs_leaves_normal_braking_alone() -> void:
	var a := _make()
	# Braking with the wheels still rolling: no intervention.
	var out := _settle_brake(a, BRAKE_FORCE, 20.0, 20.0)
	assert_float(out) \
		.override_failure_message("rolling wheels -> full brake passes through") \
		.is_equal_approx(BRAKE_FORCE, 0.001)


func test_abs_releases_on_lockup() -> void:
	var a := _make()
	# Wheels dragging far slower than the car: release pressure so they spin again.
	var locked := 20.0 * (1.0 - a.abs_lock_full)
	var out := _settle_brake(a, BRAKE_FORCE, locked, 20.0)
	assert_float(out) \
		.override_failure_message("locking wheels release brake pressure") \
		.is_less(BRAKE_FORCE)


func test_abs_release_scales_with_lockup() -> void:
	var mild := _make()
	var full := _make()
	var mild_out := _settle_brake(
		mild, BRAKE_FORCE, 20.0 * (1.0 - mild.abs_lock_threshold * 1.5), 20.0
	)
	var full_out := _settle_brake(
		full, BRAKE_FORCE, 20.0 * (1.0 - full.abs_lock_full), 20.0
	)
	assert_float(full_out) \
		.override_failure_message("deeper lock-up -> more release").is_less(mild_out)


func test_abs_still_brakes() -> void:
	var a := _make()
	# ABS must not release so much that the car stops slowing down.
	var out := _settle_brake(a, BRAKE_FORCE, 0.0, 20.0)
	assert_float(out) \
		.override_failure_message("the car still brakes under ABS").is_greater(0.0)


func test_abs_never_increases_brake_force() -> void:
	var a := _make()
	for i in range(0, 20):
		var wheel_speed := 20.0 * (1.0 - float(i) * 0.05)
		var out := a.filter_brake_force(BRAKE_FORCE, wheel_speed, 20.0, STEP)
		assert_float(out) \
			.override_failure_message("ABS never adds brake force (step %d)" % i) \
			.is_less_equal(BRAKE_FORCE + 0.001)


func test_abs_inactive_below_minimum_speed() -> void:
	var a := _make()
	# At walking pace, locking the wheels is how the car comes to a stop and STAYS
	# stopped — real ABS disengages here for exactly this reason.
	var out := _settle_brake(a, BRAKE_FORCE, 0.0, a.abs_min_speed - 0.1)
	assert_float(out) \
		.override_failure_message("ABS releases control at a crawl so the car can stop") \
		.is_equal_approx(BRAKE_FORCE, 0.001)


func test_abs_can_be_disabled() -> void:
	var a := _make()
	a.abs_enabled = false
	var out := _settle_brake(a, BRAKE_FORCE, 0.0, 20.0)
	assert_float(out) \
		.override_failure_message("disabled ABS passes the brake through untouched") \
		.is_equal_approx(BRAKE_FORCE, 0.001)


# ─── Stability control ───────────────────────────────────────────────────────

func test_stability_quiet_when_car_follows_the_driver() -> void:
	var a := _make()
	# The car is rotating exactly as asked: no correction, so ordinary cornering
	# is completely untouched.
	var torque := a.stability_torque(1.0, 1.0, 20.0, false)
	assert_float(torque) \
		.override_failure_message("matched yaw -> no intervention") \
		.is_equal_approx(0.0, 0.0001)


func test_stability_allows_deadzone_deviation() -> void:
	var a := _make()
	# A little deviation is what makes a car feel alive; only real slides count.
	var torque := a.stability_torque(a.stability_yaw_deadzone * 0.9, 0.0, 20.0, false)
	assert_float(torque) \
		.override_failure_message("deviation inside the deadzone is allowed") \
		.is_equal_approx(0.0, 0.0001)


func test_stability_opposes_excess_rotation() -> void:
	var a := _make()
	# THE critical sign test: if this were backwards the aid would accelerate every
	# spin instead of catching it. Rotating faster than asked must produce torque
	# in the OPPOSITE direction.
	var spinning_positive := a.stability_torque(3.0, 0.0, 20.0, false)
	assert_float(spinning_positive) \
		.override_failure_message("over-rotation one way is corrected the other way") \
		.is_less(0.0)
	var spinning_negative := a.stability_torque(-3.0, 0.0, 20.0, false)
	assert_float(spinning_negative) \
		.override_failure_message("over-rotation the other way corrects back") \
		.is_greater(0.0)


func test_stability_corrects_understeer_too() -> void:
	var a := _make()
	# The driver asked for a lot of rotation and the car is not delivering
	# (understeer/push). The correction should nudge yaw UP toward the request.
	var torque := a.stability_torque(0.0, 3.0, 20.0, false)
	assert_float(torque) \
		.override_failure_message("understeer is nudged toward the driver's request") \
		.is_greater(0.0)


func test_stability_scales_with_error() -> void:
	var a := _make()
	var small := absf(a.stability_torque(a.stability_yaw_deadzone + 0.2, 0.0, 20.0, false))
	var large := absf(a.stability_torque(a.stability_yaw_deadzone + 1.0, 0.0, 20.0, false))
	assert_float(large) \
		.override_failure_message("a bigger slide gets a bigger correction").is_greater(small)


func test_stability_torque_is_capped() -> void:
	var a := _make()
	# A wild spin must not produce an absurd snap-back that throws the car the
	# other way — that would turn one mistake into a worse one.
	var torque := a.stability_torque(50.0, 0.0, 40.0, false)
	assert_float(absf(torque)) \
		.override_failure_message("correction is capped") \
		.is_less_equal(a.stability_max_torque + 0.001)


func test_stability_backs_off_under_handbrake() -> void:
	var a := _make()
	# The handbrake is an explicit "I want to slide" request, so the aid must
	# mostly get out of the way or drifting becomes impossible.
	var normal := absf(a.stability_torque(3.0, 0.0, 20.0, false))
	var drifting := absf(a.stability_torque(3.0, 0.0, 20.0, true))
	assert_float(drifting) \
		.override_failure_message("handbrake slides are barely corrected").is_less(normal)


func test_stability_still_present_under_handbrake() -> void:
	var a := _make()
	# ...but not zero, or a handbrake slide becomes uncatchable.
	var drifting := absf(a.stability_torque(3.0, 0.0, 20.0, true))
	assert_float(drifting) \
		.override_failure_message("some correction survives the handbrake").is_greater(0.0)


func test_stability_inactive_below_minimum_speed() -> void:
	var a := _make()
	# Donuts and low-speed manoeuvring must not be fought.
	var torque := a.stability_torque(5.0, 0.0, a.stability_min_speed - 0.1, false)
	assert_float(torque) \
		.override_failure_message("no stability control at low speed") \
		.is_equal_approx(0.0, 0.0001)


func test_stability_can_be_disabled() -> void:
	var a := _make()
	a.stability_control_enabled = false
	var torque := a.stability_torque(5.0, 0.0, 20.0, false)
	assert_float(torque) \
		.override_failure_message("disabled stability control does nothing") \
		.is_equal_approx(0.0, 0.0001)


func test_stability_reports_intervention_for_the_hud() -> void:
	var a := _make()
	a.stability_torque(3.0, 0.0, 20.0, false)
	assert_float(a.stability_intervention) \
		.override_failure_message("an intervention is reported for the telltale") \
		.is_greater(0.0)
	a.stability_torque(0.0, 0.0, 20.0, false)
	assert_float(a.stability_intervention) \
		.override_failure_message("the telltale clears when the car settles") \
		.is_equal_approx(0.0, 0.0001)


# ─── Global toggles and reset ────────────────────────────────────────────────

func test_set_all_enabled_switches_every_aid() -> void:
	var a := _make()
	a.set_all_enabled(false)
	assert_bool(a.traction_control_enabled) \
		.override_failure_message("TCS off").is_false()
	assert_bool(a.abs_enabled).override_failure_message("ABS off").is_false()
	assert_bool(a.stability_control_enabled) \
		.override_failure_message("stability off").is_false()
	a.set_all_enabled(true)
	assert_bool(a.traction_control_enabled) \
		.override_failure_message("TCS back on").is_true()


func test_all_aids_off_is_fully_transparent() -> void:
	var a := _make()
	a.set_all_enabled(false)
	# The "pro" preset: inputs must reach the tyres completely unmodified.
	var engine := _settle_engine(a, ENGINE_FORCE, 20.0 * 5.0, 20.0)
	var brake := _settle_brake(a, BRAKE_FORCE, 0.0, 20.0)
	var torque := a.stability_torque(5.0, 0.0, 20.0, false)
	assert_float(engine) \
		.override_failure_message("throttle untouched").is_equal_approx(ENGINE_FORCE, 0.001)
	assert_float(brake) \
		.override_failure_message("brake untouched").is_equal_approx(BRAKE_FORCE, 0.001)
	assert_float(torque) \
		.override_failure_message("no corrective torque").is_equal_approx(0.0, 0.0001)


func test_reset_clears_intervention_state() -> void:
	var a := _make()
	_settle_engine(a, ENGINE_FORCE, 20.0 * 5.0, 20.0)
	_settle_brake(a, BRAKE_FORCE, 0.0, 20.0)
	a.stability_torque(3.0, 0.0, 20.0, false)
	a.reset()
	assert_float(a.tcs_cut).override_failure_message("TCS cleared").is_equal_approx(0.0, 0.0001)
	assert_float(a.abs_release) \
		.override_failure_message("ABS cleared").is_equal_approx(0.0, 0.0001)
	assert_float(a.stability_intervention) \
		.override_failure_message("stability cleared").is_equal_approx(0.0, 0.0001)
