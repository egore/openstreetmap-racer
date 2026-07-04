extends GdUnitTestSuite

## Unit tests for WeatherController — the dry/wet-road weather state.
##
## The controller drives a single global shader uniform (`wetness`) that the
## asphalt/terrain shaders read. Its testable surface is the state machine and
## the live level: set_wet / toggle / is_wet, and where the level lands. The
## tween that animates the level needs a SceneTree, so the controller is added as
## a child; tests read get_level() (the value pushed to the uniform) rather than
## the uniform itself, which keeps them independent of a live RenderingServer.
##
## Level constants are read off the class so expectations track the source.

const WET := WeatherController.WET_LEVEL
const DRY := WeatherController.DRY_LEVEL


func _weather(start_wet: bool = false) -> WeatherController:
	var w := WeatherController.new()
	w.start_wet = start_wet
	add_child(w)   # runs _ready(), which seeds the level
	return w


# ─── Initial state ───────────────────────────────────────────────────────────

## Starts dry by default: not wet, level at the dry constant.
func test_starts_dry_by_default() -> void:
	var w := _weather(false)
	assert_bool(w.is_wet()).override_failure_message("defaults to dry").is_false()
	assert_float(w.get_level()).override_failure_message("dry level seeded").is_equal_approx(DRY, 0.001)


## start_wet seeds the wet state and level immediately (no fade needed at boot).
func test_starts_wet_when_configured() -> void:
	var w := _weather(true)
	assert_bool(w.is_wet()).override_failure_message("start_wet -> wet").is_true()
	assert_float(w.get_level()).override_failure_message("wet level seeded").is_equal_approx(WET, 0.001)


# ─── State transitions ───────────────────────────────────────────────────────

## set_wet(true) flips the target state immediately (before the fade finishes).
func test_set_wet_flips_target() -> void:
	var w := _weather(false)
	w.set_wet(true)
	assert_bool(w.is_wet()).override_failure_message("target is wet at once").is_true()


## toggle() flips and returns the new state.
func test_toggle_flips_and_reports() -> void:
	var w := _weather(false)
	assert_bool(w.toggle()).override_failure_message("toggle from dry -> wet").is_true()
	assert_bool(w.is_wet()).is_true()
	assert_bool(w.toggle()).override_failure_message("toggle from wet -> dry").is_false()
	assert_bool(w.is_wet()).is_false()


## Setting the same state when idle is a no-op (doesn't start a redundant tween).
func test_set_same_state_is_noop() -> void:
	var w := _weather(false)
	# Already dry and no tween in flight; asking for dry again must not change level.
	w.set_wet(false)
	assert_float(w.get_level()).override_failure_message("still dry").is_equal_approx(DRY, 0.001)


# ─── Level animation (via the tween on the tree) ─────────────────────────────

## After a wet transition completes, the level reaches the wet constant.
func test_level_reaches_wet_after_transition() -> void:
	var w := _weather(false)
	w.set_wet(true)
	# Wait out the full transition plus a margin.
	await await_millis(int(WeatherController.TRANSITION_TIME * 1000.0) + 400)
	assert_float(w.get_level()) \
		.override_failure_message("level tweened to wet") \
		.is_equal_approx(WET, 0.01)


## And a wet→dry transition brings the level back to dry.
func test_level_returns_to_dry() -> void:
	var w := _weather(true)
	w.set_wet(false)
	await await_millis(int(WeatherController.TRANSITION_TIME * 1000.0) + 400)
	assert_float(w.get_level()) \
		.override_failure_message("level tweened back to dry") \
		.is_equal_approx(DRY, 0.01)


# ─── Level bounds ────────────────────────────────────────────────────────────

## The live level is always clamped to 0..1 (a stray value can't blow the shader).
func test_level_is_clamped() -> void:
	var w := _weather(false)
	w._apply_level(5.0)
	assert_float(w.get_level()).override_failure_message("clamped to 1").is_equal_approx(1.0, 0.001)
	w._apply_level(-2.0)
	assert_float(w.get_level()).override_failure_message("clamped to 0").is_equal_approx(0.0, 0.001)


## The wet level is meaningfully wet but held below a perfect mirror.
func test_wet_level_is_high_but_not_full() -> void:
	assert_float(WET).override_failure_message("wet is substantially wet").is_greater(0.5)
	assert_float(WET).override_failure_message("wet stays below a perfect mirror").is_less_equal(1.0)
	assert_float(DRY).override_failure_message("dry is zero").is_equal_approx(0.0, 0.001)
