extends GdUnitTestSuite

## Unit tests for the TachometerModel rev-counter logic.
##
## TachometerModel is a pure logic helper (no Control, no viewport): given a gear
## and how far through its speed band the car is, it answers "what revs is the
## engine showing, and should the shift light be on?". These tests pin the
## contracts the dial's readability depends on:
##
##   1. Revs sweep up within a gear and drop on an upshift (the characteristic
##      sawtooth that makes a tacho readable at a glance).
##   2. The needle is smoothed, so a shift is a quick sweep rather than a teleport.
##   3. Idle/neutral/reverse are handled sanely — a running engine never shows 0.
##   4. The redline reports correctly, since it is the game's shift cue.
##   5. The dial geometry maps 0..max RPM onto the sweep without drifting off it.

const TachometerModel := preload("res://scripts/tachometer_model.gd")
const Transmission := preload("res://scripts/transmission.gd")

## A typical physics step (60 Hz).
const STEP := 1.0 / 60.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _make() -> TachometerModel:
	return TachometerModel.new()


## Step the model until the smoothed needle settles on its target.
func _settle(
	m: TachometerModel, gear: int, ratio: float, speed_kmh: float, frames: int = 200
) -> float:
	var rpm := 0.0
	for _i in frames:
		rpm = m.update(gear, ratio, speed_kmh, STEP)
	return rpm


# ─── Rev mapping within a gear ───────────────────────────────────────────────

func test_revs_rise_through_a_gear() -> void:
	var m := _make()
	# The defining behaviour: within one gear, more speed means more revs.
	var low := m.rpm_for(3, 0.0, 60.0)
	var mid := m.rpm_for(3, 0.5, 80.0)
	var high := m.rpm_for(3, 1.0, 100.0)
	assert_float(mid).override_failure_message("revs rise through the gear").is_greater(low)
	assert_float(high).override_failure_message("revs keep rising to the top").is_greater(mid)


func test_top_of_gear_reaches_max_rpm() -> void:
	var m := _make()
	# The top of a band is the moment before the upshift, i.e. the limiter.
	assert_float(m.rpm_for(4, 1.0, 120.0)) \
		.override_failure_message("the top of a gear is max revs") \
		.is_equal_approx(m.max_rpm, 0.001)


func test_upshift_drops_the_revs() -> void:
	var m := _make()
	# The sawtooth: the top of one gear must show more revs than the bottom of the
	# next. Without this the dial would read as a meaningless speed proxy.
	var before_shift := m.rpm_for(3, 1.0, 100.0)
	var after_shift := m.rpm_for(4, 0.0, 100.0)
	assert_float(after_shift) \
		.override_failure_message("an upshift drops the revs").is_less(before_shift)


func test_revs_never_fall_below_idle() -> void:
	var m := _make()
	# A running engine is always turning, so the bottom of a gear still shows revs.
	assert_float(m.rpm_for(1, 0.0, 5.0)) \
		.override_failure_message("even the bottom of 1st is above idle") \
		.is_greater_equal(m.idle_rpm)


func test_every_gear_bottom_is_above_idle() -> void:
	var m := _make()
	# The clutch re-engages with the wheels turning, so revs are dragged up to road
	# speed rather than dropping to idle on every shift.
	for gear in range(1, Transmission.FORWARD_GEAR_COUNT + 1):
		assert_float(m.rpm_for(gear, 0.0, 50.0)) \
			.override_failure_message("gear %d does not drop to idle" % gear) \
			.is_greater(m.idle_rpm)


func test_gear_ratio_is_clamped() -> void:
	var m := _make()
	# An out-of-range band position must not drive the needle off the dial.
	assert_float(m.rpm_for(3, 5.0, 100.0)) \
		.override_failure_message("over-range ratio clamps to max revs") \
		.is_equal_approx(m.max_rpm, 0.001)
	assert_float(m.rpm_for(3, -5.0, 100.0)) \
		.override_failure_message("under-range ratio clamps to the gear's bottom") \
		.is_greater_equal(m.idle_rpm)


# ─── Neutral and reverse ─────────────────────────────────────────────────────

func test_neutral_idles() -> void:
	var m := _make()
	# In neutral the engine is disconnected from the wheels, so it idles no matter
	# how fast the car happens to be rolling.
	assert_float(m.rpm_for(Transmission.GEAR_NEUTRAL, 0.0, 0.0)) \
		.override_failure_message("stationary in neutral idles") \
		.is_equal_approx(m.idle_rpm, 0.001)
	assert_float(m.rpm_for(Transmission.GEAR_NEUTRAL, 0.8, 90.0)) \
		.override_failure_message("coasting in neutral still idles") \
		.is_equal_approx(m.idle_rpm, 0.001)


func test_reverse_revs_with_speed() -> void:
	var m := _make()
	# Transmission leaves gear_ratio at 0 in reverse, so the model must derive the
	# sweep from speed instead — otherwise reversing would sit stuck at idle.
	var slow := m.rpm_for(Transmission.GEAR_REVERSE, 0.0, 2.0)
	var fast := m.rpm_for(Transmission.GEAR_REVERSE, 0.0, 25.0)
	assert_float(fast) \
		.override_failure_message("reversing faster shows more revs").is_greater(slow)


func test_reverse_is_capped_at_max_rpm() -> void:
	var m := _make()
	# Reverse is a short gear; it must still not exceed the dial.
	assert_float(m.rpm_for(Transmission.GEAR_REVERSE, 0.0, 500.0)) \
		.override_failure_message("reverse revs stay on the dial") \
		.is_less_equal(m.max_rpm + 0.001)


func test_reverse_uses_speed_magnitude() -> void:
	var m := _make()
	# Reverse speed arrives negative from the car; the dial must not read that as
	# "below idle".
	assert_float(m.rpm_for(Transmission.GEAR_REVERSE, 0.0, -20.0)) \
		.override_failure_message("negative reverse speed reads as revs") \
		.is_greater(m.idle_rpm)


# ─── Needle smoothing ────────────────────────────────────────────────────────

func test_needle_does_not_jump_in_one_frame() -> void:
	var m := _make()
	# A real needle has mass. One frame must not carry it all the way to the target,
	# or a gear change would look like a glitch rather than a sweep.
	var after_one := m.update(6, 1.0, 200.0, STEP)
	assert_float(after_one) \
		.override_failure_message("the needle eases toward its target") \
		.is_less(m.target_rpm)


func test_needle_converges_on_the_target() -> void:
	var m := _make()
	# Given time, the needle must actually arrive, not stall short of the target.
	var settled := _settle(m, 4, 0.5, 110.0)
	assert_float(settled) \
		.override_failure_message("the needle reaches its target") \
		.is_equal_approx(m.target_rpm, 1.0)


func test_needle_sweeps_down_after_an_upshift() -> void:
	var m := _make()
	# Wind up to the limiter in 3rd, then shift: the needle must fall.
	_settle(m, 3, 1.0, 100.0)
	var before := m.display_rpm
	m.update(4, 0.0, 100.0, STEP)
	assert_float(m.display_rpm) \
		.override_failure_message("the needle drops on an upshift").is_less(before)


func test_zero_delta_holds_the_needle() -> void:
	var m := _make()
	_settle(m, 3, 0.5, 90.0)
	var held := m.display_rpm
	m.update(6, 1.0, 200.0, 0.0)
	assert_float(m.display_rpm) \
		.override_failure_message("a paused frame does not move the needle") \
		.is_equal_approx(held, 0.001)


# ─── Dial geometry ───────────────────────────────────────────────────────────

func test_needle_fraction_spans_zero_to_one() -> void:
	var m := _make()
	m.display_rpm = 0.0
	assert_float(m.needle_fraction()) \
		.override_failure_message("no revs sits at the start of the sweep") \
		.is_equal_approx(0.0, 0.0001)
	m.display_rpm = m.max_rpm
	assert_float(m.needle_fraction()) \
		.override_failure_message("max revs sits at the end of the sweep") \
		.is_equal_approx(1.0, 0.0001)


func test_needle_fraction_is_clamped_to_the_dial() -> void:
	var m := _make()
	# Even past the limiter the needle must stay on the face.
	m.display_rpm = m.max_rpm * 3.0
	assert_float(m.needle_fraction()) \
		.override_failure_message("the needle never leaves the dial") \
		.is_equal_approx(1.0, 0.0001)


func test_angle_spans_the_configured_sweep() -> void:
	var m := _make()
	assert_float(m.angle_for_fraction(0.0)) \
		.override_failure_message("zero maps to the dial's start") \
		.is_equal_approx(m.dial_start, 0.0001)
	assert_float(m.angle_for_fraction(1.0)) \
		.override_failure_message("full maps to the end of the sweep") \
		.is_equal_approx(m.dial_start + m.dial_sweep, 0.0001)


func test_angle_increases_monotonically() -> void:
	var m := _make()
	# The needle must always travel one way round the dial as revs rise.
	var previous := m.angle_for_fraction(0.0)
	for i in range(1, 21):
		var angle := m.angle_for_fraction(float(i) / 20.0)
		assert_float(angle) \
			.override_failure_message("the needle sweeps one way (step %d)" % i) \
			.is_greater(previous)
		previous = angle


# ─── Redline ─────────────────────────────────────────────────────────────────

func test_not_redlining_at_idle() -> void:
	var m := _make()
	m.display_rpm = m.idle_rpm
	assert_bool(m.is_redlining()) \
		.override_failure_message("idling is not redlining").is_false()


func test_redlining_at_the_limiter() -> void:
	var m := _make()
	m.display_rpm = m.max_rpm
	assert_bool(m.is_redlining()) \
		.override_failure_message("the limiter is the red zone").is_true()


func test_redline_boundary() -> void:
	var m := _make()
	# Exactly at the redline counts as redlining (the shift cue should be on).
	m.display_rpm = m.redline_rpm
	assert_bool(m.is_redlining()) \
		.override_failure_message("the redline itself counts").is_true()
	m.display_rpm = m.redline_rpm - 1.0
	assert_bool(m.is_redlining()) \
		.override_failure_message("just below the redline does not").is_false()


func test_redline_intensity_ramps() -> void:
	var m := _make()
	# The shift light builds rather than flicking on, so the warning has lead time.
	m.display_rpm = m.redline_rpm
	assert_float(m.redline_intensity()) \
		.override_failure_message("intensity starts at zero on the boundary") \
		.is_equal_approx(0.0, 0.001)
	m.display_rpm = (m.redline_rpm + m.max_rpm) * 0.5
	var half := m.redline_intensity()
	assert_float(half).override_failure_message("intensity ramps up").is_greater(0.0)
	assert_float(half).override_failure_message("and is not yet full").is_less(1.0)
	m.display_rpm = m.max_rpm
	assert_float(m.redline_intensity()) \
		.override_failure_message("intensity is full at the limiter") \
		.is_equal_approx(1.0, 0.001)


func test_redline_intensity_is_clamped() -> void:
	var m := _make()
	m.display_rpm = m.max_rpm * 5.0
	assert_float(m.redline_intensity()) \
		.override_failure_message("intensity never exceeds full") \
		.is_less_equal(1.0)


func test_redline_fraction_sits_inside_the_sweep() -> void:
	var m := _make()
	var fraction := m.redline_fraction()
	assert_float(fraction) \
		.override_failure_message("the red zone starts on the dial").is_greater(0.0)
	assert_float(fraction) \
		.override_failure_message("and ends within it").is_less_equal(1.0)


func test_driving_normally_does_not_redline() -> void:
	var m := _make()
	# Mid-gear cruising must not sit permanently on the shift light, or the cue
	# becomes meaningless.
	_settle(m, 4, 0.4, 110.0)
	assert_bool(m.is_redlining()) \
		.override_failure_message("mid-gear cruising is not redlining").is_false()


func test_holding_a_gear_to_the_top_redlines() -> void:
	var m := _make()
	# ...but pinning a gear must light it, which is the whole point.
	_settle(m, 4, 1.0, 130.0)
	assert_bool(m.is_redlining()) \
		.override_failure_message("holding a gear to the top redlines").is_true()


# ─── Reset ───────────────────────────────────────────────────────────────────

func test_reset_returns_the_needle_to_rest() -> void:
	var m := _make()
	_settle(m, 5, 0.9, 160.0)
	m.reset()
	assert_float(m.display_rpm) \
		.override_failure_message("reset drops the needle to rest") \
		.is_equal_approx(0.0, 0.0001)
	assert_float(m.target_rpm) \
		.override_failure_message("reset clears the target").is_equal_approx(0.0, 0.0001)
