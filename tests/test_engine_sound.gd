extends GdUnitTestSuite

## Unit tests for the EngineSound mute/unmute behaviour.
##
## EngineSound wraps an AudioStreamPlayer whose actual audio output depends on
## the Godot audio server (unavailable in headless CI).  These tests verify the
## *logic* layer: that set_muted() sets the flag, that update_engine() is a
## no-op while muted, and that un-muting allows the player to restart.

const Transmission := preload("res://scripts/transmission.gd")


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Build an EngineSound, attach it to the scene tree so _ready() fires, and
## return it.  The caller must free it via free_engine().
func _make() -> EngineSound:
	var es := EngineSound.new()
	add_child(es)
	# After add_child + _ready, the internal _player exists.
	return es


func free_engine(es: EngineSound) -> void:
	if es != null and is_instance_valid(es):
		es.free()


# ─── set_muted flag ──────────────────────────────────────────────────────────

func test_initially_not_muted() -> void:
	var es := _make()
	assert_bool(es._muted) \
		.override_failure_message("engine starts un-muted").is_false()
	free_engine(es)


func test_set_muted_true_sets_flag() -> void:
	var es := _make()
	es.set_muted(true)
	assert_bool(es._muted) \
		.override_failure_message("set_muted(true) sets the flag").is_true()
	free_engine(es)


func test_set_muted_false_clears_flag() -> void:
	var es := _make()
	es.set_muted(true)
	es.set_muted(false)
	assert_bool(es._muted) \
		.override_failure_message("set_muted(false) clears the flag").is_false()
	free_engine(es)


# ─── set_muted stops the player ─────────────────────────────────────────────

func test_muting_stops_player() -> void:
	var es := _make()
	# Kick the player into the playing state via update_engine.
	es.update_engine(60.0, 2, 0.5)
	es.set_muted(true)
	assert_bool(es._player.playing) \
		.override_failure_message("muting stops the AudioStreamPlayer").is_false()
	free_engine(es)


# ─── update_engine is a no-op while muted ────────────────────────────────────

func test_update_engine_does_not_restart_while_muted() -> void:
	var es := _make()
	es.set_muted(true)
	# Calling update_engine while muted must not restart playback.
	es.update_engine(100.0, 3, 0.7)
	assert_bool(es._player.playing) \
		.override_failure_message("update_engine is a no-op while muted").is_false()
	free_engine(es)


# ─── un-muting allows restart ────────────────────────────────────────────────

func test_unmuting_allows_restart_on_next_update() -> void:
	var es := _make()
	es.update_engine(60.0, 2, 0.5)
	es.set_muted(true)
	assert_bool(es._player.playing).is_false()
	es.set_muted(false)
	# The player should restart on the next update_engine call.
	es.update_engine(60.0, 2, 0.5)
	assert_bool(es._player.playing) \
		.override_failure_message("un-muting lets update_engine restart the player").is_true()
	free_engine(es)


# ─── sweep position helper ──────────────────────────────────────────────────

func test_sweep_position_boundaries() -> void:
	var es := _make()
	assert_float(es._sweep_position_for_ratio(0.0)) \
		.override_failure_message("ratio 0 -> SWEEP_START").is_equal(EngineSound.SWEEP_START)
	assert_float(es._sweep_position_for_ratio(1.0)) \
		.override_failure_message("ratio 1 -> SWEEP_END").is_equal(EngineSound.SWEEP_END)
	free_engine(es)
