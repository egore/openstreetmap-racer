class_name RoadMaterialFactory
extends RefCounted

## Builds the surface material for road ribbons. Paved highway types get the
## procedural asphalt ShaderMaterial (grainy albedo, varied roughness, faked
## normal bump driven by world-space noise — see scripts/shaders/asphalt.gdshader);
## unpaved/soft surfaces (footway, path, cycleway, track) keep a plain matte
## StandardMaterial3D since asphalt grain would look wrong on dirt/gravel.
##
## The asphalt Shader resource is preloaded once and shared across every road;
## each road gets its own lightweight ShaderMaterial that only overrides the
## `base_color` uniform with the per-highway-type tint. This keeps draw-call
## state small while letting all roads share one compiled shader.

const ASPHALT_SHADER: Shader = preload("res://scripts/shaders/asphalt.gdshader")
## Depth-writing asphalt variant used by intersection caps (see the shader for
## why the split is necessary).
const ASPHALT_JUNCTION_SHADER: Shader = preload("res://scripts/shaders/asphalt_junction.gdshader")
const RoadProfileScript := preload("res://scripts/road_profile.gd")

## Highway types rendered as plain matte surfaces rather than asphalt.
const UNPAVED_TYPES := {
	"footway": true,
	"path": true,
	"cycleway": true,
	"track": true,
	"pedestrian": true,
}

## Draw-order rank per highway class (higher = painted LATER = on top). Roads are
## kept full-length and overlap at junctions (the Mapnik model); because the
## asphalt does not write depth (see the shader's depth_draw_never), overlapping
## coplanar road quads are resolved purely by this order — so a bigger/more
## important road always paints over the smaller one at a junction, exactly like
## Mapnik draws all casings then fills big-roads-last. Unpaved/soft surfaces rank
## below every paved road so a footway never paints over a carriageway.
##
## Values are used verbatim as Material.render_priority (Godot range -128..127).
const ROAD_RENDER_PRIORITY := {
	"path": 1,
	"footway": 1,
	"cycleway": 2,
	"track": 2,
	"pedestrian": 3,
	"service": 5,
	"living_street": 6,
	"unclassified": 7,
	"residential": 8,
	"tertiary_link": 9,
	"tertiary": 10,
	"secondary_link": 11,
	"secondary": 12,
	"primary_link": 13,
	"primary": 14,
	"trunk_link": 15,
	"trunk": 16,
	"motorway_link": 17,
	"motorway": 18,
}
## Fallback priority for a highway class not in the table above.
const DEFAULT_RENDER_PRIORITY := 7


## Draw-order rank for a highway class (higher paints on top). Exposed so the
## builder can keep the road MESH's render_priority in sync with the material
## (SurfaceTool bakes the material's priority, but the MeshInstance can override).
static func render_priority_for(highway_type: String) -> int:
	return ROAD_RENDER_PRIORITY.get(highway_type, DEFAULT_RENDER_PRIORITY)

## Returns the material for a road of the given highway type, tinted `color`.
## Paved roads receive a procedural-asphalt ShaderMaterial; unpaved/soft
## surfaces fall back to a matte StandardMaterial3D.
##
## When a `lane_spec` and `road_width`/`road_length` are supplied the asphalt
## shader also paints procedural lane markings (centre line, dashed dividers,
## edge lines) from the ribbon UVs — see scripts/shaders/asphalt.gdshader and
## RoadLaneSpec. Passing null keeps a plain (unmarked) asphalt surface.
static func create_road_material(
		highway_type: String,
		color: Color,
		lane_spec: RoadLaneSpec = null,
		road_width: float = 0.0,
		road_length: float = 0.0,
		marking_spec: RoadMarkingSpec = null,
) -> Material:
	var priority := render_priority_for(highway_type)

	if UNPAVED_TYPES.has(highway_type):
		var plain := StandardMaterial3D.new()
		plain.albedo_color = color
		plain.roughness = 1.0
		# Match the asphalt's Mapnik-style layering: full-length overlapping
		# ribbons, resolved by draw order rather than depth, so a footway
		# crossing a road doesn't z-fight it (and stays below it — lower rank).
		plain.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
		plain.render_priority = priority
		return plain

	var mat := ShaderMaterial.new()
	mat.shader = ASPHALT_SHADER
	mat.set_shader_parameter("base_color", color)
	# render_priority orders overlapping (depth-write-disabled) roads so bigger
	# classes paint last/on-top at junctions — the 3D analogue of Mapnik's
	# casing-then-fill layer order.
	mat.render_priority = priority
	_apply_lane_markings(mat, lane_spec, road_width, road_length)
	_apply_transverse_markings(mat, marking_spec, road_width)
	return mat


## Material for a junction cap (the intersection surface itself).
##
## Same procedural asphalt as the ribbons — the crossing must look like the
## roads that feed it — but with lane markings disabled: the cap has no
## along/across parameterisation to paint lines into, and any markings there
## (stop bars, crossings) are emitted as explicit geometry by OSMJunctionBuilder.
##
## Draw rank for intersection caps. Above every road class so that where a cap
## and a ribbon mouth touch, the junction wins the coplanar contest.
##
## This alone was not enough, which is worth recording: render_priority only
## orders TRANSPARENT materials. Opaque surfaces are drawn by distance, so a cap
## that (like the roads) never wrote depth had no way to claim its pixels, and
## the terrain or a landuse polygon drawn afterwards painted straight over the
## intersection — a grass-coloured hole where the junction should be, despite the
## cap mesh being built, in the scene, visible and 24 mm above the ground. Caps
## therefore use their own shader that WRITES depth (asphalt_junction.gdshader).
const JUNCTION_PRIORITY := 30

static func create_junction_material(highway_type: String) -> Material:
	var color: Color = RoadProfileScript.color_for(highway_type)
	if not RoadProfileScript.is_paved(highway_type):
		var plain := StandardMaterial3D.new()
		plain.albedo_color = color
		plain.roughness = 1.0
		# Depth-writing for the same reason as the paved path below: the cap must
		# be able to claim its pixels against the ground it sits on.
		plain.render_priority = JUNCTION_PRIORITY
		return plain

	var mat := ShaderMaterial.new()
	mat.shader = ASPHALT_JUNCTION_SHADER
	mat.set_shader_parameter("base_color", color)
	mat.render_priority = JUNCTION_PRIORITY
	return mat


## Material for painted road markings emitted as explicit geometry (stop bars
## and crossings on junction caps, where the shader's UV-driven markings can't
## reach). Slightly glossier than asphalt, like fresh paint.
static func create_marking_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.85, 0.82, 0.62)
	mat.roughness = 0.55
	# Paint sits on top of every road surface, so it must outrank them all.
	mat.render_priority = 40
	return mat


## Material for kerbs / sidewalks. Shared by the ribbon builder and the junction
## corner builder so a corner is indistinguishable from the pavement leading
## into it.
static func create_sidewalk_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = RoadProfileScript.SIDEWALK_COLOR
	mat.roughness = 0.95
	return mat


## Push a RoadLaneSpec into the asphalt shader's marking uniforms. When the spec
## is null or unmarked, markings stay disabled and the road is plain asphalt.
static func _apply_lane_markings(
		mat: ShaderMaterial,
		lane_spec: RoadLaneSpec,
		road_width: float,
		road_length: float,
) -> void:
	if lane_spec == null or not lane_spec.marked or road_width <= 0.0:
		mat.set_shader_parameter("markings_enabled", 0.0)
		return
	mat.set_shader_parameter("markings_enabled", 1.0)
	mat.set_shader_parameter("road_width", road_width)
	mat.set_shader_parameter("road_length", road_length)
	mat.set_shader_parameter("lane_count", float(lane_spec.lane_count))
	mat.set_shader_parameter("forward_lanes", float(lane_spec.forward_lanes))
	mat.set_shader_parameter("one_way", 1.0 if lane_spec.one_way else 0.0)


## Push a RoadMarkingSpec's transverse markings (crossings, stop/give-way lines)
## into the asphalt shader's uniforms. These are painted independently of the
## lane markings, so a crossing shows even on an undivided road — but they still
## need the carriageway width to span it, so a zero width disables them. When the
## spec is null or empty, transverse_count stays 0 and nothing extra is drawn.
static func _apply_transverse_markings(
		mat: ShaderMaterial,
		marking_spec: RoadMarkingSpec,
		road_width: float,
) -> void:
	if marking_spec == null or marking_spec.is_empty() or road_width <= 0.0:
		mat.set_shader_parameter("transverse_count", 0)
		return
	var along := marking_spec.along_positions()
	var kinds := marking_spec.kinds()
	var facings := marking_spec.facings()
	mat.set_shader_parameter("transverse_count", along.size())
	# The shader arrays are fixed-size (MAX_TRANSVERSE_MARKINGS); passing the
	# packed arrays sets the leading entries and leaves the rest at their
	# defaults, which transverse_count keeps the loop from reading.
	mat.set_shader_parameter("transverse_along", along)
	mat.set_shader_parameter("transverse_kind", kinds)
	mat.set_shader_parameter("transverse_facing", facings)
	# road_width is already set by the lane-marking path, but a road may have
	# crossings without lane markings (e.g. service road); set it here too so
	# the transverse block has a valid carriageway width regardless.
	mat.set_shader_parameter("road_width", road_width)
