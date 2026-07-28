extends GdUnitTestSuite

## Tests for the SpeedBlur overlay.
##
## The shader itself cannot be asserted on without a GPU and a rendered frame, so
## these tests cover the part that decides what the shader is told to do: the
## speed→strength curve, its smoothing, and the node's placement contract.
##
## The placement assertions matter as much as the curve. This node is a
## full-screen overlay; if it accepted mouse input it would silently swallow every
## click meant for the pause menu underneath it, which is the kind of bug that is
## very hard to trace back to a cosmetic effect.

const SpeedBlurScript := preload("res://scripts/speed_blur.gd")

const STEP := 1.0 / 60.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _make() -> SpeedBlur:
	var blur: SpeedBlur = SpeedBlurScript.new()
	add_child(blur)
	auto_free(blur)
	return blur


## Feed a constant speed until the smoothed strength settles.
func _settle(blur: SpeedBlur, speed_kmh: float, frames: int = 300) -> float:
	for _i in frames:
		blur.update_speed(speed_kmh, STEP)
	return blur.get_strength()


# ─── The speed curve ─────────────────────────────────────────────────────────

func test_no_blur_when_stationary() -> void:
	var blur := _make()
	assert_float(blur.strength_for_speed(0.0)) \
		.override_failure_message("a parked car is perfectly sharp") \
		.is_equal_approx(0.0, 0.0001)


func test_no_blur_at_town_speeds() -> void:
	var blur := _make()
	# The effect is a high-speed reward, not a permanent filter over the game.
	assert_float(blur.strength_for_speed(blur.start_speed_kmh - 1.0)) \
		.override_failure_message("below the threshold the frame stays clean") \
		.is_equal_approx(0.0, 0.0001)


func test_blur_appears_above_the_threshold() -> void:
	var blur := _make()
	assert_float(blur.strength_for_speed(blur.start_speed_kmh + 20.0)) \
		.override_failure_message("past the threshold the blur engages") \
		.is_greater(0.0)


func test_blur_grows_with_speed() -> void:
	var blur := _make()
	var slow := blur.strength_for_speed(blur.start_speed_kmh + 20.0)
	var fast := blur.strength_for_speed(blur.start_speed_kmh + 60.0)
	assert_float(fast) \
		.override_failure_message("more speed -> more smear").is_greater(slow)


func test_blur_increases_monotonically() -> void:
	var blur := _make()
	# The effect must never dip as the car accelerates, or it would visibly pulse.
	var previous := 0.0
	for i in range(0, 41):
		var speed := float(i) * 10.0
		var strength := blur.strength_for_speed(speed)
		assert_float(strength) \
			.override_failure_message("blur never decreases with speed (at %.0f km/h)" % speed) \
			.is_greater_equal(previous - 0.0001)
		previous = strength


func test_blur_reaches_maximum_at_full_speed() -> void:
	var blur := _make()
	assert_float(blur.strength_for_speed(blur.full_speed_kmh)) \
		.override_failure_message("full speed gives the configured maximum") \
		.is_equal_approx(blur.max_strength, 0.0001)


func test_blur_is_capped_beyond_full_speed() -> void:
	var blur := _make()
	# The frame must not keep degrading indefinitely on a long straight.
	assert_float(blur.strength_for_speed(blur.full_speed_kmh * 5.0)) \
		.override_failure_message("the smear stops growing past full speed") \
		.is_equal_approx(blur.max_strength, 0.0001)


func test_blur_never_exceeds_the_configured_maximum() -> void:
	var blur := _make()
	for i in range(0, 60):
		assert_float(blur.strength_for_speed(float(i) * 20.0)) \
			.override_failure_message("strength stays within its ceiling (step %d)" % i) \
			.is_less_equal(blur.max_strength + 0.0001)


func test_reversing_uses_speed_magnitude() -> void:
	var blur := _make()
	# Speed arrives negative when reversing; the effect should treat it the same
	# rather than reading it as "below the threshold" forever.
	assert_float(blur.strength_for_speed(-blur.full_speed_kmh)) \
		.override_failure_message("reversing fast still blurs") \
		.is_equal_approx(blur.strength_for_speed(blur.full_speed_kmh), 0.0001)


func test_curve_is_gentle_in_the_mid_range() -> void:
	var blur := _make()
	# The exponent should hold most of the effect back for genuinely high speed,
	# so the top end feels like an event rather than the blur being always-on.
	var midpoint := (blur.start_speed_kmh + blur.full_speed_kmh) * 0.5
	var at_mid := blur.strength_for_speed(midpoint)
	assert_float(at_mid) \
		.override_failure_message("the mid range is well under half strength") \
		.is_less(blur.max_strength * 0.5)


# ─── Smoothing ───────────────────────────────────────────────────────────────

func test_strength_starts_clear() -> void:
	var blur := _make()
	assert_float(blur.get_strength()) \
		.override_failure_message("the overlay starts clear").is_equal_approx(0.0, 0.0001)


func test_strength_eases_rather_than_snapping() -> void:
	var blur := _make()
	# A single frame at top speed must not jump straight to full blur, or a crash
	# (a sudden speed change) would flash the effect on and off.
	blur.update_speed(blur.full_speed_kmh, STEP)
	assert_float(blur.get_strength()) \
		.override_failure_message("the ramp eases in").is_less(blur.max_strength)


func test_strength_converges_on_the_target() -> void:
	var blur := _make()
	var settled := _settle(blur, blur.full_speed_kmh)
	assert_float(settled) \
		.override_failure_message("held at speed, the blur reaches full strength") \
		.is_equal_approx(blur.max_strength, 0.001)


func test_strength_eases_back_out_when_slowing() -> void:
	var blur := _make()
	_settle(blur, blur.full_speed_kmh)
	# Coming to a stop must clear the effect completely, not leave a haze.
	var cleared := _settle(blur, 0.0)
	assert_float(cleared) \
		.override_failure_message("stopping clears the blur").is_equal_approx(0.0, 0.001)


func test_zero_delta_holds_the_current_strength() -> void:
	var blur := _make()
	_settle(blur, blur.full_speed_kmh)
	var held := blur.get_strength()
	blur.update_speed(0.0, 0.0)
	assert_float(blur.get_strength()) \
		.override_failure_message("a paused frame does not move the effect") \
		.is_equal_approx(held, 0.0001)


# ─── Toggle ──────────────────────────────────────────────────────────────────

func test_disabling_drives_the_effect_to_zero() -> void:
	var blur := _make()
	_settle(blur, blur.full_speed_kmh)
	blur.enabled = false
	var cleared := _settle(blur, blur.full_speed_kmh)
	assert_float(cleared) \
		.override_failure_message("a disabled effect fades out even at speed") \
		.is_equal_approx(0.0, 0.001)


func test_reset_clears_immediately() -> void:
	var blur := _make()
	_settle(blur, blur.full_speed_kmh)
	blur.reset()
	assert_float(blur.get_strength()) \
		.override_failure_message("reset clears the blur at once") \
		.is_equal_approx(0.0, 0.0001)


# ─── Placement contract ──────────────────────────────────────────────────────

func test_overlay_ignores_mouse_input() -> void:
	var blur := _make()
	# This node covers the entire screen. If it accepted input it would swallow
	# every click meant for the pause menu underneath it.
	assert_int(blur.mouse_filter) \
		.override_failure_message("the overlay never intercepts clicks") \
		.is_equal(Control.MOUSE_FILTER_IGNORE)


func test_overlay_covers_the_viewport() -> void:
	var blur := _make()
	# A partial overlay would blur only part of the frame, with a visible seam.
	assert_float(blur.anchor_right) \
		.override_failure_message("the overlay spans the full width") \
		.is_equal_approx(1.0, 0.0001)
	assert_float(blur.anchor_bottom) \
		.override_failure_message("the overlay spans the full height") \
		.is_equal_approx(1.0, 0.0001)


func test_update_is_safe_without_a_shader_material() -> void:
	var blur := _make()
	# The node is created in tests (and could be authored in a scene) with no
	# material assigned. Driving it must degrade gracefully rather than erroring.
	blur.update_speed(150.0, STEP)
	assert_float(blur.get_strength()) \
		.override_failure_message("the curve still runs without a material") \
		.is_greater(0.0)
