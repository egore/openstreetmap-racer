extends GdUnitTestSuite

## Unit tests for the SteeringModel steering rack.
##
## SteeringModel is a pure logic helper (no physics body, no scene tree): given the
## driver's steering input and the chassis state it answers "what angle are the
## front wheels actually at?". It owns the three things that separate a car that
## feels weighted from one that feels like an RC toy, so these tests pin each:
##
##   1. Rate limiting — the wheels ramp toward the target instead of snapping, and
##      unwind to centre faster than they wind on.
##   2. Speed sensitivity — full lock when parking, a sliver of it at top speed.
##   3. Countersteer assist — steers into a slide, scales with slip, and yields to
##      a driver who is already correcting.
##
## Sign convention throughout: positive = LEFT, negative = RIGHT, angles radians.

const SteeringModel := preload("res://scripts/steering_model.gd")

## A typical physics step (60 Hz), used for stepping the rack in tests.
const STEP := 1.0 / 60.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _make() -> SteeringModel:
	return SteeringModel.new()


## Step the model repeatedly with a constant input, to let the rate-limited rack
## converge. Returns the final angle.
func _hold(
	m: SteeringModel,
	input: float,
	speed: float,
	frames: int,
	slip_angle: float = 0.0,
	slip_sign: float = 0.0
) -> float:
	var angle := 0.0
	for _i in frames:
		angle = m.update(input, speed, slip_angle, slip_sign, STEP)
	return angle


# ─── Rate limiting ───────────────────────────────────────────────────────────

func test_starts_centred() -> void:
	var m := _make()
	assert_float(m.steer_angle) \
		.override_failure_message("a fresh rack sits at centre").is_equal_approx(0.0, 0.0001)


func test_single_frame_cannot_reach_full_lock() -> void:
	var m := _make()
	# The whole point of the rack: one frame of full input must NOT teleport the
	# wheels to full lock the way `steering = input * max_angle` did.
	var after_one := m.update(1.0, 0.0, 0.0, 0.0, STEP)
	assert_float(after_one) \
		.override_failure_message("one frame must not reach full lock") \
		.is_less(m.max_steer_angle)
	# It should have moved by no more than the rack's rated speed.
	assert_float(after_one) \
		.override_failure_message("movement is bounded by steer_rate") \
		.is_less_equal(m.steer_rate * STEP + 0.0001)


func test_converges_to_full_lock_when_held() -> void:
	var m := _make()
	# Held long enough, the rack still reaches the full angle available at 0 m/s.
	var angle := _hold(m, 1.0, 0.0, 120)
	assert_float(angle) \
		.override_failure_message("holding full input reaches full lock") \
		.is_equal_approx(m.max_steer_angle, 0.001)


func test_steering_is_progressive_over_frames() -> void:
	var m := _make()
	# Each successive frame of held input gets closer to lock — a visible ramp,
	# which is what reads as "weight" in the steering.
	var a1 := m.update(1.0, 0.0, 0.0, 0.0, STEP)
	var a2 := m.update(1.0, 0.0, 0.0, 0.0, STEP)
	var a3 := m.update(1.0, 0.0, 0.0, 0.0, STEP)
	assert_float(a2).override_failure_message("frame 2 turns further than 1").is_greater(a1)
	assert_float(a3).override_failure_message("frame 3 turns further than 2").is_greater(a2)


func test_returns_to_centre_when_input_released() -> void:
	var m := _make()
	_hold(m, 1.0, 0.0, 120)
	assert_float(m.steer_angle).override_failure_message("locked over first").is_greater(0.1)
	var centred := _hold(m, 0.0, 0.0, 120)
	assert_float(centred) \
		.override_failure_message("releasing input returns the wheels to centre") \
		.is_equal_approx(0.0, 0.001)


func test_return_to_centre_is_faster_than_winding_on() -> void:
	var m := _make()
	# Caster self-centring: unwinding should be quicker than winding on, which is
	# both realistic and what stops the car feeling sluggish when you let go.
	#
	# The rack must first be wound well away from centre: released from only one
	# frame's worth of angle it would reach centre within a single frame and both
	# rates would clip to the same distance, proving nothing.
	var wind_on := m.update(1.0, 0.0, 0.0, 0.0, STEP)
	_hold(m, 1.0, 0.0, 20)
	var before_release := m.steer_angle
	var after_release := m.update(0.0, 0.0, 0.0, 0.0, STEP)
	var unwound := before_release - after_release
	assert_float(unwound) \
		.override_failure_message("unwinding is faster than winding on") \
		.is_greater(wind_on)


func test_steering_right_is_negative() -> void:
	var m := _make()
	var angle := _hold(m, -1.0, 0.0, 120)
	assert_float(angle) \
		.override_failure_message("negative input steers right (negative angle)") \
		.is_equal_approx(-m.max_steer_angle, 0.001)


func test_partial_analog_input_gives_partial_lock() -> void:
	var m := _make()
	# The payoff of gamepad support: half deflection must settle at half lock,
	# not the full lock a digital key would produce.
	var half := _hold(m, 0.5, 0.0, 120)
	assert_float(half) \
		.override_failure_message("half input settles at half lock") \
		.is_equal_approx(m.max_steer_angle * 0.5, 0.001)


func test_zero_delta_does_not_move_the_rack() -> void:
	var m := _make()
	# A paused frame must not advance the steering.
	m.update(1.0, 0.0, 0.0, 0.0, 0.0)
	assert_float(m.steer_angle) \
		.override_failure_message("zero delta leaves the rack untouched") \
		.is_equal_approx(0.0, 0.0001)


func test_input_is_clamped_beyond_unit_range() -> void:
	var m := _make()
	# An out-of-range input (a mis-scaled controller axis) must not exceed lock.
	var angle := _hold(m, 5.0, 0.0, 200)
	assert_float(angle) \
		.override_failure_message("over-range input still clamps to full lock") \
		.is_equal_approx(m.max_steer_angle, 0.001)


# ─── Speed sensitivity ───────────────────────────────────────────────────────

func test_full_lock_available_at_standstill() -> void:
	var m := _make()
	assert_float(m.angle_limit_for_speed(0.0)) \
		.override_failure_message("parking speed gives the full rack") \
		.is_equal_approx(m.max_steer_angle, 0.0001)


func test_lock_collapses_to_minimum_at_high_speed() -> void:
	var m := _make()
	assert_float(m.angle_limit_for_speed(m.speed_sensitivity_full)) \
		.override_failure_message("at the sensitivity ceiling only min lock remains") \
		.is_equal_approx(m.min_steer_angle, 0.0001)
	# And it does not keep shrinking past the ceiling.
	assert_float(m.angle_limit_for_speed(m.speed_sensitivity_full * 3.0)) \
		.override_failure_message("beyond the ceiling the limit holds at minimum") \
		.is_equal_approx(m.min_steer_angle, 0.0001)


func test_lock_decreases_monotonically_with_speed() -> void:
	var m := _make()
	# No speed should ever give MORE lock than a slower one, or the car would gain
	# turn-in as it accelerated, which feels wrong and is dangerous to drive.
	var previous := m.angle_limit_for_speed(0.0)
	for i in range(1, 60):
		var speed := float(i)
		var limit := m.angle_limit_for_speed(speed)
		assert_float(limit) \
			.override_failure_message("lock must not grow with speed (at %.0f m/s)" % speed) \
			.is_less_equal(previous + 0.0001)
		previous = limit


func test_lock_never_reaches_zero() -> void:
	var m := _make()
	# There must always be enough authority to change lanes at top speed.
	assert_float(m.angle_limit_for_speed(200.0)) \
		.override_failure_message("some steering authority always remains") \
		.is_greater(0.0)


func test_speed_limits_the_settled_angle() -> void:
	var m := _make()
	# Holding full input at speed settles at the speed-limited angle, not full lock.
	var fast := _hold(m, 1.0, m.speed_sensitivity_full, 200)
	assert_float(fast) \
		.override_failure_message("at speed, full input is capped by the taper") \
		.is_equal_approx(m.min_steer_angle, 0.001)


func test_negative_speed_uses_magnitude() -> void:
	var m := _make()
	# Reversing quickly should taper the same as driving forward quickly, rather
	# than reading as "negative speed" and handing back full lock.
	assert_float(m.angle_limit_for_speed(-30.0)) \
		.override_failure_message("taper uses speed magnitude") \
		.is_equal_approx(m.angle_limit_for_speed(30.0), 0.0001)


# ─── Countersteer assist ─────────────────────────────────────────────────────

func test_no_assist_when_driving_straight() -> void:
	var m := _make()
	# Zero slip means nothing to correct; the assist must stay completely out.
	m.update(0.0, 20.0, 0.0, 0.0, STEP)
	assert_float(m.assist_angle) \
		.override_failure_message("no slip -> no assist").is_equal_approx(0.0, 0.0001)


func test_no_assist_below_slip_threshold() -> void:
	var m := _make()
	# Ordinary cornering slip must not trigger help, or the car would feel like it
	# is steering itself through every bend.
	var assist := m.countersteer_for(
		m.countersteer_threshold * 0.5, 1.0, 20.0, 0.0, m.max_steer_angle
	)
	assert_float(assist) \
		.override_failure_message("slip below threshold -> no assist") \
		.is_equal_approx(0.0, 0.0001)


func test_no_assist_below_minimum_speed() -> void:
	var m := _make()
	# Slip is noise at a crawl; assisting there would fight low-speed manoeuvring.
	var assist := m.countersteer_for(
		0.5, 1.0, m.countersteer_min_speed - 0.1, 0.0, m.max_steer_angle
	)
	assert_float(assist) \
		.override_failure_message("too slow -> no assist").is_equal_approx(0.0, 0.0001)


func test_assist_steers_into_the_slide() -> void:
	var m := _make()
	# The defining behaviour: a slide to one side produces steering to that SAME
	# side (steering into the slide), not against it. Getting this sign backwards
	# would actively spin the car, so it is the most important assertion here.
	var sliding_left := m.countersteer_for(0.5, 1.0, 20.0, 0.0, m.max_steer_angle)
	assert_float(sliding_left) \
		.override_failure_message("sliding one way steers that way").is_greater(0.0)
	var sliding_right := m.countersteer_for(0.5, -1.0, 20.0, 0.0, m.max_steer_angle)
	assert_float(sliding_right) \
		.override_failure_message("sliding the other way steers the other way") \
		.is_less(0.0)


func test_assist_scales_with_slip_angle() -> void:
	var m := _make()
	# A bigger slide earns a bigger correction, so the help is proportionate.
	var small := m.countersteer_for(0.25, 1.0, 20.0, 0.0, m.max_steer_angle)
	var large := m.countersteer_for(0.6, 1.0, 20.0, 0.0, m.max_steer_angle)
	assert_float(large) \
		.override_failure_message("a bigger slide gets more assist").is_greater(small)


func test_assist_is_capped() -> void:
	var m := _make()
	# Even a fully sideways car must not get more than the configured maximum,
	# so the assist can never drive the car somewhere the player did not ask.
	var extreme := m.countersteer_for(3.0, 1.0, 60.0, 0.0, m.max_steer_angle)
	assert_float(absf(extreme)) \
		.override_failure_message("assist is capped at countersteer_max") \
		.is_less_equal(m.countersteer_max + 0.0001)


func test_assist_yields_when_player_already_correcting() -> void:
	var m := _make()
	# If the driver is already countersteering, the assist must back off rather
	# than stack on top — otherwise the car over-rotates the other way and feels
	# like it is fighting your hands.
	var unassisted_player := m.countersteer_for(0.5, 1.0, 20.0, 0.0, m.max_steer_angle)
	var correcting_player := m.countersteer_for(0.5, 1.0, 20.0, 1.0, m.max_steer_angle)
	assert_float(correcting_player) \
		.override_failure_message("assist backs off when the driver corrects") \
		.is_less(unassisted_player)


func test_assist_does_not_yield_to_opposite_steering() -> void:
	var m := _make()
	# Steering AWAY from the slide (deepening it, e.g. deliberately extending a
	# drift) is not "already correcting", so the assist should not treat it as such.
	var neutral := m.countersteer_for(0.5, 1.0, 20.0, 0.0, m.max_steer_angle)
	var opposite := m.countersteer_for(0.5, 1.0, 20.0, -1.0, m.max_steer_angle)
	assert_float(opposite) \
		.override_failure_message("opposite steering does not reduce the assist") \
		.is_equal_approx(neutral, 0.0001)


func test_zero_slip_sign_disables_assist() -> void:
	var m := _make()
	# The car passes 0 when the slide direction is meaningless (crawling, or
	# reversing). That must fully disable the assist regardless of slip angle.
	var assist := m.countersteer_for(1.0, 0.0, 30.0, 0.0, m.max_steer_angle)
	assert_float(assist) \
		.override_failure_message("no slide direction -> no assist") \
		.is_equal_approx(0.0, 0.0001)


func test_assist_is_rate_limited_like_normal_steering() -> void:
	var m := _make()
	# The assist moves the rack, it does not teleport the wheels: a single frame of
	# a big slide must still respect the rate limit.
	var after_one := m.update(0.0, 20.0, 1.0, 1.0, STEP)
	assert_float(absf(after_one)) \
		.override_failure_message("assist obeys the rack's rate limit") \
		.is_less_equal(m.steer_rate * STEP + 0.0001)


func test_assist_respects_speed_limited_lock() -> void:
	var m := _make()
	# The assist must not sneak past the speed taper and apply an angle the driver
	# could not have requested at that speed.
	var limit := m.angle_limit_for_speed(m.speed_sensitivity_full)
	var angle := _hold(m, 1.0, m.speed_sensitivity_full, 200, 1.0, 1.0)
	assert_float(absf(angle)) \
		.override_failure_message("assisted angle stays within the speed-limited lock") \
		.is_less_equal(limit + 0.0001)


func test_disabling_assist_via_zero_max() -> void:
	var m := _make()
	# countersteer_max = 0 is the documented way to switch the aid off entirely.
	m.countersteer_max = 0.0
	var assist := m.countersteer_for(1.0, 1.0, 30.0, 0.0, m.max_steer_angle)
	assert_float(assist) \
		.override_failure_message("zero max disables the assist").is_equal_approx(0.0, 0.0001)


# ─── Reset ───────────────────────────────────────────────────────────────────

func test_reset_returns_to_centre() -> void:
	var m := _make()
	_hold(m, 1.0, 10.0, 60, 0.5, 1.0)
	m.reset()
	assert_float(m.steer_angle) \
		.override_failure_message("reset centres the rack").is_equal_approx(0.0, 0.0001)
	assert_float(m.assist_angle) \
		.override_failure_message("reset clears the assist").is_equal_approx(0.0, 0.0001)
