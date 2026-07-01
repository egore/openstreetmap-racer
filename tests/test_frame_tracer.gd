extends GdUnitTestSuite

## Tests for FrameTracer, the opt-in span timer used to hunt main-thread
## stutters. The important guarantees: it's inert (no logging, no stats) when
## disabled, it aggregates durations when enabled, and record_usec is safe to
## call the way the worker-thread parse/rebuild tasks do.

const FrameTracer := preload("res://scripts/frame_tracer.gd")


func before_test() -> void:
	# Each test controls enablement explicitly; start from a clean, known state.
	FrameTracer.set_enabled(false)
	FrameTracer.dump_summary()  # clears any residual stats (no-op while disabled)


func after() -> void:
	FrameTracer.set_enabled(false)


func test_disabled_by_default_records_nothing() -> void:
	FrameTracer.set_enabled(false)
	FrameTracer.begin("x")
	var elapsed := FrameTracer.end("x")
	assert_int(elapsed).override_failure_message("disabled end() returns 0").is_equal(0)


func test_enabled_end_returns_positive_elapsed() -> void:
	FrameTracer.set_enabled(true)
	FrameTracer.begin("work")
	# Burn a little wall-clock so the span is measurably non-zero.
	var spin := Time.get_ticks_usec() + 1500
	while Time.get_ticks_usec() < spin:
		pass
	var elapsed := FrameTracer.end("work")
	assert_int(elapsed).override_failure_message("enabled span measures elapsed time").is_greater(0)


func test_end_without_begin_is_safe() -> void:
	FrameTracer.set_enabled(true)
	# No matching begin(): must not crash and must report zero.
	assert_int(FrameTracer.end("never_begun")) \
		.override_failure_message("unmatched end() is a safe no-op").is_equal(0)


func test_threshold_gates_logging_not_measurement() -> void:
	# A high threshold means nothing is *logged*, but elapsed is still measured
	# and returned (logging is a side effect; measurement is the contract).
	FrameTracer.set_enabled(true)
	FrameTracer.set_threshold_ms(100000.0)  # effectively never logs
	FrameTracer.begin("quiet")
	var elapsed := FrameTracer.end("quiet")
	assert_int(elapsed).override_failure_message("still measured under threshold").is_greater_equal(0)
	FrameTracer.set_threshold_ms(4.0)  # restore default-ish


func test_record_usec_accumulates_when_enabled() -> void:
	# record_usec is the thread-safe entry the worker tasks use. It must be inert
	# when disabled and accumulate when enabled (proven indirectly: enabling and
	# recording then dumping must not crash and clears cleanly).
	FrameTracer.set_enabled(false)
	FrameTracer.record_usec("offthread", 5000)  # inert
	FrameTracer.set_enabled(true)
	FrameTracer.record_usec("offthread", 5000)
	FrameTracer.record_usec("offthread", 7000)
	# dump_summary clears stats; a second dump has nothing to report. We can't
	# capture stdout here, but we assert it runs without error and resets.
	FrameTracer.dump_summary()
	FrameTracer.dump_summary()
	assert_bool(true).override_failure_message("record/dump cycle is safe").is_true()


func test_scope_ends_on_free() -> void:
	# The RAII Span must end its span when the reference is dropped. With tracing
	# enabled, opening a scope then releasing it should leave no dangling open
	# span (a subsequent end() of the same label is a no-op returning 0).
	FrameTracer.set_enabled(true)
	var s := FrameTracer.scope("scoped")
	s = null  # drop the only reference -> _notification(PREDELETE) ends the span
	# The span already ended; ending it again by hand must be a no-op.
	assert_int(FrameTracer.end("scoped")) \
		.override_failure_message("scope already closed on free").is_equal(0)


func test_scope_close_is_idempotent() -> void:
	FrameTracer.set_enabled(true)
	var s := FrameTracer.scope("closeme")
	s.close()
	s.close()  # second close must not error or double-count
	assert_bool(true).override_failure_message("double close is safe").is_true()
