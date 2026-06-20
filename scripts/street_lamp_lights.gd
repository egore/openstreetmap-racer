class_name StreetLampLights
extends Node

## The world's street lamps, switched on together after dark and off by day.
##
## This is the street-lamp counterpart to Headlights: a single component that
## owns one intent — set_on(true/false) — so the rest of the game never has to
## know how many lamps there are or how their glow is wired. The day/night
## controller decides *when* it's dark; this only knows how to be on or off.
##
## Unlike the car's headlights, street lamps don't live in a fixed scene subtree.
## They are placed per OSM tile and stream in and out as the car drives, so this
## controller can't just collect its lights once in _ready(). Instead each tile's
## OSMAssetPlacer registers its lamp lights here as the tile loads, and the
## controller drives every registered group from a single shared brightness level.
##
## That shared level is the crux: a tile that streams in at night must spawn
## already lit (not snap on a moment later), and a tile that streams in mid-fade
## must come up at exactly the fade's current brightness. New registrations are
## therefore applied at the live level immediately, and the global fade walks
## that level for everything at once.

## Seconds for the lamps to fade fully on or off. Slightly slower than the car's
## headlights so a whole street easing on reads as ambient dusk rather than a
## switch being thrown.
const FADE_TIME := 1.2

## One tile's worth of street-lamp lights. Holds the OmniLight3D point lights and
## the emissive bulb materials so both the cast light and the visible glow of the
## bulb pulse together. Kept as a plain bucket the placer fills and hands over.
class LampGroup:
	## The point lights that throw a pool of light on the road under each lamp.
	var lights: Array[OmniLight3D] = []
	## Per-bulb emissive materials, driven so the lamp head itself glows.
	var materials: Array[StandardMaterial3D] = []
	## Energy each OmniLight3D reaches when fully on (captured at register time so
	## the per-lamp authored brightness survives the global 0..1 fade).
	var light_energy: float = 0.0
	## Emission multiplier each bulb material reaches when fully on.
	var glow_energy: float = 0.0
	## Tint of this group's cast light and bulb glow, resolved from the lamp's OSM
	## tags (light:colour / lamp_type) at build time so a sodium street glows
	## orange while an LED street stays white. White by default.
	var color: Color = Color.WHITE

## Live groups, keyed by the tile root Node they belong to. Keyed by the node so
## a tile unloading can drop its group in O(1) without scanning, and freed tiles
## self-evict (see _prune_freed).
var _groups: Dictionary = {}  # Node -> LampGroup

## Target state: true once the lamps are meant to be on (set the instant the sky
## starts turning to night, before the fade finishes).
var _on: bool = false
## Live 0..1 brightness shared by every group. New tiles register at this value.
var _level: float = 0.0
var _tween: Tween


## Switches every street lamp on or off, fading over FADE_TIME. No-op if already
## in (or heading to) the requested state.
func set_on(on: bool) -> void:
	if on == _on:
		return
	_on = on
	if _tween != null and _tween.is_valid():
		_tween.kill()
	_tween = create_tween()
	_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var target := 1.0 if on else 0.0
	_tween.tween_method(_set_level, _level, target, FADE_TIME)


## True when the lamps are on (or fading on).
func is_on() -> bool:
	return _on


## Registers one tile's lamp lights and brings them straight to the current
## brightness, so a tile streaming in at night (or mid-fade) is already correctly
## lit instead of popping on a frame later. The group is keyed by `owner` (the
## tile root) so unregister_tile() can drop it when the tile unloads.
func register_tile(owner: Node, group: LampGroup) -> void:
	if owner == null or group == null:
		return
	_groups[owner] = group
	_apply_to_group(group, _level)


## Drops a tile's lamp lights when its tile unloads. Safe to call for a tile that
## was never registered (a tile with no street lamps), which keeps the tile
## manager's unload path branch-free.
func unregister_tile(owner: Node) -> void:
	_groups.erase(owner)


# --- Internals -------------------------------------------------------------

## Applies a 0..1 brightness to every registered group and remembers it as the
## live level so subsequently-registered tiles match. Prunes any groups whose
## tile was freed out from under us first.
func _set_level(level: float) -> void:
	_level = level
	_prune_freed()
	for owner: Node in _groups:
		_apply_to_group(_groups[owner], level)


## Drives one group's lights and bulb glow to the given level. level 0 also
## disables the point lights entirely so an off lamp costs nothing to render.
func _apply_to_group(group: LampGroup, level: float) -> void:
	var lit := level > 0.001
	for light in group.lights:
		if is_instance_valid(light):
			light.light_color = group.color
			light.light_energy = group.light_energy * level
			light.visible = lit
	for mat in group.materials:
		mat.emission = group.color
		mat.emission_enabled = lit
		mat.emission_energy_multiplier = group.glow_energy * level


## A tile can be queue_free()'d before its unregister_tile() runs (or without one
## at all). Drop any groups whose owning node has been freed so we never touch a
## dangling light.
func _prune_freed() -> void:
	var dead: Array[Node] = []
	for owner: Node in _groups:
		if not is_instance_valid(owner):
			dead.append(owner)
	for owner: Node in dead:
		_groups.erase(owner)
