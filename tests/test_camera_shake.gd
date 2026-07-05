extends GdUnitTestSuite

## Unit tests for the CameraShake trauma model.
##
## CameraShake is a pure logic helper (no camera node, no scene tree): callers
## add trauma on an event, tick it each frame, and read a small local-space
## offset to add on top of the follow camera. These tests pin the contract that
## future tuning must not silently break:
##
##   1. Resting state produces zero offset and reports inactive.
##   2. add_trauma accumulates and clamps to 1.0; negatives are ignored.
##   3. tick() decays trauma linearly toward zero and eventually settles.
##   4. Amplitude is non-linear (trauma^power) — the feel-good curve.
##   5. A non-zero shake produces a bounded, non-zero offset that fades with trauma.

const CameraShake := preload("res://scripts/camera_shake.gd")


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _make() -> CameraShake:
	return CameraShake.new()


# ─── Resting state ───────────────────────────────────────────────────────────

func test_starts_inactive_with_zero_offset() -> void:
	var s := _make()
	assert_bool(s.is_active()).override_failure_message("fresh shake is inactive").is_false()
	assert_float(s.trauma).override_failure_message("fresh trauma is zero").is_equal_approx(0.0, 0.0001)
	var off := s.get_offset()
	assert_vector(off["position"]).override_failure_message("no positional offset at rest") \
		.is_equal_approx(Vector3.ZERO, Vector3(0.0001, 0.0001, 0.0001))
	assert_vector(off["rotation"]).override_failure_message("no rotational offset at rest") \
		.is_equal_approx(Vector3.ZERO, Vector3(0.0001, 0.0001, 0.0001))


# ─── Trauma accumulation & clamping ──────────────────────────────────────────

func test_add_trauma_accumulates() -> void:
	var s := _make()
	s.add_trauma(0.3)
	s.add_trauma(0.2)
	assert_float(s.trauma).override_failure_message("trauma stacks additively").is_equal_approx(0.5, 0.0001)
	assert_bool(s.is_active()).override_failure_message("shake now active").is_true()


func test_add_trauma_clamps_to_one() -> void:
	var s := _make()
	s.add_trauma(0.8)
	s.add_trauma(0.8)
	assert_float(s.trauma).override_failure_message("trauma clamps at 1.0").is_equal_approx(1.0, 0.0001)


func test_negative_trauma_ignored() -> void:
	var s := _make()
	s.add_trauma(0.5)
	s.add_trauma(-0.3)
	assert_float(s.trauma).override_failure_message("negative add is a no-op").is_equal_approx(0.5, 0.0001)


# ─── Decay ───────────────────────────────────────────────────────────────────

func test_tick_decays_trauma() -> void:
	var s := _make()
	s.decay_rate = 1.0
	s.add_trauma(1.0)
	s.tick(0.25)
	assert_float(s.trauma).override_failure_message("0.25s at rate 1.0 removes 0.25 trauma") \
		.is_equal_approx(0.75, 0.0001)


func test_tick_settles_to_zero() -> void:
	var s := _make()
	s.decay_rate = 2.0
	s.add_trauma(0.5)
	# 0.5 trauma at rate 2.0 fully decays in 0.25s; a full second is plenty.
	s.tick(1.0)
	assert_float(s.trauma).override_failure_message("trauma bottoms out at zero, never negative") \
		.is_equal_approx(0.0, 0.0001)
	assert_bool(s.is_active()).override_failure_message("settled shake is inactive").is_false()


func test_zero_delta_does_not_decay() -> void:
	var s := _make()
	s.add_trauma(0.5)
	s.tick(0.0)
	assert_float(s.trauma).override_failure_message("a zero-length frame leaves trauma untouched") \
		.is_equal_approx(0.5, 0.0001)


# ─── Non-linear amplitude curve ──────────────────────────────────────────────

func test_amplitude_is_squared_by_default() -> void:
	var s := _make()
	s.trauma_power = 2.0
	s.add_trauma(0.5)
	# 0.5^2 = 0.25 — small trauma stays subtle, which is the whole point.
	assert_float(s.amplitude()).override_failure_message("amplitude = trauma^2") \
		.is_equal_approx(0.25, 0.0001)


func test_amplitude_grows_faster_than_trauma() -> void:
	var low := _make()
	low.add_trauma(0.25)
	var high := _make()
	high.add_trauma(0.75)
	# The ratio of amplitudes must exceed the ratio of traumas (non-linearity).
	var trauma_ratio := 0.75 / 0.25
	var amp_ratio := high.amplitude() / low.amplitude()
	assert_float(amp_ratio).override_failure_message("big hits slam harder than trauma alone") \
		.is_greater(trauma_ratio)


# ─── Offset behaviour ────────────────────────────────────────────────────────

func test_offset_nonzero_when_traumatised() -> void:
	var s := _make()
	s.add_trauma(1.0)
	# Advance a few frames so the noise clock moves off its zero crossing.
	var saw_motion := false
	for i: int in range(8):
		s.tick(0.016)
		var off := s.get_offset()
		if (off["position"] as Vector3).length() > 0.0001 \
				or (off["rotation"] as Vector3).length() > 0.0001:
			saw_motion = true
			break
	assert_bool(saw_motion).override_failure_message("a full-trauma shake moves the camera").is_true()


func test_offset_bounded_by_maxima() -> void:
	var s := _make()
	s.max_offset = 0.25
	s.max_roll = 0.06
	s.add_trauma(1.0)
	# At full trauma (amp 1.0) no axis may exceed its configured maximum.
	for i: int in range(200):
		s.tick(0.0)  # keep trauma pinned at 1.0 while sweeping the clock manually
		s._time += 0.05
		var off := s.get_offset()
		var p := off["position"] as Vector3
		var r := off["rotation"] as Vector3
		assert_float(absf(p.x)).is_less_equal(s.max_offset + 0.0001)
		assert_float(absf(p.y)).is_less_equal(s.max_offset + 0.0001)
		assert_float(absf(p.z)).is_less_equal(s.max_offset + 0.0001)
		assert_float(absf(r.z)).is_less_equal(s.max_roll + 0.0001)


func test_offset_shrinks_as_trauma_decays() -> void:
	# Isolate the trauma effect from the noise sweep: sample the SAME clock point
	# at two different trauma levels. Because the offset is noise * amplitude(trauma),
	# holding the clock fixed means only the trauma-driven amplitude changes, so the
	# lower-trauma sample must be strictly smaller.
	var s := _make()
	# Pick a clock point that is NOT on the noise lattice (Perlin returns ~0 at
	# integer coordinates, and time is sampled as _time * frequency).
	s._time = 5.37
	s.add_trauma(1.0)
	var high := (s.get_offset()["position"] as Vector3).length()
	assert_float(high).override_failure_message("full-trauma offset is non-zero here").is_greater(0.0)
	# Drop trauma without moving the clock.
	s.trauma = 0.4
	var low := (s.get_offset()["position"] as Vector3).length()
	assert_float(low).override_failure_message("offset magnitude falls with trauma") \
		.is_less(high)
