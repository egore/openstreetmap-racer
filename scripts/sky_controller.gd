class_name SkyController
extends Node

## Owns the look of the sky and lighting, and blends between a day and a night
## preset on demand.
##
## This is the single source of truth for "what time is it?". It drives three
## things that must stay in agreement for the scene to read correctly:
##   1. the procedural sky shader (gradient, sun disk, cloud tint),
##   2. the DirectionalLight3D that casts the world's shadows (the "sun"), and
##   3. the environment's fog and ambient light.
##
## Keeping all of that here means the rest of the game only has to flip a single
## boolean (or call toggle) — it never has to know which colours, angles or
## energies make up "night". The blend is animated with a Tween so toggling in
## the menu fades smoothly rather than snapping.

## Emitted whenever the target time of day changes (start of a transition), so
## UI can update its label/checkbox immediately without waiting for the fade.
signal day_night_changed(is_day: bool)

## A full description of the sky/light/fog at one instant. Day and night are two
## of these; the controller lerps every field between them to get any blend.
class SkyPreset:
	var zenith_color: Color
	var horizon_color: Color
	var ground_color: Color
	var sun_color: Color
	var sun_energy: float          ## Sky-shader sun disk brightness.
	var cloud_color: Color
	var cloud_shadow_color: Color
	var cloud_coverage: float
	var cloud_opacity: float
	var light_color: Color         ## DirectionalLight3D colour.
	var light_energy: float        ## DirectionalLight3D energy (0 = no sun).
	var sun_angle_deg: float       ## Sun elevation above the horizon, degrees.
	var ambient_color: Color
	var ambient_energy: float
	var fog_color: Color
	var fog_density: float

## Daytime look: bright warm sun high in the sky, soft white clouds, blue dome.
const DAY := {
	"zenith_color": Color(0.18, 0.40, 0.72),
	"horizon_color": Color(0.66, 0.78, 0.90),
	"ground_color": Color(0.34, 0.36, 0.38),
	"sun_color": Color(1.0, 0.95, 0.85),
	"sun_energy": 1.0,
	"cloud_color": Color(1.0, 1.0, 1.0),
	"cloud_shadow_color": Color(0.62, 0.66, 0.72),
	"cloud_coverage": 0.5,
	"cloud_opacity": 1.0,
	"light_color": Color(1.0, 0.96, 0.88),
	"light_energy": 1.3,
	"sun_angle_deg": 55.0,
	"ambient_color": Color(0.6, 0.65, 0.7),
	"ambient_energy": 0.5,
	"fog_color": Color(0.7, 0.75, 0.8),
	"fog_density": 0.002,
}

## Nighttime look: dim cool "moon" low on the horizon, deep blue dome, clouds
## reduced to faint grey wisps lit from below by city haze.
const NIGHT := {
	"zenith_color": Color(0.02, 0.03, 0.08),
	"horizon_color": Color(0.06, 0.08, 0.16),
	"ground_color": Color(0.02, 0.02, 0.04),
	"sun_color": Color(0.55, 0.62, 0.85),
	"sun_energy": 0.25,
	"cloud_color": Color(0.20, 0.23, 0.30),
	"cloud_shadow_color": Color(0.05, 0.06, 0.10),
	"cloud_coverage": 0.45,
	"cloud_opacity": 0.8,
	"light_color": Color(0.55, 0.62, 0.85),
	"light_energy": 0.18,
	"sun_angle_deg": 18.0,
	"ambient_color": Color(0.10, 0.13, 0.22),
	"ambient_energy": 0.35,
	"fog_color": Color(0.05, 0.07, 0.13),
	"fog_density": 0.0035,
}

## Compass heading the sun/moon sits at (degrees). Purely cosmetic — keeps the
## light coming from a consistent direction across both presets.
const SUN_AZIMUTH_DEG := 135.0

## Seconds for the day<->night crossfade when toggled.
const TRANSITION_TIME := 1.5

## Path to the WorldEnvironment whose Environment (sky/fog/ambient) we drive.
## Exported as a NodePath (not a typed node) so the scene file can wire it
## reliably; node-typed exports assigned a NodePath in a .tscn resolve to null.
@export var world_environment_path: NodePath
## Path to the world's key light (the sun/moon).
@export var sun_light_path: NodePath
## Whether the scene starts in daytime.
@export var start_in_day: bool = true

## Resolved from world_environment_path at _ready(); the resource we mutate.
var environment: Environment
## Resolved from sun_light_path at _ready().
var sun_light: DirectionalLight3D

## True when the *target* state is day (set at the moment of toggling, before the
## fade finishes). Read this to know which way things are heading.
var _is_day: bool = true
var _tween: Tween
## The live, interpolated state. We animate this struct's fields and re-apply it
## every step so a mid-transition toggle reverses cleanly from where it is now.
var _current := SkyPreset.new()
var _sky_material: ShaderMaterial


func _ready() -> void:
	# Resolve the wired nodes from their paths, then pull the Environment
	# resource off the WorldEnvironment node so we can mutate sky/fog/ambient.
	var we := get_node_or_null(world_environment_path) as WorldEnvironment
	if we != null:
		environment = we.environment
	sun_light = get_node_or_null(sun_light_path) as DirectionalLight3D

	# Pull the sky shader material out of the environment so we can push uniform
	# values into it. The scene wires a ShaderMaterial-backed Sky onto the env.
	if environment != null and environment.sky != null:
		var mat := environment.sky.sky_material
		if mat is ShaderMaterial:
			_sky_material = mat

	# Snap (no fade) to the starting preset so frame one already looks right.
	_is_day = start_in_day
	_copy_preset_into(_preset_dict(_is_day), _current)
	_apply_current()


## Flips between day and night, animating the transition. Returns the new target
## state (true = day) so callers can update UI without tracking it themselves.
func toggle_day_night() -> bool:
	set_day(not _is_day)
	return _is_day


## Sets the target time of day explicitly. No-op if already heading there.
func set_day(target_is_day: bool) -> void:
	if target_is_day == _is_day and _tween == null:
		return
	_is_day = target_is_day
	day_night_changed.emit(_is_day)
	_start_transition(_preset_dict(_is_day))


## True if the current *target* is daytime.
func is_day() -> bool:
	return _is_day


# --- Internals -------------------------------------------------------------

func _preset_dict(target_is_day: bool) -> Dictionary:
	return DAY if target_is_day else NIGHT


## Kicks off (or restarts) the crossfade toward the given preset. Because we
## tween the fields of the live _current struct from their *current* values, a
## toggle partway through an existing fade smoothly reverses instead of jumping.
func _start_transition(target: Dictionary) -> void:
	if _tween != null and _tween.is_valid():
		_tween.kill()

	var goal := SkyPreset.new()
	_copy_preset_into(target, goal)

	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# Drive a single 0->1 progress value and lerp every field from the snapshot
	# at the start of the fade to the goal. method_callback re-applies each step.
	var from := SkyPreset.new()
	_copy_struct(_current, from)
	_tween.tween_method(
		_blend_step.bind(from, goal), 0.0, 1.0, TRANSITION_TIME
	)


func _blend_step(weight: float, from: SkyPreset, to: SkyPreset) -> void:
	_current.zenith_color = from.zenith_color.lerp(to.zenith_color, weight)
	_current.horizon_color = from.horizon_color.lerp(to.horizon_color, weight)
	_current.ground_color = from.ground_color.lerp(to.ground_color, weight)
	_current.sun_color = from.sun_color.lerp(to.sun_color, weight)
	_current.sun_energy = lerpf(from.sun_energy, to.sun_energy, weight)
	_current.cloud_color = from.cloud_color.lerp(to.cloud_color, weight)
	_current.cloud_shadow_color = from.cloud_shadow_color.lerp(to.cloud_shadow_color, weight)
	_current.cloud_coverage = lerpf(from.cloud_coverage, to.cloud_coverage, weight)
	_current.cloud_opacity = lerpf(from.cloud_opacity, to.cloud_opacity, weight)
	_current.light_color = from.light_color.lerp(to.light_color, weight)
	_current.light_energy = lerpf(from.light_energy, to.light_energy, weight)
	_current.sun_angle_deg = lerpf(from.sun_angle_deg, to.sun_angle_deg, weight)
	_current.ambient_color = from.ambient_color.lerp(to.ambient_color, weight)
	_current.ambient_energy = lerpf(from.ambient_energy, to.ambient_energy, weight)
	_current.fog_color = from.fog_color.lerp(to.fog_color, weight)
	_current.fog_density = lerpf(from.fog_density, to.fog_density, weight)
	_apply_current()


## Pushes the live state onto the sky shader, the sun light and the environment.
func _apply_current() -> void:
	# Sun/moon direction: convert elevation + azimuth into a unit vector, then
	# orient the light to point along it. The sky shader needs the *travel*
	# direction (toward the sky), which is the negation of "up toward the sun".
	var elev := deg_to_rad(_current.sun_angle_deg)
	var azim := deg_to_rad(SUN_AZIMUTH_DEG)
	var to_sun := Vector3(
		cos(elev) * sin(azim),
		sin(elev),
		cos(elev) * cos(azim)
	).normalized()

	if sun_light != null:
		sun_light.light_color = _current.light_color
		sun_light.light_energy = _current.light_energy
		# Light shines opposite to the direction of the sun in the sky.
		sun_light.look_at_from_position(
			sun_light.global_position,
			sun_light.global_position - to_sun,
			Vector3.UP
		)
		# Hide the shadow caster entirely once the moon is too dim to justify it.
		sun_light.shadow_enabled = _current.light_energy > 0.05

	if _sky_material != null:
		_sky_material.set_shader_parameter("zenith_color", _current.zenith_color)
		_sky_material.set_shader_parameter("horizon_color", _current.horizon_color)
		_sky_material.set_shader_parameter("ground_color", _current.ground_color)
		_sky_material.set_shader_parameter("sun_direction", -to_sun)
		_sky_material.set_shader_parameter("sun_color", _current.sun_color)
		_sky_material.set_shader_parameter("sun_energy", _current.sun_energy)
		_sky_material.set_shader_parameter("cloud_color", _current.cloud_color)
		_sky_material.set_shader_parameter("cloud_shadow_color", _current.cloud_shadow_color)
		_sky_material.set_shader_parameter("cloud_coverage", _current.cloud_coverage)
		_sky_material.set_shader_parameter("cloud_opacity", _current.cloud_opacity)

	if environment != null:
		environment.ambient_light_color = _current.ambient_color
		environment.ambient_light_energy = _current.ambient_energy
		environment.fog_light_color = _current.fog_color
		environment.fog_density = _current.fog_density


## Reads a preset dictionary into a SkyPreset struct.
func _copy_preset_into(d: Dictionary, out: SkyPreset) -> void:
	out.zenith_color = d.zenith_color
	out.horizon_color = d.horizon_color
	out.ground_color = d.ground_color
	out.sun_color = d.sun_color
	out.sun_energy = d.sun_energy
	out.cloud_color = d.cloud_color
	out.cloud_shadow_color = d.cloud_shadow_color
	out.cloud_coverage = d.cloud_coverage
	out.cloud_opacity = d.cloud_opacity
	out.light_color = d.light_color
	out.light_energy = d.light_energy
	out.sun_angle_deg = d.sun_angle_deg
	out.ambient_color = d.ambient_color
	out.ambient_energy = d.ambient_energy
	out.fog_color = d.fog_color
	out.fog_density = d.fog_density


## Copies one struct's fields into another (snapshot for tween start state).
func _copy_struct(src: SkyPreset, dst: SkyPreset) -> void:
	dst.zenith_color = src.zenith_color
	dst.horizon_color = src.horizon_color
	dst.ground_color = src.ground_color
	dst.sun_color = src.sun_color
	dst.sun_energy = src.sun_energy
	dst.cloud_color = src.cloud_color
	dst.cloud_shadow_color = src.cloud_shadow_color
	dst.cloud_coverage = src.cloud_coverage
	dst.cloud_opacity = src.cloud_opacity
	dst.light_color = src.light_color
	dst.light_energy = src.light_energy
	dst.sun_angle_deg = src.sun_angle_deg
	dst.ambient_color = src.ambient_color
	dst.ambient_energy = src.ambient_energy
	dst.fog_color = src.fog_color
	dst.fog_density = src.fog_density
