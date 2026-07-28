class_name SpeedBlur
extends ColorRect

## Drives the radial speed-blur shader from the car's speed.
##
## The last of the "sense of speed" cues: the camera FOV already widens with speed
## and the engine note rises, but the image itself stays perfectly sharp at 200
## km/h, which subconsciously reads as slow. Smearing the edges of the frame while
## leaving the centre crisp is what sells velocity — it is the effect every racing
## game reaches for.
##
## This node is a full-screen ColorRect running scripts/shaders/speed_blur.gdshader,
## which reads the rendered frame through SCREEN_TEXTURE. Two placement rules
## matter and are enforced in _ready:
##
##   * It must cover the viewport, or the blur would only affect part of the frame.
##   * It must never intercept mouse input, or it would swallow every click meant
##     for the game or the pause menu underneath it.
##
## It is also expected to sit *below* the HUD in the scene tree, so the instrument
## cluster stays sharp; blurring the player's own dials would look like a bug
## rather than an effect.
##
## The speed→strength curve lives here rather than in the shader so it can be
## tuned and unit-tested without a GPU.

## Speed (km/h) below which there is no blur at all. Town driving should look
## completely clean; the effect is a high-speed reward, not a permanent filter.
@export var start_speed_kmh: float = 90.0

## Speed (km/h) at which the blur reaches full strength. Above this it stops
## growing, so the frame never degrades further no matter how fast the car goes.
@export var full_speed_kmh: float = 200.0

## Blur strength at full speed, 0..1. Deliberately well below 1: the effect
## should be felt more than seen. Anything stronger starts to look like a smeared
## screenshot rather than motion.
@export var max_strength: float = 0.55

## Shapes the ramp between start_speed_kmh and full_speed_kmh. Above 1 keeps the
## effect subtle through the mid range and saves most of it for genuinely high
## speed, which is what makes the top end feel like an event.
@export var curve_exponent: float = 1.6

## How quickly the strength follows the target (per-second lerp weight). Smoothing
## stops the blur from flickering when speed oscillates — most visibly during a
## crash, where an instant drop to zero would look like a glitch.
@export var response: float = 3.0

## Master toggle. When off the shader is driven to zero (and early-outs), so this
## is also the way to A/B the effect's frame cost.
@export var enabled: bool = true

## The shader uniform currently applied. Kept so the ramp can be smoothed frame to
## frame, and so tests can read back what was computed.
var _strength: float = 0.0

## Name of the shader uniform this node writes. Centralised so a rename cannot
## silently desync the script from the shader.
const STRENGTH_UNIFORM := &"strength"


func _ready() -> void:
	# Cover the whole viewport and follow it through resolution changes.
	set_anchors_preset(Control.PRESET_FULL_RECT)
	# A full-screen overlay that accepted input would block every click beneath it.
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The effect is purely cosmetic, so it should keep rendering while the game is
	# paused (the frame behind the pause menu stays as it was) but never block.
	_apply_strength(0.0)


## Update the blur from the car's current speed. Wired to CarController.speed_changed.
## delta is taken separately so the smoothing is frame-rate independent.
func update_speed(speed_kmh: float, delta: float) -> void:
	# A zero-length frame (paused, or the first frame) must leave the effect where
	# it is: no time has passed, so nothing can have changed. Snapping to the
	# target here would make the blur jump the moment the game is paused.
	if delta <= 0.0:
		return

	var target := 0.0 if not enabled else strength_for_speed(speed_kmh)
	# A response of 0 disables smoothing entirely, which is a legitimate setting
	# (an instant, unsmoothed effect) rather than a paused frame.
	if response <= 0.0:
		_strength = target
	else:
		_strength = lerpf(_strength, target, clampf(response * delta, 0.0, 1.0))
	_apply_strength(_strength)


## The blur strength (0..max_strength) for a given speed, before smoothing.
##
## Zero below start_speed_kmh, then ramps along curve_exponent to max_strength at
## full_speed_kmh and holds there. Exposed separately so the curve can be tested
## and tuned without a viewport or a shader.
func strength_for_speed(speed_kmh: float) -> float:
	var speed := absf(speed_kmh)
	if speed <= start_speed_kmh:
		return 0.0
	if full_speed_kmh <= start_speed_kmh:
		return max_strength
	var t := clampf((speed - start_speed_kmh) / (full_speed_kmh - start_speed_kmh), 0.0, 1.0)
	return pow(t, curve_exponent) * max_strength


## The strength currently pushed to the shader, for tests and debugging.
func get_strength() -> float:
	return _strength


## Reset the effect to clear. Called on respawn so a blur from the previous run
## does not linger over a stationary car.
func reset() -> void:
	_strength = 0.0
	_apply_strength(0.0)


## Write the strength to the shader, if one is assigned. Guarded so the node is
## harmless in a scene where the material has not been set up (and so tests can
## exercise the curve without a GPU material).
func _apply_strength(value: float) -> void:
	var shader_material := material as ShaderMaterial
	if shader_material == null:
		return
	shader_material.set_shader_parameter(STRENGTH_UNIFORM, value)
