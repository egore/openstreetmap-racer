class_name CarPaint
extends RefCounted

## Builds and applies physically-based materials to the player car so it reads as
## a real vehicle rather than flat-shaded blockout — the "hero asset" pass that
## pairs with the screen-space reflections enabled in PostProcessing.
##
## The car.blend model ships four named body surfaces plus wheel surfaces:
##
##   Mesh:  "Glas", "Paintjob", "Rear Lights", "Chrome"
##   Wheel: "Tire", "Chrome"
##
## We key off those material *names* (not surface indices) so a re-export that
## reorders surfaces, or a different model that reuses the same names, still gets
## the right treatment. Anything we don't recognise is left untouched.
##
## The star is "Paintjob": a metallic base coat under a clear lacquer
## (clearcoat), which is what gives real car paint its two-layer highlight — a
## broad soft reflection from the flake and a tight sharp glint from the lacquer
## on top. Godot's StandardMaterial3D models this directly with metallic + the
## clearcoat pair, and SSR makes it reflect the actual sky/buildings.
##
## This class is a plain RefCounted with the material construction split out as
## pure builders (build_paint_material, etc.), so tests can assert the resulting
## material properties without a car, a scene tree, or a renderer.

## Material names in the car model, matched case-insensitively/trimmed so a minor
## re-export ("paintjob" vs "Paintjob") still resolves.
const NAME_PAINT := "paintjob"
const NAME_GLASS := "glas"        ## Blender's German-export spelling of "glass".
const NAME_GLASS_ALT := "glass"   ## Accept the English spelling too.
const NAME_LIGHTS := "rear lights"
const NAME_CHROME := "chrome"
const NAME_TIRE := "tire"

## Default body colour if the caller doesn't specify one — a deep racing red.
const DEFAULT_PAINT_COLOR := Color(0.0, 0.393, 0.674, 1.0)

## Paint finish knobs. metallic ~1 with a low base roughness gives the flake its
## sheen; the clearcoat adds the second, sharper reflection layer on top.
const PAINT_METALLIC := 0.9
const PAINT_ROUGHNESS := 0.28
const PAINT_CLEARCOAT := 1.0
const PAINT_CLEARCOAT_ROUGHNESS := 0.06

## Glass: dark, very smooth, slightly see-through, and metallic-ish so SSR gives
## it a strong environment reflection (real automotive glass reads as a mirror at
## grazing angles).
const GLASS_COLOR := Color(0.05, 0.06, 0.08, 0.55)
const GLASS_ROUGHNESS := 0.02
const GLASS_METALLIC := 0.5

## Chrome/trim: a near-perfect mirror. High metallic, near-zero roughness.
const CHROME_COLOR := Color(0.9, 0.9, 0.92)
const CHROME_METALLIC := 1.0
const CHROME_ROUGHNESS := 0.08

## Rear lights: red plastic that glows a little so it blooms under the new
## post-processing at night without being a full light source.
const LIGHTS_COLOR := Color(0.6, 0.03, 0.03)
const LIGHTS_EMISSION := Color(0.8, 0.02, 0.02)
const LIGHTS_EMISSION_ENERGY := 1.6

## Tyre rubber: matte, dark, non-metallic.
const TIRE_COLOR := Color(0.05, 0.05, 0.06)
const TIRE_ROUGHNESS := 0.9


## Applies the full material set to a car mesh subtree. Walks every
## MeshInstance3D under (and including) `root`, and for each surface swaps in the
## PBR material that matches the surface's original material name. Surfaces whose
## names we don't recognise keep whatever they had.
##
## `paint_color` recolours only the body ("Paintjob"); pass a custom colour to
## repaint the car. Returns the number of surfaces that were reassigned (handy
## for tests / sanity logging).
func apply_to(root: Node, paint_color: Color = DEFAULT_PAINT_COLOR) -> int:
	var count := 0
	for mi: MeshInstance3D in _mesh_instances(root):
		count += _apply_to_mesh(mi, paint_color)
	return count


## Resolves the material name of a single surface to a freshly built material, or
## null when the name isn't one we handle (caller leaves the surface alone). Pure
## and side-effect-free so tests can drive it directly with a name string.
func material_for(surface_name: String, paint_color: Color = DEFAULT_PAINT_COLOR) -> Material:
	var key := surface_name.strip_edges().to_lower()
	match key:
		NAME_PAINT:
			return build_paint_material(paint_color)
		NAME_GLASS, NAME_GLASS_ALT:
			return build_glass_material()
		NAME_CHROME:
			return build_chrome_material()
		NAME_LIGHTS:
			return build_lights_material()
		NAME_TIRE:
			return build_tire_material()
		_:
			return null


# --- Material builders (pure) ------------------------------------------------

## Metallic base coat + clear lacquer. This is the hero material.
func build_paint_material(color: Color = DEFAULT_PAINT_COLOR) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "CarPaint_Body"
	m.albedo_color = color
	m.metallic = PAINT_METALLIC
	m.metallic_specular = 0.5
	m.roughness = PAINT_ROUGHNESS
	# The second reflection layer: a thin clear coat over the flake. Low
	# roughness makes its highlight tight and sharp on top of the softer base.
	m.clearcoat_enabled = true
	m.clearcoat = PAINT_CLEARCOAT
	m.clearcoat_roughness = PAINT_CLEARCOAT_ROUGHNESS
	return m


## Dark, smooth, semi-transparent glass with a strong reflection.
func build_glass_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "CarPaint_Glass"
	m.albedo_color = GLASS_COLOR
	m.metallic = GLASS_METALLIC
	m.metallic_specular = 0.9
	m.roughness = GLASS_ROUGHNESS
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	# Windows should be lit from both sides and not cast the flat back-face look.
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


## Near-perfect mirror trim.
func build_chrome_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "CarPaint_Chrome"
	m.albedo_color = CHROME_COLOR
	m.metallic = CHROME_METALLIC
	m.metallic_specular = 1.0
	m.roughness = CHROME_ROUGHNESS
	return m


## Red plastic lenses with a gentle self-glow (blooms at night).
func build_lights_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "CarPaint_RearLights"
	m.albedo_color = LIGHTS_COLOR
	m.roughness = 0.35
	m.emission_enabled = true
	m.emission = LIGHTS_EMISSION
	m.emission_energy_multiplier = LIGHTS_EMISSION_ENERGY
	return m


## Matte black rubber.
func build_tire_material() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.resource_name = "CarPaint_Tire"
	m.albedo_color = TIRE_COLOR
	m.metallic = 0.0
	m.roughness = TIRE_ROUGHNESS
	return m


# --- Internals ---------------------------------------------------------------

## Applies matching materials to every surface of one MeshInstance3D. Reads each
## surface's *current* material name to decide what to swap in, via the surface
## override so we never mutate the shared imported mesh resource.
func _apply_to_mesh(mi: MeshInstance3D, paint_color: Color) -> int:
	var mesh := mi.mesh
	if mesh == null:
		return 0
	var count := 0
	for s: int in range(mesh.get_surface_count()):
		var existing := mi.get_active_material(s)
		var name := ""
		if existing != null:
			name = existing.resource_name
		var replacement := material_for(name, paint_color)
		if replacement != null:
			mi.set_surface_override_material(s, replacement)
			count += 1
	return count


## Depth-first collection of every MeshInstance3D at or under `root`.
func _mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root == null:
		return out
	if root is MeshInstance3D:
		out.append(root)
	for child: Node in root.get_children():
		out.append_array(_mesh_instances(child))
	return out
