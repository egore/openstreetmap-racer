extends GdUnitTestSuite

## Unit tests for ImpactBurstSpec.
##
## ImpactBurstSpec is a pure logic helper (no GPUParticles3D, no scene tree): given
## a crash severity it answers how big the impact burst should be. These tests pin
## the mapping so future tuning can't silently break it:
##
##   1. Below min severity there is no burst.
##   2. Intensity is clamped to [0, 1] across the min..full band.
##   3. Particle count and speed scale with severity, bounded by the configured
##      min/max, and a qualifying tap always spawns at least min_count.

const ImpactBurstSpec := preload("res://scripts/impact_burst_spec.gd")


func _make() -> ImpactBurstSpec:
	return ImpactBurstSpec.new()


# ─── Gating ──────────────────────────────────────────────────────────────────

func test_no_burst_below_min_severity() -> void:
	var s := _make()
	assert_bool(s.should_burst(s.min_severity - 0.1)) \
		.override_failure_message("a negligible tap throws no sparks").is_false()


func test_burst_at_and_above_min_severity() -> void:
	var s := _make()
	assert_bool(s.should_burst(s.min_severity)) \
		.override_failure_message("a tap at the threshold bursts").is_true()
	assert_bool(s.should_burst(1000.0)) \
		.override_failure_message("a big hit bursts").is_true()


# ─── Intensity curve ─────────────────────────────────────────────────────────

func test_intensity_clamps_to_unit_range() -> void:
	var s := _make()
	assert_float(s.intensity(-100.0)).override_failure_message("clamps low to 0").is_equal_approx(0.0, 0.0001)
	assert_float(s.intensity(999.0)).override_failure_message("clamps high to 1").is_equal_approx(1.0, 0.0001)


func test_intensity_monotonic() -> void:
	var s := _make()
	var lo := s.intensity(20.0)
	var hi := s.intensity(100.0)
	assert_float(hi).override_failure_message("harder crash -> higher intensity").is_greater(lo)


# ─── Particle count ──────────────────────────────────────────────────────────

func test_particle_count_at_min_is_min_count() -> void:
	var s := _make()
	assert_int(s.particle_count(s.min_severity)) \
		.override_failure_message("a threshold tap spawns exactly min_count").is_equal(s.min_count)


func test_particle_count_saturates_at_max() -> void:
	var s := _make()
	assert_int(s.particle_count(10000.0)) \
		.override_failure_message("a huge crash spawns max_count").is_equal(s.max_count)


func test_particle_count_scales_between() -> void:
	var s := _make()
	var mid := s.particle_count((s.min_severity + s.full_severity) * 0.5)
	assert_int(mid).override_failure_message("mid crash is between min and max").is_greater(s.min_count)
	assert_int(mid).override_failure_message("mid crash is below max").is_less(s.max_count)


# ─── Burst speed ─────────────────────────────────────────────────────────────

func test_burst_speed_scales_with_severity() -> void:
	var s := _make()
	var slow := s.burst_speed(s.min_severity)
	var fast := s.burst_speed(s.full_severity)
	assert_float(slow).override_failure_message("min-severity speed is the floor").is_equal_approx(s.min_speed, 0.0001)
	assert_float(fast).override_failure_message("full-severity speed is the ceiling").is_equal_approx(s.max_speed, 0.0001)
	assert_float(fast).override_failure_message("harder crash throws debris faster").is_greater(slow)
