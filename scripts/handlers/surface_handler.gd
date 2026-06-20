class_name SurfaceHandler
extends OSMWayHandler

## Closed ways tagged with a physical surface material (surface=paving_stones,
## surface=asphalt, etc.) and no higher-level feature tag that another handler
## would claim. These represent paved plazas, courtyards, pedestrian areas, and
## other hard-surface ground polygons that carry `area=yes` + `surface=*` but no
## landuse/natural/leisure key.
##
## Registered AFTER AreaHandler so it only catches ways that slip through every
## other handler (roads already handle `surface` on highway ways; buildings
## handle their own footprints, etc.).

## Surface material → ground color. Tuned to read as realistic paving seen from
## driving height: warm tones for stone/brick, cool grey for concrete/asphalt.
const SURFACE_COLORS := {
	# Stone / block paving
	"paving_stones": Color(0.55, 0.52, 0.48),
	"sett": Color(0.50, 0.47, 0.43),
	"cobblestone": Color(0.48, 0.45, 0.42),
	"unhewn_cobblestone": Color(0.46, 0.44, 0.41),
	# Concrete / asphalt
	"concrete": Color(0.58, 0.58, 0.56),
	"concrete:plates": Color(0.56, 0.56, 0.54),
	"concrete:lanes": Color(0.56, 0.56, 0.54),
	"asphalt": Color(0.20, 0.20, 0.20),
	# Compacted / loose
	"compacted": Color(0.52, 0.48, 0.40),
	"gravel": Color(0.55, 0.52, 0.46),
	"fine_gravel": Color(0.58, 0.55, 0.48),
	"pebblestone": Color(0.54, 0.52, 0.48),
	# Natural / soft
	"sand": Color(0.72, 0.67, 0.52),
	"ground": Color(0.45, 0.40, 0.32),
	"earth": Color(0.45, 0.38, 0.30),
	"dirt": Color(0.42, 0.36, 0.28),
	"mud": Color(0.35, 0.30, 0.24),
	"grass": Color(0.40, 0.65, 0.30),
	"grass_paver": Color(0.45, 0.58, 0.38),
	# Artificial
	"metal": Color(0.50, 0.50, 0.55),
	"wood": Color(0.50, 0.40, 0.28),
	"tartan": Color(0.55, 0.25, 0.22),
	"rubber": Color(0.30, 0.30, 0.30),
	"acrylic": Color(0.30, 0.45, 0.55),
	# Tile / brick
	"bricks": Color(0.58, 0.38, 0.28),
	"tiles": Color(0.60, 0.55, 0.50),
	"stone": Color(0.52, 0.50, 0.46),
}

const DEFAULT_SURFACE_COLOR := Color(0.50, 0.48, 0.45)


func handler_name() -> String:
	return "surface"


## A way qualifies as a surface area when it is a closed ring AND has a
## `surface` tag but lacks any primary feature key that a more specific handler
## would claim (highway, building, waterway, etc.).
static func is_surface_area(way: OSMParser.OSMWay) -> bool:
	if not way.tags.has("surface"):
		return false
	if not OSMWayHandler.is_closed_way(way):
		return false
	# If a more-specific feature tag is present another handler should have
	# already claimed the way before we ran. Guard against misconfiguration.
	if way.tags.has("highway") or way.tags.has("building") \
			or way.tags.has("building:part") or way.tags.has("railway") \
			or way.tags.has("waterway") or way.tags.has("amenity") \
			or way.tags.has("landuse") or way.tags.has("natural") \
			or way.tags.has("leisure"):
		return false
	return true


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_surface_area(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	var points := PolygonUtils.way_to_points(way.node_ids, ctx.osm_data.nodes)
	var surface_val: String = way.tags.get("surface", "")
	var color: Color = SURFACE_COLORS.get(surface_val, DEFAULT_SURFACE_COLOR)
	var mesh_instance: MeshInstance3D
	if ctx.has_terrain:
		mesh_instance = PolygonUtils.build_terrain_draped_mesh(
			points, color, ctx.osm_data.height_provider, ctx.grid_step, 0.012, ctx.tile_clip)
	else:
		mesh_instance = PolygonUtils.build_flat_polygon_mesh(points, color, 0.012, true)
	if mesh_instance != null:
		mesh_instance.name = "Surface_%d" % way.id
	return mesh_instance
