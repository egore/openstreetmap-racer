class_name WeatherController
extends Node

## Owns the world's wetness and drives it into the surface shaders.
##
## This is the "wet track" toggle: flip the world between dry and rain-soaked and
## the roads darken and turn to near-mirrors (so the SSR from PostProcessing
## paints the sky and lights onto them), while the grass gains a damp sheen. It
## is the counterpart to SkyController (time of day) and StreetLampLights — a
## single component owning one intent so nothing else has to know how "wet" is
## wired.
##
## The mechanism is a single global shader uniform, `wetness` (0 = dry, 1 =
## soaked), declared in project.godot's [shader_globals] and read by
## asphalt.gdshader and terrain.gdshader. Setting one global value reaches every
## road and ground tile at once — including ones that stream in later — without
## the CPU ever touching an individual material. That is the whole reason for the
## global-uniform approach over per-material tracking (roads spawn a fresh
## ShaderMaterial each; chasing them all would be far more code and slower).
##
## Transitions are tweened so rain "rolls in" over a couple of seconds rather than
## snapping. The value write is funnelled through a small sink (_apply_level) so
## tests can capture the level without a live RenderingServer.

## Name of the global shader uniform (must match [shader_globals] in
## project.godot and the `global uniform float wetness;` in the shaders).
const GLOBAL_UNIFORM := &"wetness"

## Seconds for a full dry<->wet transition. A touch slow so it reads as weather
## changing, not a switch.
const TRANSITION_TIME := 3.0

## Wetness level when "wet". Kept just under 1.0 so the road kramp doesn't go to a
## perfect mirror (which looks unnaturally glassy and exaggerates SSR artefacts).
const WET_LEVEL := 0.9
const DRY_LEVEL := 0.0

## Whether the world starts wet. Frame-one value; toggled at runtime.
@export var start_wet: bool = false

## Target state: true once the world is meant to be wet (set the instant a
## transition begins, before the tween finishes).
var _wet: bool = false
## Live 0..1 wetness, animated by the tween and pushed to the global uniform.
var _level: float = 0.0
var _tween: Tween


func _ready() -> void:
	_wet = start_wet
	_level = WET_LEVEL if _wet else DRY_LEVEL
	_apply_level(_level)


## Flips between dry and wet, tweening the transition. Returns the new target
## state (true = wet) so callers can update UI without tracking it.
func toggle() -> bool:
	set_wet(not _wet)
	return _wet


## Sets the target wetness explicitly. No-op if already in (or heading to) that
## state and not mid-transition.
func set_wet(wet: bool) -> void:
	if wet == _wet and _tween == null:
		return
	_wet = wet
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var target := WET_LEVEL if wet else DRY_LEVEL
	_tween.tween_method(_apply_level, _level, target, TRANSITION_TIME)


## True when the world is wet (or turning wet).
func is_wet() -> bool:
	return _wet


## The live wetness level (0..1). Exposed for tests / debugging.
func get_level() -> float:
	return _level


# --- Internals -------------------------------------------------------------

## Store the live level and push it to the global shader uniform. Overridable /
## observable by tests (which check _level) without needing the RenderingServer;
## the RenderingServer call is a no-op cost when the global isn't registered, so
## it's safe to run headless too.
func _apply_level(level: float) -> void:
	_level = clampf(level, 0.0, 1.0)
	RenderingServer.global_shader_parameter_set(GLOBAL_UNIFORM, _level)
