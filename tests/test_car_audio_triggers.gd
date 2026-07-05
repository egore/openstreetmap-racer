extends GdUnitTestSuite

## Unit tests for CarAudioTriggers.
##
## CarAudioTriggers is a pure logic helper (no AudioStreamPlayer, no scene tree):
## the car feeds it slip/speed/grip each frame and discrete crash severities, and
## it answers with a screech level and impact one-shot decisions. These tests pin
## the feel curve so future tuning can't silently break it:
##
##   1. No screech when slipping below threshold, or below the min speed.
##   2. Screech ramps with slip and with speed, saturating at 1.0.
##   3. A broken-traction slide screeches louder than a clean-gripping chirp.
##   4. update_screech eases toward the target rather than snapping.
##   5. Impacts below min severity don't play; qualifying ones scale with severity.
##   6. The impact cooldown collapses a multi-frame crash into a single thump.

const CarAudioTriggers := preload("res://scripts/car_audio_triggers.gd")


func _make() -> CarAudioTriggers:
	return CarAudioTriggers.new()


# ─── Screech: silence conditions ─────────────────────────────────────────────

func test_no_screech_below_slip_threshold() -> void:
	var a := _make()
	# Tracking almost straight at speed: silent.
	var target := a._screech_target(0.05, 15.0, false)
	assert_float(target).override_failure_message("tiny slip -> no screech").is_equal_approx(0.0, 0.0001)


func test_no_screech_below_min_speed() -> void:
	var a := _make()
	# Fully sideways but nearly stopped: silent (a nudge shouldn't squeal).
	var target := a._screech_target(1.0, 1.0, false)
	assert_float(target).override_failure_message("slow slide -> no screech").is_equal_approx(0.0, 0.0001)


# ─── Screech: ramp behaviour ─────────────────────────────────────────────────

func test_screech_increases_with_slip() -> void:
	var a := _make()
	var low := a._screech_target(0.3, 15.0, false)
	var high := a._screech_target(0.5, 15.0, false)
	assert_float(high).override_failure_message("more slip -> louder screech").is_greater(low)


func test_screech_increases_with_speed() -> void:
	var a := _make()
	var slow := a._screech_target(0.5, 8.0, false)
	var fast := a._screech_target(0.5, 18.0, false)
	assert_float(fast).override_failure_message("more speed -> louder screech").is_greater(slow)


func test_screech_saturates_at_one() -> void:
	var a := _make()
	# Way past every threshold on a broken-traction slide: clamps to 1.0.
	var target := a._screech_target(2.0, 40.0, false)
	assert_float(target).override_failure_message("screech clamps to 1.0").is_equal_approx(1.0, 0.0001)


func test_broken_traction_louder_than_gripping() -> void:
	var a := _make()
	var gripping := a._screech_target(0.5, 15.0, true)
	var sliding := a._screech_target(0.5, 15.0, false)
	assert_float(sliding).override_failure_message("a slide squeals louder than a grip chirp") \
		.is_greater(gripping)


func test_realistic_drift_is_clearly_audible() -> void:
	# Regression guard for the "I drift but hear nothing" bug. This car tops out
	# around 15 m/s (55 km/h); a normal cornering drift (past the drift-kudos slip
	# threshold, no handbrake so gripping=true) must produce a level well above the
	# audible floor — not the near-silent ~0.06 the old thresholds gave. If someone
	# retunes the speed band back up for a faster car, this fails loudly.
	var a := _make()
	var level := a._screech_target(0.35, 10.0, true)  # a solid grip drift at 36 km/h
	assert_float(level).override_failure_message(
		"a normal drift on this car must clearly squeal (level=%.3f)" % level).is_greater(0.25)


# ─── Screech: smoothing ──────────────────────────────────────────────────────

func test_update_screech_eases_toward_target() -> void:
	var a := _make()
	a.screech_attack = 4.0
	# One short frame at full-slip should move the level up but not all the way.
	var lvl := a.update_screech(2.0, 40.0, false, 0.05)
	assert_float(lvl).override_failure_message("level rises from zero").is_greater(0.0)
	assert_float(lvl).override_failure_message("but does not snap to full in one frame").is_less(1.0)


func test_release_is_slower_than_attack() -> void:
	# The squeal must fall slower than it rises, so a brief sub-threshold slip dip
	# mid-drift doesn't zero the level and restart the sample (the "playing but
	# silent" stutter bug). Rise one step from 0, then fall one step from a high
	# level with the SAME delta; the fall must move less than the rise.
	var a := _make()
	var rise_from := a.screech_level  # 0.0
	a.update_screech(2.0, 40.0, false, 0.05)  # target ~1.0, uses attack
	var rise_delta := a.screech_level - rise_from
	var b := _make()
	b.screech_level = 0.8
	b.update_screech(0.0, 0.0, false, 0.05)   # target 0.0, uses release
	var fall_delta := 0.8 - b.screech_level
	assert_float(fall_delta).override_failure_message(
		"release must be gentler than attack (rise=%.3f fall=%.3f)" % [rise_delta, fall_delta]) \
		.is_less(rise_delta)


func test_holds_through_brief_slip_dip() -> void:
	# Simulate a drift where slip dips below threshold for a couple of frames: the
	# level must stay clearly audible across the dip, not collapse to zero.
	var a := _make()
	# Establish a strong squeal.
	for i in range(10):
		a.update_screech(0.5, 12.0, false, 1.0 / 60.0)
	var before := a.screech_level
	assert_float(before).override_failure_message("squeal established").is_greater(0.3)
	# Two frames of no slip (a momentary dip).
	a.update_screech(0.0, 12.0, false, 1.0 / 60.0)
	a.update_screech(0.0, 12.0, false, 1.0 / 60.0)
	assert_float(a.screech_level).override_failure_message(
		"level holds audible through a 2-frame slip dip (was %.3f, now %.3f)" % [before, a.screech_level]) \
		.is_greater(0.02)


func test_update_screech_settles_to_zero() -> void:
	var a := _make()
	a.screech_level = 0.8
	# Feed a silent state for a long frame: eases back down to (near) zero.
	for i: int in range(20):
		a.update_screech(0.0, 0.0, false, 0.1)
	assert_float(a.screech_level).override_failure_message("screech settles silent").is_equal_approx(0.0, 0.001)


# ─── Impact ──────────────────────────────────────────────────────────────────

func test_impact_below_min_severity_does_not_play() -> void:
	var a := _make()
	var r := a.register_impact(1.0)
	assert_bool(r["play"]).override_failure_message("a negligible tap makes no sound").is_false()


func test_impact_volume_scales_with_severity() -> void:
	var a := _make()
	var soft := a.register_impact(20.0)
	# Space the next hit past the cooldown by advancing time via update_screech.
	a.update_screech(0.0, 0.0, false, 1.0)
	var hard := a.register_impact(120.0)
	assert_bool(soft["play"]).override_failure_message("soft hit plays").is_true()
	assert_bool(hard["play"]).override_failure_message("hard hit plays").is_true()
	assert_float(hard["volume"]).override_failure_message("harder hit is louder") \
		.is_greater(soft["volume"])


func test_impact_volume_clamped_to_one() -> void:
	var a := _make()
	var r := a.register_impact(10000.0)
	assert_float(r["volume"]).override_failure_message("impact volume clamps to 1.0") \
		.is_less_equal(1.0)


func test_impact_cooldown_collapses_burst() -> void:
	# A crash can emit several penalty events across consecutive physics frames.
	# Only the first should thump; the rest fall inside the cooldown window.
	var a := _make()
	a.impact_cooldown = 0.15
	var first := a.register_impact(100.0)
	# Two more hits within the same ~16ms frame window.
	a.update_screech(0.0, 0.0, false, 0.016)
	var second := a.register_impact(100.0)
	a.update_screech(0.0, 0.0, false, 0.016)
	var third := a.register_impact(100.0)
	assert_bool(first["play"]).override_failure_message("first hit thumps").is_true()
	assert_bool(second["play"]).override_failure_message("second hit suppressed by cooldown").is_false()
	assert_bool(third["play"]).override_failure_message("third hit suppressed by cooldown").is_false()


func test_impact_fires_again_after_cooldown() -> void:
	var a := _make()
	a.impact_cooldown = 0.15
	var first := a.register_impact(100.0)
	# Advance well past the cooldown.
	a.update_screech(0.0, 0.0, false, 0.3)
	var later := a.register_impact(100.0)
	assert_bool(first["play"]).override_failure_message("first hit thumps").is_true()
	assert_bool(later["play"]).override_failure_message("a properly-spaced later hit thumps too").is_true()


func test_rejected_impact_does_not_reset_cooldown() -> void:
	# A too-soon hit must NOT push the cooldown timer, or a rapid stream of hits
	# could starve a legitimately-spaced impact forever.
	var a := _make()
	a.impact_cooldown = 0.15
	a.register_impact(100.0)              # fires, timer = 0
	a.update_screech(0.0, 0.0, false, 0.1)  # timer = 0.1 (still < cooldown)
	var rejected := a.register_impact(100.0)  # rejected, must NOT reset timer
	assert_bool(rejected["play"]).is_false()
	a.update_screech(0.0, 0.0, false, 0.1)  # timer = 0.2 (> cooldown) if not reset
	var ok := a.register_impact(100.0)
	assert_bool(ok["play"]).override_failure_message("rejected hit didn't swallow the cooldown").is_true()
