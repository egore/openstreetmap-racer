extends GdUnitTestSuite

## Unit tests for the PostProcessing controller.
##
## PostProcessing is a Node, but its meaningful logic is pure: given the effect
## toggles and a PPSettings struct it stamps an Environment resource. So each
## test builds a controller, sets its toggles, and calls apply_to() against a
## throwaway Environment — no WorldEnvironment, no SceneTree fade, no rendering.
## We assert exactly the Environment fields the controller is responsible for,
## leaving fog/ambient (owned by SkyController) untouched.
##
## The day/night presets are read straight off the class constants so the
## expectations track the source: if a preset value changes, these move with it.

const DAY := PostProcessing.DAY
const NIGHT := PostProcessing.NIGHT


# ─── Fixtures ────────────────────────────────────────────────────────────────

## A PostProcessing instance added to the tree (so any tween has a home) with all
## effects on by default. Tests flip individual toggles before calling apply_to.
func _pp() -> PostProcessing:
	var pp := PostProcessing.new()
	add_child(pp)
	return pp


## A PPSettings struct filled from a preset dictionary (DAY/NIGHT), mirroring the
## controller's own _copy_preset_into so tests can feed apply_to real values.
func _settings(d: Dictionary) -> PostProcessing.PPSettings:
	var s := PostProcessing.PPSettings.new()
	s.glow_intensity = d.glow_intensity
	s.glow_bloom = d.glow_bloom
	s.glow_hdr_threshold = d.glow_hdr_threshold
	s.exposure = d.exposure
	s.brightness = d.brightness
	s.contrast = d.contrast
	s.saturation = d.saturation
	s.dof_far_distance = d.dof_far_distance
	s.dof_far_transition = d.dof_far_transition
	s.dof_far_amount = d.dof_far_amount
	return s


# ─── Master switch ───────────────────────────────────────────────────────────

## With the master switch off, every screen-space effect is disabled regardless
## of the individual toggles — the clean A/B baseline.
func test_master_disabled_turns_everything_off() -> void:
	var pp := _pp()
	pp.enabled = false
	# Individually "on", but the master switch must win.
	pp.glow_enabled = true
	pp.ssao_enabled = true
	pp.ssil_enabled = true
	pp.ssr_enabled = true
	pp.adjustments_enabled = true
	pp.dof_enabled = true

	var env := Environment.new()
	pp.apply_to(env, _settings(DAY))
	var attrs := CameraAttributesPractical.new()
	pp.apply_dof_to(attrs, _settings(DAY))

	assert_bool(env.glow_enabled).override_failure_message("master off disables glow").is_false()
	assert_bool(env.ssao_enabled).override_failure_message("master off disables SSAO").is_false()
	assert_bool(env.ssil_enabled).override_failure_message("master off disables SSIL").is_false()
	assert_bool(env.ssr_enabled).override_failure_message("master off disables SSR").is_false()
	assert_bool(env.adjustment_enabled).override_failure_message("master off disables grade").is_false()
	assert_bool(attrs.dof_blur_far_enabled).override_failure_message("master off disables DOF").is_false()


# ─── Per-effect toggles ──────────────────────────────────────────────────────

## Every effect on maps straight through to the Environment flags.
func test_all_effects_on_map_through() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.glow_enabled = true
	pp.ssao_enabled = true
	pp.ssil_enabled = true
	pp.ssr_enabled = true
	pp.adjustments_enabled = true

	var env := Environment.new()
	pp.apply_to(env, _settings(DAY))

	assert_bool(env.glow_enabled).is_true()
	assert_bool(env.ssao_enabled).is_true()
	assert_bool(env.ssil_enabled).is_true()
	assert_bool(env.ssr_enabled).is_true()
	assert_bool(env.adjustment_enabled).is_true()


## Each effect toggles independently: turning one off leaves the others on.
func test_effects_toggle_independently() -> void:
	var effects := ["glow_enabled", "ssao_enabled", "ssil_enabled", "ssr_enabled"]
	var env_flag := {
		"glow_enabled": "glow_enabled",
		"ssao_enabled": "ssao_enabled",
		"ssil_enabled": "ssil_enabled",
		"ssr_enabled": "ssr_enabled",
	}
	for off: String in effects:
		var pp := _pp()
		pp.enabled = true
		# Start all on, then disable exactly one.
		for e: String in effects:
			pp.set(e, true)
		pp.set(off, false)

		var env := Environment.new()
		pp.apply_to(env, _settings(DAY))

		# The disabled one is off...
		assert_bool(env.get(env_flag[off])) \
			.override_failure_message("%s disabled -> env flag off" % off).is_false()
		# ...and every other one stays on.
		for e: String in effects:
			if e == off:
				continue
			assert_bool(env.get(env_flag[e])) \
				.override_failure_message("%s stays on when only %s is disabled" % [e, off]).is_true()


## Disabling only the grade leaves the screen-space effects untouched.
func test_adjustments_toggle_is_independent() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.glow_enabled = true
	pp.ssr_enabled = true
	pp.adjustments_enabled = false

	var env := Environment.new()
	pp.apply_to(env, _settings(DAY))

	assert_bool(env.adjustment_enabled).override_failure_message("grade off").is_false()
	assert_bool(env.glow_enabled).override_failure_message("glow unaffected by grade toggle").is_true()
	assert_bool(env.ssr_enabled).override_failure_message("SSR unaffected by grade toggle").is_true()


# ─── Continuous values ───────────────────────────────────────────────────────

## Glow parameters are written from the supplied settings when glow is on.
func test_glow_values_applied() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.glow_enabled = true
	var s := _settings(NIGHT)

	var env := Environment.new()
	pp.apply_to(env, s)

	assert_float(env.glow_intensity).is_equal_approx(s.glow_intensity, 0.0001)
	assert_float(env.glow_bloom).is_equal_approx(s.glow_bloom, 0.0001)
	assert_float(env.glow_hdr_threshold).is_equal_approx(s.glow_hdr_threshold, 0.0001)


## The grade (exposure/brightness/contrast/saturation) is written when on.
func test_grade_values_applied() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.adjustments_enabled = true
	var s := _settings(DAY)

	var env := Environment.new()
	pp.apply_to(env, s)

	assert_float(env.tonemap_exposure).is_equal_approx(s.exposure, 0.0001)
	assert_float(env.adjustment_brightness).is_equal_approx(s.brightness, 0.0001)
	assert_float(env.adjustment_contrast).is_equal_approx(s.contrast, 0.0001)
	assert_float(env.adjustment_saturation).is_equal_approx(s.saturation, 0.0001)


## We always drive an ACES filmic tonemap when enabled (the "AAA" rolloff).
func test_tonemap_is_aces_when_enabled() -> void:
	var pp := _pp()
	pp.enabled = true
	var env := Environment.new()
	pp.apply_to(env, _settings(DAY))
	assert_int(env.tonemap_mode).is_equal(Environment.TONE_MAPPER_ACES)


## Glow uses the screen blend mode (physical-ish bloom, not blown-out additive).
func test_glow_uses_screen_blend() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.glow_enabled = true
	var env := Environment.new()
	pp.apply_to(env, _settings(DAY))
	assert_int(env.glow_blend_mode).is_equal(Environment.GLOW_BLEND_MODE_SCREEN)


# ─── Day vs night presets ────────────────────────────────────────────────────

## Night blooms harder and lower-threshold than day, so emissive lights blaze
## against the dark frame. This is the whole reason the presets differ.
func test_night_blooms_harder_than_day() -> void:
	assert_float(NIGHT.glow_bloom) \
		.override_failure_message("night has stronger bloom than day").is_greater(DAY.glow_bloom)
	assert_float(NIGHT.glow_intensity) \
		.override_failure_message("night has higher glow intensity than day").is_greater(DAY.glow_intensity)
	assert_float(NIGHT.glow_hdr_threshold) \
		.override_failure_message("night bloom kicks in at a lower threshold").is_less(DAY.glow_hdr_threshold)


## Night lifts exposure so shadows don't crush to pure black.
func test_night_exposure_lifts() -> void:
	assert_float(NIGHT.exposure) \
		.override_failure_message("night exposure lifts above day").is_greater_equal(DAY.exposure)


## Applying the day preset then the night preset actually changes the written
## glow values on the Environment (presets aren't accidentally identical).
func test_presets_produce_different_environment() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.glow_enabled = true

	var day_env := Environment.new()
	pp.apply_to(day_env, _settings(DAY))
	var night_env := Environment.new()
	pp.apply_to(night_env, _settings(NIGHT))

	assert_float(night_env.glow_bloom) \
		.override_failure_message("day and night bloom differ on the Environment") \
		.is_not_equal(day_env.glow_bloom)


# ─── Depth of field ──────────────────────────────────────────────────────────

## DOF on writes the far-blur distance/transition/amount to the camera attributes.
func test_dof_values_applied() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.dof_enabled = true
	var s := _settings(DAY)

	var attrs := CameraAttributesPractical.new()
	pp.apply_dof_to(attrs, s)

	assert_bool(attrs.dof_blur_far_enabled).override_failure_message("DOF far enabled").is_true()
	assert_float(attrs.dof_blur_far_distance).is_equal_approx(s.dof_far_distance, 0.0001)
	assert_float(attrs.dof_blur_far_transition).is_equal_approx(s.dof_far_transition, 0.0001)
	assert_float(attrs.dof_blur_amount).is_equal_approx(s.dof_far_amount, 0.0001)


## DOF is gated by both its own toggle and the master switch, independently of
## the Environment-side effects.
func test_dof_toggle_is_independent() -> void:
	# DOF off -> camera attrs far-blur off, but Environment effects still on.
	var pp := _pp()
	pp.enabled = true
	pp.glow_enabled = true
	pp.ssr_enabled = true
	pp.dof_enabled = false

	var env := Environment.new()
	pp.apply_to(env, _settings(DAY))
	var attrs := CameraAttributesPractical.new()
	pp.apply_dof_to(attrs, _settings(DAY))

	assert_bool(attrs.dof_blur_far_enabled).override_failure_message("DOF off").is_false()
	assert_bool(env.glow_enabled).override_failure_message("glow unaffected by DOF toggle").is_true()
	assert_bool(env.ssr_enabled).override_failure_message("SSR unaffected by DOF toggle").is_true()


## Only the far side of DOF is used — the near blur is never enabled, so the car
## and immediate road always stay sharp.
func test_dof_near_stays_disabled() -> void:
	var pp := _pp()
	pp.enabled = true
	pp.dof_enabled = true
	var attrs := CameraAttributesPractical.new()
	pp.apply_dof_to(attrs, _settings(DAY))
	assert_bool(attrs.dof_blur_near_enabled).override_failure_message("near DOF stays off").is_false()
