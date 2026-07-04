class_name BuildingMaterialFactory
extends RefCounted

## Builds the procedural-PBR surface materials for building walls and roofs, the
## building-side analogue of RoadMaterialFactory.
##
## Walls and roofs keep their per-building tint (resolved by OSMBuildingBuilder
## from the colour/material tags), but instead of a flat StandardMaterial3D they
## get a ShaderMaterial backed by building_wall.gdshader / roof.gdshader. Those
## shaders fake masonry courses / tile rows / panel seams and a micro-normal from
## world-space noise — no texture files, matching the asphalt shader's approach —
## so the buildings catch light and reflect the sky (under SSR) like real
## surfaces rather than reading as flat blockout.
##
## The one bit of interpretation this class owns is the "surface kind": mapping an
## OSM building:material / roof:material value onto one of the shader's three
## looks (smooth / masonry / panel for walls; tiles / flat / metal for roofs).
## That mapping is pure and table-driven, so it is unit-tested directly without
## building any geometry.
##
## The shaders are preloaded once and shared; each building gets a lightweight
## ShaderMaterial that only overrides `base_color` and `surface_kind`.

const WALL_SHADER: Shader = preload("res://scripts/shaders/building_wall.gdshader")
const ROOF_SHADER: Shader = preload("res://scripts/shaders/roof.gdshader")

## Wall surface kinds (must match building_wall.gdshader's `surface_kind`).
enum WallKind { SMOOTH = 0, MASONRY = 1, PANEL = 2 }
## Roof surface kinds (must match roof.gdshader's `surface_kind`).
enum RoofKind { TILES = 0, FLAT = 1, METAL = 2 }

## OSM building:material → wall kind. Anything not listed falls back to SMOOTH
## (plaster/render is the most common default and the most forgiving look).
const WALL_KIND_BY_MATERIAL := {
	"brick": WallKind.MASONRY,
	"stone": WallKind.MASONRY,
	"sandstone": WallKind.MASONRY,
	"limestone": WallKind.MASONRY,
	"granite": WallKind.MASONRY,
	"marble": WallKind.MASONRY,
	"cement_block": WallKind.MASONRY,
	"concrete": WallKind.PANEL,
	"metal": WallKind.PANEL,
	"steel": WallKind.PANEL,
	"glass": WallKind.PANEL,
	"plaster": WallKind.SMOOTH,
	"render": WallKind.SMOOTH,
	"stucco": WallKind.SMOOTH,
	"wood": WallKind.SMOOTH,
}

## OSM roof:material → roof kind. Unlisted falls back to TILES (the commonest
## pitched-roof covering; on a flat roof the rows simply read as a subtle grain).
const ROOF_KIND_BY_MATERIAL := {
	"roof_tiles": RoofKind.TILES,
	"tile": RoofKind.TILES,
	"tiles": RoofKind.TILES,
	"thatch": RoofKind.TILES,
	"slate": RoofKind.TILES,
	"metal": RoofKind.METAL,
	"zinc": RoofKind.METAL,
	"tin": RoofKind.METAL,
	"copper": RoofKind.METAL,
	"eternit": RoofKind.FLAT,
	"tar_paper": RoofKind.FLAT,
	"gravel": RoofKind.FLAT,
	"grass": RoofKind.FLAT,
	"concrete": RoofKind.FLAT,
	"glass": RoofKind.FLAT,
}


## Resolve an OSM building:material string to a wall kind. Case-insensitive and
## whitespace-trimmed; empty / unknown → SMOOTH.
static func wall_kind_for(material: String) -> WallKind:
	var key := material.strip_edges().to_lower()
	return WALL_KIND_BY_MATERIAL.get(key, WallKind.SMOOTH)


## Resolve an OSM roof:material string to a roof kind. Empty / unknown → TILES.
static func roof_kind_for(material: String) -> RoofKind:
	var key := material.strip_edges().to_lower()
	return ROOF_KIND_BY_MATERIAL.get(key, RoofKind.TILES)


## Build a wall ShaderMaterial tinted `color` with the given kind.
static func create_wall_material(color: Color, kind: WallKind = WallKind.SMOOTH) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = WALL_SHADER
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("surface_kind", float(kind))
	return mat


## Build a roof ShaderMaterial tinted `color` with the given kind.
static func create_roof_material(color: Color, kind: RoofKind = RoofKind.TILES) -> ShaderMaterial:
	var mat := ShaderMaterial.new()
	mat.shader = ROOF_SHADER
	mat.set_shader_parameter("base_color", color)
	mat.set_shader_parameter("surface_kind", float(kind))
	return mat


## Apply procedural materials across a finished building subtree. Walks every
## MeshInstance3D under `root` and assigns a wall or roof ShaderMaterial via
## material_override, choosing by node name:
##
##   "Roof"                                  → roof shader (roof_kind)
##   "Walls" / "Gables" / "*Walls" (skillion,
##      sawtooth) / anything else            → wall shader (wall_kind)
##
## Uses material_override so the geometry code (which bakes a flat StandardMaterial
## as a fallback tint) stays untouched and the shared meshes are never mutated.
## Colours are read from each mesh's existing material so the per-building /
## per-roof tints resolved by OSMBuildingBuilder carry straight through.
##
## Returns the number of meshes reassigned (for tests / logging).
static func apply_to_building(root: Node, wall_kind: WallKind, roof_kind: RoofKind) -> int:
	var count := 0
	for mi: MeshInstance3D in _mesh_instances(root):
		var color := _existing_color(mi)
		if mi.name == "Roof":
			mi.material_override = create_roof_material(color, roof_kind)
		else:
			mi.material_override = create_wall_material(color, wall_kind)
		count += 1
	return count


# --- Internals ---------------------------------------------------------------

## The tint baked onto a mesh's first surface material (StandardMaterial3D from
## the geometry builders). Falls back to white if none is present.
static func _existing_color(mi: MeshInstance3D) -> Color:
	var mat := mi.get_active_material(0)
	if mat is StandardMaterial3D:
		return (mat as StandardMaterial3D).albedo_color
	if mat is ShaderMaterial:
		var p = (mat as ShaderMaterial).get_shader_parameter("base_color")
		if p is Color:
			return p
	return Color.WHITE


static func _mesh_instances(root: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root == null:
		return out
	if root is MeshInstance3D:
		out.append(root)
	for child: Node in root.get_children():
		out.append_array(_mesh_instances(child))
	return out
