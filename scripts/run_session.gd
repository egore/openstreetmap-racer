class_name RunSession
extends RefCounted

## One timed run: a countdown, a fixed stretch of driving, then a result.
##
## Pure logic, like KudosTracker: the run controller ticks it each frame with
## the car's speed and running kudos, and forwards each kudos event. The session
## keeps the clock and the run's statistics, and says when the run starts (GO)
## and ends (FINISHED).

enum Mode { FREE_DRIVE, KUDOS_ATTACK }
enum State { IDLE, COUNTDOWN, RUNNING, FINISHED }
## What tick() wants the caller to act on this frame.
enum Cue { NONE, GO, FINISHED }

## Seconds of scored driving.
var duration: float = 180.0
## Seconds of "3, 2, 1" before the run starts.
var countdown_time: float = 3.0

var state: State = State.IDLE

## Final (or, while running, current) kudos for this run.
var score: int = 0
var distance_m: float = 0.0
var top_speed_ms: float = 0.0
var drifts: int = 0
var near_misses: int = 0
## Crashes, flips and spin-outs.
var mistakes: int = 0
## The single biggest scoring moment, e.g. "NEAR MISS" for 140.
var best_move_label: String = ""
var best_move_amount: int = 0

var _countdown_left: float = 0.0
var _time_left: float = 0.0


## Reset everything and begin the countdown.
func start() -> void:
	state = State.COUNTDOWN
	_countdown_left = countdown_time
	_time_left = duration
	score = 0
	distance_m = 0.0
	top_speed_ms = 0.0
	drifts = 0
	near_misses = 0
	mistakes = 0
	best_move_label = ""
	best_move_amount = 0


## Advance the run by `delta` seconds. `kudos` is the car's running total, which
## the caller resets to zero on GO.
func tick(delta: float, speed_ms: float, kudos: int) -> Cue:
	match state:
		State.COUNTDOWN:
			_countdown_left -= delta
			if _countdown_left <= 0.0:
				_countdown_left = 0.0
				state = State.RUNNING
				return Cue.GO
		State.RUNNING:
			# Clamp so the frame that crosses zero doesn't count driving past it.
			var step := minf(delta, _time_left)
			_time_left -= step
			distance_m += speed_ms * step
			top_speed_ms = maxf(top_speed_ms, speed_ms)
			score = kudos
			if _time_left <= 0.0:
				_time_left = 0.0
				state = State.FINISHED
				return Cue.FINISHED
	return Cue.NONE


## Count a kudos event towards the run's statistics. Ignored outside the run.
func record_event(label: String, amount: int, is_penalty: bool) -> void:
	if state != State.RUNNING:
		return
	if is_penalty:
		mistakes += 1
		return
	match label:
		"DRIFT":
			drifts += 1
		"NEAR MISS":
			near_misses += 1
	if amount > best_move_amount:
		best_move_amount = amount
		best_move_label = label


## The number to show during the countdown: 3, 2, 1, then 0 once running.
func countdown_number() -> int:
	return ceili(_countdown_left) if state == State.COUNTDOWN else 0


func time_left() -> float:
	return _time_left


func is_running() -> bool:
	return state == State.RUNNING


## "2:05" style clock text. Rounds up, so the clock reads 0:00 only at the end.
static func format_time(seconds: float) -> String:
	var whole := ceili(maxf(seconds, 0.0))
	@warning_ignore("integer_division")
	return "%d:%02d" % [whole / 60, whole % 60]


## "12,345" style score text.
static func format_score(value: int) -> String:
	var digits := str(absi(value))
	var grouped := ""
	while digits.length() > 3:
		grouped = "," + digits.right(3) + grouped
		digits = digits.left(digits.length() - 3)
	return ("-" if value < 0 else "") + digits + grouped


## The key a mode's records are saved under in the profile.
static func record_key(mode: Mode) -> String:
	return "kudos_attack" if mode == Mode.KUDOS_ATTACK else "free_drive"


static func mode_name(mode: Mode) -> String:
	return "KUDOS ATTACK" if mode == Mode.KUDOS_ATTACK else "FREE DRIVE"
