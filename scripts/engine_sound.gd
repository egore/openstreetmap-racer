class_name EngineSound
extends Node

## Plays a real engine recording, controlling the playback position to
## match the car's current RPM.  The source MP3 contains a gear sweep
## followed by a natural gear shift (with the characteristic RPM drop-off
## howl).  During normal driving the playback head tracks a position in the
## sweep proportional to the within-gear RPM.  When the transmission shifts,
## the gear-shift section plays through naturally so the player hears the
## turbo overrun / engine howl.
##
## Two regions of the recording are used:
##   SWEEP  — a smooth, continuous RPM ramp (the car accelerating in gear)
##   SHIFT  — the moment the gear changes: RPM peaks then drops rapidly
##
## Usage:  create one EngineSound, add_child it to the car, and call
##         update_engine() every physics frame.

const SOUND_PATH := "res://sounds/car_engine.mp3"

## ── Sweep region ────────────────────────────────────────────────────────
## 5.45 s – 8.20 s: clean RPM ramp from ~39 Hz to ~50 Hz fundamental.
## This is the longest, loudest, highest-confidence sweep in the recording.
const SWEEP_START := 5.45
const SWEEP_END := 8.20

## ── Shift region ────────────────────────────────────────────────────────
## 8.20 s – 8.90 s: the natural gear shift — RPM peaks then drops with
## the characteristic overrun howl.  Played once during a gear change.
const SHIFT_START := 8.20
const SHIFT_END := 8.90

## Volume envelope (dB).
const VOLUME_IDLE_DB := -14.0
const VOLUME_MAX_DB := -4.0

## How far (seconds) the playback head can drift from its target position
## in the sweep before we seek to correct it.  Larger = more natural
## (the recording plays forward continuously), smaller = tighter RPM
## tracking.  0.15 s is about one engine cycle at low RPM.
const DRIFT_TOLERANCE := 0.15

var _player: AudioStreamPlayer = null

## When true the engine audio is completely silenced (player stopped).
## Used by the pause menu so the engine doesn't drone while the game is paused.
var _muted: bool = false

## State machine: SWEEP (normal driving) or SHIFT (playing the gear-shift
## section, then returning to SWEEP).
enum State { SWEEP, SHIFT }
var _state: State = State.SWEEP

## The gear index from the previous frame, to detect gear changes.
var _prev_gear: int = Transmission.GEAR_NEUTRAL


func _ready() -> void:
	_player = AudioStreamPlayer.new()
	_player.name = "EngineSoundPlayer"
	_player.bus = &"Master"
	_player.volume_db = VOLUME_IDLE_DB
	# Stop the engine sound when the scene tree is paused (pause menu).
	_player.process_mode = Node.PROCESS_MODE_PAUSABLE
	var stream := load(SOUND_PATH)
	if stream is AudioStream:
		_player.stream = stream
	else:
		push_warning("EngineSound: could not load %s" % SOUND_PATH)
	add_child(_player)


## Call every physics frame.
##
## - speed_kmh:  unsigned car speed in km/h.
## - gear:       current gear index from Transmission.
## - gear_ratio: 0-1 position within the current gear band.
func update_engine(speed_kmh: float, gear: int, gear_ratio: float) -> void:
	if _player == null or _player.stream == null:
		return
	if _muted:
		return

	var moving := gear != Transmission.GEAR_NEUTRAL and speed_kmh > 1.0

	# Volume: ramp with overall speed.
	var speed_factor := clampf(speed_kmh / 180.0, 0.0, 1.0)
	_player.volume_db = lerpf(VOLUME_IDLE_DB, VOLUME_MAX_DB, speed_factor)

	# Detect gear shifts (only upshifts in forward gears trigger the howl).
	if gear > 0 and _prev_gear > 0 and gear > _prev_gear:
		_state = State.SHIFT
		if _player.playing:
			_player.seek(SHIFT_START)
	_prev_gear = gear

	# Ensure the player is running.
	if not _player.playing:
		_player.play(SWEEP_START)
		_state = State.SWEEP

	var pos := _player.get_playback_position()

	match _state:
		State.SHIFT:
			# Let the shift section play through naturally.
			if pos >= SHIFT_END or pos < SHIFT_START:
				# Shift sound finished — return to sweep at the current RPM.
				_state = State.SWEEP
				var target := _sweep_position_for_ratio(
					clampf(gear_ratio, 0.0, 1.0) if moving else 0.0)
				_player.seek(target)

		State.SWEEP:
			var ratio := clampf(gear_ratio, 0.0, 1.0) if moving else 0.0
			var target := _sweep_position_for_ratio(ratio)

			# If the head has drifted outside the sweep or too far from the
			# target position, nudge it back.
			if pos < SWEEP_START or pos >= SWEEP_END:
				_player.seek(target)
			elif absf(pos - target) > DRIFT_TOLERANCE:
				_player.seek(target)
			# Otherwise let it play forward naturally — the real recording
			# has the most authentic texture when it runs uninterrupted.


## Silence or restore the engine audio. Call with `true` when entering the
## pause menu and `false` when resuming. Stopping the player (rather than
## just pausing it) avoids the sustained mid-sample drone that
## PROCESS_MODE_PAUSABLE would leave behind.
func set_muted(muted: bool) -> void:
	_muted = muted
	if _player == null:
		return
	if muted:
		_player.stop()
	# When un-muted the player restarts naturally on the next update_engine()
	# call because that method already handles the not-playing case.


## Map gear_ratio 0..1 to a playback position inside the sweep region.
func _sweep_position_for_ratio(ratio: float) -> float:
	return lerpf(SWEEP_START, SWEEP_END, ratio)
