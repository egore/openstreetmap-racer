class_name Headlights
extends Node3D

## The car's headlights: a pair of forward-facing spot beams plus the glowing
## lamp faces on the car body, switched on together as one unit.
##
## This is a self-contained component that sits under the car and exposes a
## single intent — set_on(true/false) — so the rest of the game never has to
## know how many lights there are or how the lamp glow is wired. The day/night
## controller decides *when* it's dark; this only knows how to be on or off.
##
## Turning on/off is faded rather than snapped so the beams swell up and die
## down like real bulbs warming/cooling, which reads far better than a hard pop
## when the sky crossfades between day and night.

## Seconds for the headlights to fade fully on or off.
const FADE_TIME := 0.8

## Brightness (light_energy) of each spot beam when fully on. Tuned to throw a
## visible pool of light on the road at night without blowing out the exposure.
@export var beam_energy: float = 6.0
## Emission energy of the lamp faces when fully on (the visible "glow" of the
## bulb itself, separate from the beam it casts).
@export var lamp_glow_energy: float = 4.0

## The forward-facing spot beams. Found automatically among the children.
var _beams: Array[SpotLight3D] = []
## The lamp-face meshes whose material emission we pulse on/off.
var _lamp_meshes: Array[MeshInstance3D] = []
## Per-lamp emissive materials, made unique per instance so toggling the glow on
## one car never bleeds into a shared material used elsewhere.
var _lamp_materials: Array[StandardMaterial3D] = []

var _on: bool = false
var _tween: Tween


func _ready() -> void:
	# Collect the lights and lamp faces from the scene subtree so the scene file
	# stays the single source of truth for *where* the lights are; this script
	# only cares that they exist.
	for child in _all_descendants(self):
		if child is SpotLight3D:
			_beams.append(child as SpotLight3D)
		elif child is MeshInstance3D:
			var mesh := child as MeshInstance3D
			# Give each lamp face its own material instance and capture it so we
			# can drive emission_energy_multiplier without touching the shared
			# resource the .tscn authored.
			var mat := mesh.get_active_material(0)
			if mat is StandardMaterial3D:
				var unique := (mat as StandardMaterial3D).duplicate() as StandardMaterial3D
				mesh.set_surface_override_material(0, unique)
				_lamp_meshes.append(mesh)
				_lamp_materials.append(unique)

	# Start fully off, no fade, so a daytime spawn shows dark lamps immediately.
	_apply_level(0.0)


## Switches the headlights on or off, fading over FADE_TIME. No-op if already in
## (or heading to) the requested state.
func set_on(on: bool) -> void:
	if on == _on:
		return
	_on = on
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var target := 1.0 if on else 0.0
	_tween.tween_method(_apply_level, _current_level(), target, FADE_TIME)


## True when the headlights are on (or fading on).
func is_on() -> bool:
	return _on


# --- Internals -------------------------------------------------------------

## Reads back the current fade level from a beam so a mid-fade reverse starts
## from where the lights actually are, not from a snapped 0/1.
func _current_level() -> float:
	if _beams.is_empty() or beam_energy <= 0.0:
		return 1.0 if _on else 0.0
	return clampf(_beams[0].light_energy / beam_energy, 0.0, 1.0)


## Applies a 0..1 brightness level to every beam and lamp face. level 0 also
## disables the spot lights entirely so an off headlight costs nothing to render.
func _apply_level(level: float) -> void:
	var lit := level > 0.001
	for beam in _beams:
		beam.light_energy = beam_energy * level
		beam.visible = lit
	for i in _lamp_meshes.size():
		# Hide the lamp face entirely when off so it's the glow that's visible,
		# never the bare box. Only the emission shows it once the lights warm up.
		_lamp_meshes[i].visible = lit
	for mat in _lamp_materials:
		mat.emission_enabled = lit
		mat.emission_energy_multiplier = lamp_glow_energy * level


func _all_descendants(node: Node) -> Array[Node]:
	var out: Array[Node] = []
	for child in node.get_children():
		out.append(child)
		out.append_array(_all_descendants(child))
	return out
