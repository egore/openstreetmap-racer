extends GdUnitTestSuite

## Unit tests for the Transmission gear-selection logic.
##
## Transmission is a pure data/logic helper (no physics body, no scene tree):
## given a signed forward speed and the car's max speed it answers "what gear am
## I in?". Because it owns the gear curve that drives both the HUD and (later)
## the sound system, these tests pin the contract that future tuning must not
## silently break:
##
##   1. Sign/threshold handling: reverse, the neutral dead-zone, and forward.
##   2. The geometric speed-band construction (each gear taller than the last,
##      6th gear topping out exactly at max_speed with no gaps or overlap).
##   3. Lazy rebuild when the car's max_speed is retuned at runtime.
##   4. The HUD label mapping ("R", "N", "1".."6").

const Transmission := preload("res://scripts/transmission.gd")

## A representative top speed (km/h) used across the band tests.
const MAX_SPEED := 200.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _make() -> Transmission:
	return Transmission.new()


# ─── Sign and threshold handling ─────────────────────────────────────────────

func test_reverse_when_speed_below_negative_threshold() -> void:
	var tx := _make()
	# At or beyond the negative threshold the car is in reverse.
	assert_int(tx.gear_for_speed(-tx.neutral_speed_threshold, MAX_SPEED)) \
		.override_failure_message("speed == -threshold -> reverse") \
		.is_equal(Transmission.GEAR_REVERSE)
	assert_int(tx.gear_for_speed(-50.0, MAX_SPEED)) \
		.override_failure_message("clearly negative speed -> reverse") \
		.is_equal(Transmission.GEAR_REVERSE)


func test_neutral_inside_dead_zone() -> void:
	var tx := _make()
	# |speed| strictly below the threshold is the neutral dead-zone so the HUD
	# shows "N" instead of flickering into 1st while stationary.
	assert_int(tx.gear_for_speed(0.0, MAX_SPEED)) \
		.override_failure_message("stationary -> neutral").is_equal(Transmission.GEAR_NEUTRAL)
	var just_under := tx.neutral_speed_threshold - 0.001
	assert_int(tx.gear_for_speed(just_under, MAX_SPEED)) \
		.override_failure_message("just below +threshold -> neutral") \
		.is_equal(Transmission.GEAR_NEUTRAL)
	assert_int(tx.gear_for_speed(-just_under, MAX_SPEED)) \
		.override_failure_message("just above -threshold -> neutral") \
		.is_equal(Transmission.GEAR_NEUTRAL)


func test_first_gear_at_threshold_boundary() -> void:
	var tx := _make()
	# The neutral test is `< threshold`, so reaching the threshold exactly is the
	# first forward gear (the dead-zone is half-open on the positive side).
	assert_int(tx.gear_for_speed(tx.neutral_speed_threshold, MAX_SPEED)) \
		.override_failure_message("speed == +threshold -> 1st gear").is_equal(1)


# ─── Forward gear bands ──────────────────────────────────────────────────────

func test_low_speed_is_first_gear() -> void:
	var tx := _make()
	# A crawl just above the dead-zone is unambiguously 1st gear.
	assert_int(tx.gear_for_speed(2.0, MAX_SPEED)) \
		.override_failure_message("2 km/h -> 1st gear").is_equal(1)


func test_top_speed_is_highest_gear() -> void:
	var tx := _make()
	assert_int(tx.gear_for_speed(MAX_SPEED, MAX_SPEED)) \
		.override_failure_message("at max speed -> top gear") \
		.is_equal(Transmission.FORWARD_GEAR_COUNT)


func test_above_top_speed_clamps_to_highest_gear() -> void:
	var tx := _make()
	# Overspeed (e.g. downhill) must not run off the band array; it clamps to top.
	assert_int(tx.gear_for_speed(MAX_SPEED * 2.0, MAX_SPEED)) \
		.override_failure_message("overspeed -> clamped to top gear") \
		.is_equal(Transmission.FORWARD_GEAR_COUNT)


func test_gears_increase_monotonically_with_speed() -> void:
	var tx := _make()
	# Sweeping speed from 0 to max must produce a non-decreasing gear sequence
	# that touches every forward gear and never skips one (contiguous bands).
	var last_gear := 0
	var seen := {}
	var speed := 0.0
	while speed <= MAX_SPEED:
		var gear := tx.gear_for_speed(speed, MAX_SPEED)
		assert_int(gear) \
			.override_failure_message("gear never decreases as speed rises (at %.1f km/h)" % speed) \
			.is_greater_equal(last_gear)
		last_gear = gear
		seen[gear] = true
		speed += 1.0
	# Every forward gear 1..N must appear somewhere in the sweep.
	for g in range(1, Transmission.FORWARD_GEAR_COUNT + 1):
		assert_bool(seen.has(g)) \
			.override_failure_message("gear %d is reachable in a 0->max sweep" % g).is_true()


func test_higher_gears_cover_wider_speed_bands() -> void:
	var tx := _make()
	# gear_spacing > 1.0 means each successive gear spans a wider speed band.
	# Measure each band width by counting the km/h range mapped to each gear.
	var widths := PackedFloat32Array()
	widths.resize(Transmission.FORWARD_GEAR_COUNT)
	var speed := tx.neutral_speed_threshold
	while speed <= MAX_SPEED:
		var gear := tx.gear_for_speed(speed, MAX_SPEED)
		if gear >= 1 and gear <= Transmission.FORWARD_GEAR_COUNT:
			widths[gear - 1] += 1.0
		speed += 0.5
	for i in range(1, Transmission.FORWARD_GEAR_COUNT):
		assert_float(widths[i]) \
			.override_failure_message("gear %d band is wider than gear %d" % [i + 1, i]) \
			.is_greater(widths[i - 1])


# ─── Lazy rebuild on max_speed change ────────────────────────────────────────

func test_rebuilds_when_max_speed_changes() -> void:
	var tx := _make()
	# Same speed should map to a higher gear when the top speed is lowered,
	# because the bands compress. This proves the lazy rebuild fired.
	var gear_fast := tx.gear_for_speed(100.0, 400.0)
	var gear_slow := tx.gear_for_speed(100.0, 120.0)
	assert_int(gear_slow) \
		.override_failure_message("100 km/h sits in a higher gear when max is lower") \
		.is_greater(gear_fast)


func test_build_for_max_speed_top_band_equals_max() -> void:
	var tx := _make()
	tx.build_for_max_speed(MAX_SPEED)
	# Exactly at max speed we must still be in the top gear (the final upshift
	# point lands on max_speed; no overflow into a non-existent 7th gear).
	assert_int(tx.gear_for_speed(MAX_SPEED, MAX_SPEED)) \
		.override_failure_message("top band upper bound == max_speed") \
		.is_equal(Transmission.FORWARD_GEAR_COUNT)


# ─── HUD labels ──────────────────────────────────────────────────────────────

func test_gear_label_special_indices() -> void:
	assert_str(Transmission.gear_label(Transmission.GEAR_REVERSE)) \
		.override_failure_message("reverse -> R").is_equal("R")
	assert_str(Transmission.gear_label(Transmission.GEAR_NEUTRAL)) \
		.override_failure_message("neutral -> N").is_equal("N")


func test_gear_label_forward_gears() -> void:
	for g in range(1, Transmission.FORWARD_GEAR_COUNT + 1):
		assert_str(Transmission.gear_label(g)) \
			.override_failure_message("gear %d -> \"%d\"" % [g, g]).is_equal(str(g))
