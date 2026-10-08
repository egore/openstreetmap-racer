extends GdUnitTestSuite

## RunSession: the clock and statistics of one timed run.

const RunSessionScript := preload("res://scripts/run_session.gd")


func _session(duration: float = 10.0) -> RunSessionScript:
	var s := RunSessionScript.new()
	s.duration = duration
	s.countdown_time = 3.0
	s.start()
	return s


## Tick until a cue other than NONE fires, or `max_seconds` pass.
func _tick_until_cue(s: RunSessionScript, max_seconds: float, speed: float = 0.0) -> int:
	var t := 0.0
	while t < max_seconds:
		var cue := s.tick(0.1, speed, 0)
		if cue != RunSessionScript.Cue.NONE:
			return cue
		t += 0.1
	return RunSessionScript.Cue.NONE


func test_starts_with_a_countdown_from_three() -> void:
	var s := _session()
	assert_int(s.state).is_equal(RunSessionScript.State.COUNTDOWN)
	assert_int(s.countdown_number()).is_equal(3)
	s.tick(1.5, 0.0, 0)
	assert_int(s.countdown_number()).is_equal(2)


func test_countdown_ends_with_go_and_the_clock_untouched() -> void:
	var s := _session()
	assert_int(_tick_until_cue(s, 5.0)).is_equal(RunSessionScript.Cue.GO)
	assert_bool(s.is_running()).is_true()
	assert_float(s.time_left()).is_equal(10.0)


func test_run_finishes_once_when_the_clock_runs_out() -> void:
	var s := _session(2.0)
	_tick_until_cue(s, 5.0)
	assert_int(_tick_until_cue(s, 5.0)).is_equal(RunSessionScript.Cue.FINISHED)
	assert_float(s.time_left()).is_equal(0.0)
	assert_int(s.tick(0.1, 0.0, 0)).is_equal(RunSessionScript.Cue.NONE)


func test_distance_and_top_speed_only_count_while_running() -> void:
	var s := _session(2.0)
	_tick_until_cue(s, 5.0, 20.0)
	assert_float(s.distance_m).is_equal(0.0)
	s.tick(1.0, 10.0, 0)
	# The final frame overshoots the clock; only the second left counts.
	s.tick(5.0, 30.0, 0)
	assert_float(s.distance_m).is_equal_approx(40.0, 0.001)
	assert_float(s.top_speed_ms).is_equal(30.0)


func test_score_follows_the_cars_kudos_until_the_end() -> void:
	var s := _session(1.0)
	_tick_until_cue(s, 5.0)
	s.tick(0.5, 0.0, 120)
	assert_int(s.score).is_equal(120)
	s.tick(1.0, 0.0, 300)
	s.tick(0.1, 0.0, 999)
	assert_int(s.score).is_equal(300)


func test_events_are_tallied_during_the_run_only() -> void:
	var s := _session()
	s.record_event("DRIFT", 50, false)
	_tick_until_cue(s, 5.0)
	s.record_event("DRIFT", 40, false)
	s.record_event("NEAR MISS", 90, false)
	s.record_event("NEAR MISS", 60, false)
	s.record_event("CRASH", -200, true)
	s.record_event("FLIPPED", -150, true)
	assert_int(s.drifts).is_equal(1)
	assert_int(s.near_misses).is_equal(2)
	assert_int(s.mistakes).is_equal(2)
	assert_str(s.best_move_label).is_equal("NEAR MISS")
	assert_int(s.best_move_amount).is_equal(90)


func test_restarting_clears_the_previous_run() -> void:
	var s := _session(1.0)
	_tick_until_cue(s, 5.0)
	s.record_event("DRIFT", 40, false)
	s.tick(0.5, 10.0, 80)
	s.start()
	assert_int(s.score).is_equal(0)
	assert_int(s.drifts).is_equal(0)
	assert_float(s.distance_m).is_equal(0.0)
	assert_float(s.time_left()).is_equal(1.0)


func test_clock_text_rounds_up() -> void:
	assert_str(RunSessionScript.format_time(180.0)).is_equal("3:00")
	assert_str(RunSessionScript.format_time(125.2)).is_equal("2:06")
	assert_str(RunSessionScript.format_time(0.4)).is_equal("0:01")
	assert_str(RunSessionScript.format_time(0.0)).is_equal("0:00")


func test_score_text_groups_thousands() -> void:
	assert_str(RunSessionScript.format_score(0)).is_equal("0")
	assert_str(RunSessionScript.format_score(999)).is_equal("999")
	assert_str(RunSessionScript.format_score(12345)).is_equal("12,345")
	assert_str(RunSessionScript.format_score(1234567)).is_equal("1,234,567")
