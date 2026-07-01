class_name FrameTracer
extends RefCounted

## Lightweight, opt-in frame-time tracer for hunting main-thread stutters.
##
## The problem it solves: when the game hitches "while loading data", you need to
## know WHICH main-thread block ate the frame and for how long — without adding
## noisy prints everywhere or paying for them in normal play. This is a tiny
## span timer built on Time.get_ticks_usec() that:
##
##   * is a no-op unless tracing is enabled (near-zero cost when off), and
##   * when on, only logs a span whose duration exceeds a threshold, so the log
##     stays quiet until a real hitch happens, then names the culprit + its ms.
##
## Godot ships visual profilers (Debugger → Profiler / Visual Profiler / Monitors)
## which are the right first stop for an ad-hoc look. This helper complements them
## for the streaming/loading paths specifically: it works headless, is
## reproducible, attributes time to named spans you choose, and can be left in a
## shipped build (flag-gated) to diagnose a field report.
##
## Usage (paired begin/end):
##     FrameTracer.begin("instance_tile")
##     ... work ...
##     FrameTracer.end("instance_tile")   # logs if over threshold
##
## Usage (scoped, RAII-style — auto-ends when the returned object is freed):
##     var _s := FrameTracer.scope("build_terrain")
##     ... work ...        # span ends when _s goes out of scope
##
## Enabling:
##   * env var  OSMRACER_TRACE=1        (checked once, lazily)
##   * or code  FrameTracer.set_enabled(true)
##   * threshold via OSMRACER_TRACE_MS (float ms) or set_threshold_ms().

## Default: only report spans longer than this many milliseconds. A frame at 60
## fps is ~16.7 ms, so 4 ms is a meaningful slice of one frame's budget.
const _DEFAULT_THRESHOLD_MS := 4.0

static var _enabled: bool = false
static var _threshold_us: int = int(_DEFAULT_THRESHOLD_MS * 1000.0)
static var _configured: bool = false
## label -> start ticks (usec) for the currently open span of that label. Only
## touched by begin()/end(), which are main-thread paired calls; not shared with
## worker threads (those use record_usec, which needs no open-span state).
static var _open: Dictionary = {}
## Optional aggregation: label -> {count, total_us, max_us} across the run, for a
## summary dump. Only populated while enabled. Guarded by _stats_mutex because
## record_usec may be called from WorkerThreadPool tasks (e.g. timing the
## off-thread tile parse) concurrently with the main thread.
static var _stats: Dictionary = {}
static var _stats_mutex := Mutex.new()


## Lazily read env-var configuration the first time tracing is touched, so the
## helper needs no autoload/registration and stays inert until asked.
static func _ensure_configured() -> void:
	if _configured:
		return
	_configured = true
	if OS.has_environment("OSMRACER_TRACE"):
		var v := OS.get_environment("OSMRACER_TRACE").strip_edges()
		_enabled = v != "" and v != "0" and v.to_lower() != "false"
	if OS.has_environment("OSMRACER_TRACE_MS"):
		var ms := OS.get_environment("OSMRACER_TRACE_MS").to_float()
		if ms > 0.0:
			_threshold_us = int(ms * 1000.0)


## Turn tracing on/off at runtime (e.g. from a debug key or console command).
static func set_enabled(on: bool) -> void:
	_ensure_configured()
	_enabled = on


static func is_enabled() -> bool:
	_ensure_configured()
	return _enabled


## Only spans longer than this are logged. Lower it to catch smaller hitches.
static func set_threshold_ms(ms: float) -> void:
	_threshold_us = int(maxf(0.0, ms) * 1000.0)


## Open a span. Cheap no-op when disabled. Re-opening the same label overwrites
## the previous start (spans of one label are not meant to nest).
static func begin(label: String) -> void:
	if not is_enabled():
		return
	_open[label] = Time.get_ticks_usec()


## Close a span opened with begin(); logs + accumulates when over threshold.
## Returns the elapsed microseconds (0 when disabled or never begun), so callers
## can make their own decisions if they want.
static func end(label: String) -> int:
	if not is_enabled() or not _open.has(label):
		return 0
	var elapsed: int = Time.get_ticks_usec() - int(_open[label])
	_open.erase(label)
	_accumulate(label, elapsed)
	if elapsed >= _threshold_us:
		print("[trace] %s took %.2f ms" % [label, elapsed / 1000.0])
	return elapsed


## Scoped span: hold the returned Span; it ends automatically when freed (goes
## out of scope). Convenient for early-returning functions. No-op object when
## disabled so the call site stays uniform.
static func scope(label: String) -> Span:
	return Span.new(label)


## Record a pre-measured duration (usec) for a label without begin/end — handy
## for timing something you already bracketed with Time.get_ticks_usec(), or for
## aggregating off-thread work whose duration you pass back to the main thread.
static func record_usec(label: String, elapsed_us: int) -> void:
	if not is_enabled():
		return
	_accumulate(label, elapsed_us)
	if elapsed_us >= _threshold_us:
		print("[trace] %s took %.2f ms" % [label, elapsed_us / 1000.0])


static func _accumulate(label: String, elapsed_us: int) -> void:
	# Guarded: record_usec (hence _accumulate) can run on a WorkerThreadPool task
	# while the main thread also records a span. The lock is only taken when
	# tracing is enabled, so it costs nothing in normal play.
	_stats_mutex.lock()
	var s: Dictionary = _stats.get(label, {"count": 0, "total_us": 0, "max_us": 0})
	s["count"] = int(s["count"]) + 1
	s["total_us"] = int(s["total_us"]) + elapsed_us
	s["max_us"] = maxi(int(s["max_us"]), elapsed_us)
	_stats[label] = s
	_stats_mutex.unlock()


## Dump a per-label summary (count / total / avg / max) and clear it. Call this
## from a debug key or on quit to see where cumulative time went, not just the
## individual spikes. No-op when disabled.
static func dump_summary() -> void:
	if not is_enabled():
		return
	_stats_mutex.lock()
	var snapshot := _stats.duplicate(true)
	_stats.clear()
	_stats_mutex.unlock()
	if snapshot.is_empty():
		return
	print("[trace] ── summary ──────────────────────────────")
	var labels := snapshot.keys()
	labels.sort()
	for label: String in labels:
		var s: Dictionary = snapshot[label]
		var count := int(s["count"])
		var total := int(s["total_us"])
		var avg := total / maxi(1, count)
		print("[trace]   %-28s n=%-5d total=%8.2f ms  avg=%6.2f ms  max=%6.2f ms" % [
			label, count, total / 1000.0, avg / 1000.0, int(s["max_us"]) / 1000.0])
	print("[trace] ─────────────────────────────────────────")


## RAII-style span. Keep a reference for the duration you want to measure; when it
## is freed (reference dropped / out of scope), it ends the span. When tracing is
## disabled it holds no state and does nothing.
class Span extends RefCounted:
	var _label: String = ""
	var _active: bool = false

	func _init(label: String) -> void:
		# Reference the enclosing script's statics via a preload so this resolves
		# even during isolated script compilation (before the class_name is
		# registered globally). Kept as a const so there's no per-Span load cost.
		if _Tracer.is_enabled():
			_label = label
			_active = true
			_Tracer.begin(label)

	func _notification(what: int) -> void:
		if what == NOTIFICATION_PREDELETE and _active:
			_Tracer.end(_label)
			_active = false

	## End the span early (before it goes out of scope), if you need to.
	func close() -> void:
		if _active:
			_Tracer.end(_label)
			_active = false

const _Tracer := preload("res://scripts/frame_tracer.gd")
