class_name OSMWayBuilder
extends RefCounted

## Builds terrain-draped ribbon meshes from linear OSM ways: roads (highway=*),
## waterways (waterway=*), and railways (railway=*). All three share the miter-
## joined ribbon edge math and DEM-following subdivision below. Elevated
## structures that ride above the ground (power lines, gantries) live in
## OSMInfrastructureBuilder instead.

## Terrain parameters set by the tile manager. When a HeightProvider is
## available, polyline points are subdivided so road/waterway/railway ribbons
## follow the DEM instead of linearly interpolating between sparse OSM nodes.
var height_provider: HeightProvider = null
var terrain_grid_step: float = 0.0

# Road width in meters based on highway type
const ROAD_WIDTHS := {
	"motorway": 12.0,
	"motorway_link": 6.0,
	"trunk": 10.0,
	"trunk_link": 5.0,
	"primary": 8.0,
	"primary_link": 4.5,
	"secondary": 7.0,
	"secondary_link": 4.0,
	"tertiary": 6.0,
	"tertiary_link": 3.5,
	"residential": 5.0,
	"living_street": 4.0,
	"service": 3.0,
	"unclassified": 5.0,
	"pedestrian": 3.0,
	"footway": 1.5,
	"cycleway": 2.0,
	"path": 1.0,
	"track": 3.0,
}

const ROAD_COLORS := {
	"motorway": Color(0.4, 0.4, 0.45),
	"motorway_link": Color(0.4, 0.4, 0.45),
	"trunk": Color(0.42, 0.42, 0.44),
	"trunk_link": Color(0.42, 0.42, 0.44),
	"primary": Color(0.45, 0.44, 0.42),
	"primary_link": Color(0.45, 0.44, 0.42),
	"secondary": Color(0.5, 0.5, 0.48),
	"secondary_link": Color(0.5, 0.5, 0.48),
	"tertiary": Color(0.52, 0.52, 0.5),
	"tertiary_link": Color(0.52, 0.52, 0.5),
	"residential": Color(0.55, 0.55, 0.53),
	"living_street": Color(0.6, 0.58, 0.55),
	"service": Color(0.58, 0.57, 0.55),
	"footway": Color(0.65, 0.6, 0.5),
	"cycleway": Color(0.5, 0.55, 0.6),
	"path": Color(0.6, 0.55, 0.45),
	"pedestrian": Color(0.62, 0.6, 0.55),
}

const DEFAULT_WIDTH := 4.0
const DEFAULT_COLOR := Color(0.5, 0.5, 0.5)
const ROAD_Y := 0.02  # slightly above ground
const SIDEWALK_WIDTH := 1.5
const SIDEWALK_HEIGHT := 0.10
const SIDEWALK_COLOR := Color(0.68, 0.68, 0.66)
const SIDEWALK_BASE_Y := 0.0

func build_road(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

	if points.size() < 2:
		return null

	# Subdivide long segments so the ribbon follows the terrain.
	if terrain_grid_step > 0.0:
		points = PolygonUtils.subdivide_polyline_to_terrain(
			points, height_provider, terrain_grid_step)

	var highway_type: String = way.tags.get("highway", "unclassified")
	var width: float = ROAD_WIDTHS.get(highway_type, DEFAULT_WIDTH)
	var color: Color = ROAD_COLORS.get(highway_type, DEFAULT_COLOR)

	# Check for lanes tag to adjust width based on lane count
	if way.tags.has("lanes"):
		var lanes: int = way.tags["lanes"].to_int()
		if lanes > 0:
			width = lanes * 3.5

	# Explicit width tag takes highest precedence (width excluding sidewalk)
	if way.tags.has("width"):
		var explicit_width: float = way.tags["width"].to_float()
		if explicit_width > 0.0:
			width = explicit_width

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Road_%d" % way.id

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	var sidewalk_st := SurfaceTool.new()
	sidewalk_st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var sidewalk_mat := StandardMaterial3D.new()
	sidewalk_mat.albedo_color = SIDEWALK_COLOR
	sidewalk_st.set_material(sidewalk_mat)

	# Build a ribbon mesh along the polyline using miter joins at bends
	var half_w := width / 2.0
	var sidewalk_sides := _get_sidewalk_sides(way.tags)
	var has_left_sidewalk: bool = sidewalk_sides["left"]
	var has_right_sidewalk: bool = sidewalk_sides["right"]
	var miter_limit := 2.0  # clamp miter to avoid spikes on very sharp turns

	# Pre-compute the left and right edge vertices for each point using miter joins.
	# At interior points the miter bisects the angle between adjacent segments so that
	# both segments share the same edge vertices, eliminating gaps and overlaps.
	var n_pts := points.size()
	var left_edge: Array = []
	var right_edge: Array = []

	for i: int in range(n_pts):
		var pt := points[i]
		var offset: Vector3
		if i == 0:
			# First point: use the direction of the first segment
			var fwd := (points[1] - points[0]).normalized()
			var lateral := Vector3(-fwd.z, 0.0, fwd.x).normalized()
			offset = lateral * half_w
		elif i == n_pts - 1:
			# Last point: use the direction of the last segment
			var fwd := (points[i] - points[i - 1]).normalized()
			var lateral := Vector3(-fwd.z, 0.0, fwd.x).normalized()
			offset = lateral * half_w
		else:
			# Interior point: compute miter join
			var fwd_prev := (points[i] - points[i - 1]).normalized()
			var fwd_next := (points[i + 1] - points[i]).normalized()
			var lat_prev := Vector3(-fwd_prev.z, 0.0, fwd_prev.x).normalized()
			var lat_next := Vector3(-fwd_next.z, 0.0, fwd_next.x).normalized()
			# Miter direction is the average of the two lateral directions
			var miter_dir := (lat_prev + lat_next)
			if miter_dir.length_squared() < 0.0001:
				# Segments are nearly antiparallel (U-turn) — fall back to previous lateral
				miter_dir = lat_prev
			else:
				miter_dir = miter_dir.normalized()
			# Scale miter to maintain correct width: half_w / dot(miter, lateral)
			var d := miter_dir.dot(lat_prev)
			var miter_len := half_w
			if absf(d) > 0.0001:
				miter_len = half_w / d
			# Clamp miter length to prevent extreme spikes at sharp angles
			miter_len = clampf(miter_len, half_w, half_w * miter_limit)
			offset = miter_dir * miter_len
		# Drape each edge vertex on the terrain at its OWN XZ position rather than
		# copying the centerline elevation (pt.y). The lateral offset only moves
		# in XZ, so on a cross-slope the two edges land at different elevations;
		# re-sampling here keeps the uphill edge from sinking into the terrain and
		# the downhill edge from floating above it. When no DEM is loaded the
		# sampler is absent and pt.y (== 0, flat world) is used.
		var lx := pt.x - offset.x
		var lz := pt.z - offset.z
		var rx := pt.x + offset.x
		var rz := pt.z + offset.z
		var ly := _edge_height(lx, lz, pt.y) + ROAD_Y
		var ry := _edge_height(rx, rz, pt.y) + ROAD_Y
		left_edge.append(Vector3(lx, ly, lz))
		right_edge.append(Vector3(rx, ry, rz))

	for i: int in range(n_pts - 1):
		var v0: Vector3 = left_edge[i]
		var v1: Vector3 = right_edge[i]
		var v2: Vector3 = right_edge[i + 1]
		var v3: Vector3 = left_edge[i + 1]

		# Triangle 1
		st.set_normal(Vector3.UP)
		st.add_vertex(v0)
		st.set_normal(Vector3.UP)
		st.add_vertex(v2)
		st.set_normal(Vector3.UP)
		st.add_vertex(v1)

		# Triangle 2
		st.set_normal(Vector3.UP)
		st.add_vertex(v0)
		st.set_normal(Vector3.UP)
		st.add_vertex(v3)
		st.set_normal(Vector3.UP)
		st.add_vertex(v2)

		if has_left_sidewalk:
			# Left edge outward direction: points away from road center (leftward)
			var center := Vector3(points[i].x, left_edge[i].y, points[i].z)
			var outward: Vector3 = (center - left_edge[i]).normalized()
			_add_sidewalk_segment(sidewalk_st, left_edge[i], left_edge[i + 1], -outward, i == 0, i == n_pts - 2)

		if has_right_sidewalk:
			# Right edge outward direction: points away from road center (rightward)
			var center := Vector3(points[i].x, right_edge[i].y, points[i].z)
			var outward: Vector3 = (right_edge[i] - center).normalized()
			_add_sidewalk_segment(sidewalk_st, right_edge[i], right_edge[i + 1], outward, i == 0, i == n_pts - 2)

	var mesh := st.commit()
	if has_left_sidewalk or has_right_sidewalk:
		mesh = sidewalk_st.commit(mesh)

	mesh_instance.mesh = mesh
	return mesh_instance

## Terrain elevation (meters) for a ribbon edge vertex at (x, z).
##
## When a height provider is ready we re-sample the terrain *mesh* surface at the
## edge's own XZ position so each edge drapes independently (the fix for roads
## sinking into / floating over cross-slopes). Without a DEM we fall back to the
## supplied centerline elevation, which is 0 in the flat world.
func _edge_height(x: float, z: float, fallback_y: float) -> float:
	if height_provider != null and height_provider.is_ready():
		return height_provider.sample_mesh_height(x, z)
	return fallback_y

const WATERWAY_WIDTHS := {
	"river": 12.0,
	"canal": 8.0,
	"stream": 2.0,
	"ditch": 1.0,
	"drain": 1.0,
}
const WATERWAY_DEFAULT_WIDTH := 2.0
const WATERWAY_COLOR := Color(0.2, 0.4, 0.8)
const WATERWAY_Y := 0.01  # just above ground, below roads

## Builds a flat blue ribbon mesh for a waterway (river, stream, canal, ...).
## Returns null for degenerate ways. Callers should skip underground waterways
## (tunnel=culvert, etc.) before invoking this.
func build_waterway(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	# Subdivide long segments so the ribbon follows the terrain.
	if terrain_grid_step > 0.0:
		points = PolygonUtils.subdivide_polyline_to_terrain(
			points, height_provider, terrain_grid_step)

	var waterway_type: String = way.tags.get("waterway", "stream")
	var width: float = WATERWAY_WIDTHS.get(waterway_type, WATERWAY_DEFAULT_WIDTH)
	if way.tags.has("width"):
		var explicit_width: float = way.tags["width"].to_float()
		if explicit_width > 0.0:
			width = explicit_width

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Waterway_%d" % way.id

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = WATERWAY_COLOR
	st.set_material(mat)

	var edges := _build_ribbon_edges(points, width / 2.0, WATERWAY_Y)
	var left_edge: Array = edges["left"]
	var right_edge: Array = edges["right"]

	for i: int in range(points.size() - 1):
		var v0: Vector3 = left_edge[i]
		var v1: Vector3 = right_edge[i]
		var v2: Vector3 = right_edge[i + 1]
		var v3: Vector3 = left_edge[i + 1]
		st.set_normal(Vector3.UP); st.add_vertex(v0)
		st.set_normal(Vector3.UP); st.add_vertex(v2)
		st.set_normal(Vector3.UP); st.add_vertex(v1)
		st.set_normal(Vector3.UP); st.add_vertex(v0)
		st.set_normal(Vector3.UP); st.add_vertex(v3)
		st.set_normal(Vector3.UP); st.add_vertex(v2)

	mesh_instance.mesh = st.commit()
	return mesh_instance

# ─── Railways ────────────────────────────────────────────────────────────────

const RAILWAY_WIDTHS := {
	"rail": 2.6,        # standard-gauge track bed (sleeper length ~2.6 m)
	"light_rail": 2.6,
	"subway": 2.6,
	"tram": 2.2,
	"narrow_gauge": 1.8,
	"monorail": 1.2,
	"funicular": 2.2,
	"disused": 2.6,
	"preserved": 2.6,
}
const RAILWAY_DEFAULT_WIDTH := 2.6
const RAILWAY_BED_COLOR := Color(0.32, 0.28, 0.25)   # ballast / sleepers brown-grey
const RAILWAY_RAIL_COLOR := Color(0.6, 0.6, 0.62)    # steel rails
const RAILWAY_BED_Y := 0.03                          # ballast just above ground/road skin
const RAILWAY_RAIL_Y := 0.06                          # rails sit on top of the bed
const RAILWAY_RAIL_HALF := 0.07                       # half-width of each rail strip
const RAILWAY_GAUGE_FRAC := 0.55                      # rail spacing as fraction of bed width

## Builds a track-bed ribbon for a railway way (rail, tram, light_rail, ...),
## plus two thin steel rail strips on top so tracks read as rails rather than a
## plain road. Underground/elevated handling is left to the caller; returns null
## for degenerate ways.
func build_railway(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	# Subdivide long segments so the ribbon follows the terrain.
	if terrain_grid_step > 0.0:
		points = PolygonUtils.subdivide_polyline_to_terrain(
			points, height_provider, terrain_grid_step)

	var railway_type: String = way.tags.get("railway", "rail")
	var width: float = RAILWAY_WIDTHS.get(railway_type, RAILWAY_DEFAULT_WIDTH)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Railway_%d" % way.id

	# Ballast bed.
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var bed_mat := StandardMaterial3D.new()
	bed_mat.albedo_color = RAILWAY_BED_COLOR
	st.set_material(bed_mat)

	var bed := _build_ribbon_edges(points, width / 2.0, RAILWAY_BED_Y)
	var bed_left: Array = bed["left"]
	var bed_right: Array = bed["right"]
	for i: int in range(points.size() - 1):
		_emit_ribbon_quad(st, bed_left[i], bed_right[i], bed_right[i + 1], bed_left[i + 1])

	# Two rail strips, offset symmetrically from the centerline.
	var rail_offset := (width * RAILWAY_GAUGE_FRAC) / 2.0
	var rail_st := SurfaceTool.new()
	rail_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rail_mat := StandardMaterial3D.new()
	rail_mat.albedo_color = RAILWAY_RAIL_COLOR
	rail_mat.metallic = 0.6
	rail_st.set_material(rail_mat)

	_emit_offset_strip(rail_st, points, rail_offset, RAILWAY_RAIL_HALF, RAILWAY_RAIL_Y)
	_emit_offset_strip(rail_st, points, -rail_offset, RAILWAY_RAIL_HALF, RAILWAY_RAIL_Y)

	var mesh := st.commit()
	mesh = rail_st.commit(mesh)
	mesh_instance.mesh = mesh
	return mesh_instance

# ─── Ribbon helpers ──────────────────────────────────────────────────────────

## Emit the two triangles of a ribbon quad (left/right edges of a segment) with
## an upward normal. Shared by the railway bed and rail strips.
func _emit_ribbon_quad(st: SurfaceTool, l0: Vector3, r0: Vector3, r1: Vector3, l1: Vector3) -> void:
	st.set_normal(Vector3.UP); st.add_vertex(l0)
	st.set_normal(Vector3.UP); st.add_vertex(r1)
	st.set_normal(Vector3.UP); st.add_vertex(r0)
	st.set_normal(Vector3.UP); st.add_vertex(l0)
	st.set_normal(Vector3.UP); st.add_vertex(l1)
	st.set_normal(Vector3.UP); st.add_vertex(r1)

## Emit a narrow ribbon strip parallel to the centerline, displaced laterally by
## `center_offset` (signed) and `half` wide, at height `y`. Used for rail strips.
func _emit_offset_strip(st: SurfaceTool, points: PackedVector3Array, center_offset: float, half: float, y: float) -> void:
	var n_pts := points.size()
	var centerline: PackedVector3Array = PackedVector3Array()
	centerline.resize(n_pts)
	for i: int in range(n_pts):
		var lateral: Vector3
		if i == 0:
			var fwd := (points[1] - points[0]).normalized()
			lateral = Vector3(-fwd.z, 0.0, fwd.x).normalized()
		elif i == n_pts - 1:
			var fwd := (points[i] - points[i - 1]).normalized()
			lateral = Vector3(-fwd.z, 0.0, fwd.x).normalized()
		else:
			var fwd_prev := (points[i] - points[i - 1]).normalized()
			var fwd_next := (points[i + 1] - points[i]).normalized()
			var lat_prev := Vector3(-fwd_prev.z, 0.0, fwd_prev.x).normalized()
			var lat_next := Vector3(-fwd_next.z, 0.0, fwd_next.x).normalized()
			lateral = (lat_prev + lat_next)
			if lateral.length_squared() < 0.0001:
				lateral = lat_prev
			else:
				lateral = lateral.normalized()
		var pt := points[i]
		centerline[i] = Vector3(pt.x + lateral.x * center_offset, pt.y, pt.z + lateral.z * center_offset)
	var edges := _build_ribbon_edges(centerline, half, y)
	var left_edge: Array = edges["left"]
	var right_edge: Array = edges["right"]
	for i: int in range(n_pts - 1):
		_emit_ribbon_quad(st, left_edge[i], right_edge[i], right_edge[i + 1], left_edge[i + 1])

## Compute miter-joined left/right edge vertices for a polyline ribbon.
## Returns { "left": Array[Vector3], "right": Array[Vector3] }.
func _build_ribbon_edges(points: PackedVector3Array, half_w: float, y: float) -> Dictionary:
	var miter_limit := 2.0
	var n_pts := points.size()
	var left_edge: Array = []
	var right_edge: Array = []
	for i: int in range(n_pts):
		var pt := points[i]
		var offset: Vector3
		if i == 0:
			var fwd := (points[1] - points[0]).normalized()
			offset = Vector3(-fwd.z, 0.0, fwd.x).normalized() * half_w
		elif i == n_pts - 1:
			var fwd := (points[i] - points[i - 1]).normalized()
			offset = Vector3(-fwd.z, 0.0, fwd.x).normalized() * half_w
		else:
			var fwd_prev := (points[i] - points[i - 1]).normalized()
			var fwd_next := (points[i + 1] - points[i]).normalized()
			var lat_prev := Vector3(-fwd_prev.z, 0.0, fwd_prev.x).normalized()
			var lat_next := Vector3(-fwd_next.z, 0.0, fwd_next.x).normalized()
			var miter_dir := (lat_prev + lat_next)
			if miter_dir.length_squared() < 0.0001:
				miter_dir = lat_prev
			else:
				miter_dir = miter_dir.normalized()
			var d := miter_dir.dot(lat_prev)
			var miter_len := half_w
			if absf(d) > 0.0001:
				miter_len = half_w / d
			miter_len = clampf(miter_len, half_w, half_w * miter_limit)
			offset = miter_dir * miter_len
		# Drape each edge vertex on the terrain at its own XZ position (see
		# _edge_height); y is the small float offset above ground. Flat world
		# falls back to pt.y == 0.
		var lx := pt.x - offset.x
		var lz := pt.z - offset.z
		var rx := pt.x + offset.x
		var rz := pt.z + offset.z
		left_edge.append(Vector3(lx, _edge_height(lx, lz, pt.y) + y, lz))
		right_edge.append(Vector3(rx, _edge_height(rx, rz, pt.y) + y, rz))
	return { "left": left_edge, "right": right_edge }

func _get_sidewalk_sides(tags: Dictionary) -> Dictionary:
	var left := false
	var right := false

	if tags.has("sidewalk"):
		var sidewalk_tag := String(tags["sidewalk"])
		if sidewalk_tag == "separate":
			left = true
			right = true
		elif sidewalk_tag == "both":
			left = true
			right = true
		elif sidewalk_tag == "left":
			left = true
		elif sidewalk_tag == "right":
			right = true
		elif sidewalk_tag == "no":
			left = false
			right = false

	if tags.has("sidewalk:both"):
		var sidewalk_both_tag := String(tags["sidewalk:both"])
		if sidewalk_both_tag == "separate":
			left = true
			right = true
		elif sidewalk_both_tag == "no":
			left = false
			right = false

	if tags.has("sidewalk:left"):
		left = _is_rendered_sidewalk_value(String(tags["sidewalk:left"]))

	if tags.has("sidewalk:right"):
		right = _is_rendered_sidewalk_value(String(tags["sidewalk:right"]))

	return {
		"left": left,
		"right": right,
	}

func _is_rendered_sidewalk_value(value: String) -> bool:
	return value == "separate"

func _add_sidewalk_segment(st: SurfaceTool, edge_start: Vector3, edge_end: Vector3, outward: Vector3, add_start_cap: bool, add_end_cap: bool) -> void:
	var offset := outward * SIDEWALK_WIDTH

	# Base each sidewalk on the terrain elevation of its edge (the edges carry
	# pt.y + ROAD_Y), so the curb follows the DEM. SIDEWALK_BASE_Y stays the
	# ground reference; subtract ROAD_Y to land on terrain, not the road skin.
	var start_base := edge_start.y - ROAD_Y + SIDEWALK_BASE_Y
	var end_base := edge_end.y - ROAD_Y + SIDEWALK_BASE_Y

	var inner_start_bottom := Vector3(edge_start.x, start_base, edge_start.z)
	var inner_end_bottom := Vector3(edge_end.x, end_base, edge_end.z)
	var inner_start_top := Vector3(edge_start.x, start_base + SIDEWALK_HEIGHT, edge_start.z)
	var inner_end_top := Vector3(edge_end.x, end_base + SIDEWALK_HEIGHT, edge_end.z)

	var outer_start := edge_start + offset
	var outer_end := edge_end + offset
	var outer_start_bottom := Vector3(outer_start.x, start_base, outer_start.z)
	var outer_end_bottom := Vector3(outer_end.x, end_base, outer_end.z)
	var outer_start_top := Vector3(outer_start.x, start_base + SIDEWALK_HEIGHT, outer_start.z)
	var outer_end_top := Vector3(outer_end.x, end_base + SIDEWALK_HEIGHT, outer_end.z)

	# Top face — should face up
	_add_quad_facing(st, inner_start_top, inner_end_top, outer_end_top, outer_start_top, Vector3.UP)
	# Outer wall — should face outward (away from road)
	_add_quad_facing(st, outer_start_bottom, outer_start_top, outer_end_top, outer_end_bottom, outward)
	# Inner wall — should face inward (toward road, i.e. -outward)
	_add_quad_facing(st, inner_start_bottom, inner_end_bottom, inner_end_top, inner_start_top, -outward)

	if add_start_cap:
		# Start cap — should face toward start (opposite of edge direction)
		var cap_normal := (edge_start - edge_end).normalized()
		_add_quad_facing(st, outer_start_bottom, inner_start_bottom, inner_start_top, outer_start_top, cap_normal)

	if add_end_cap:
		# End cap — should face toward end
		var cap_normal := (edge_end - edge_start).normalized()
		_add_quad_facing(st, inner_end_bottom, outer_end_bottom, outer_end_top, inner_end_top, cap_normal)

func _add_quad_facing(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, desired_normal: Vector3) -> void:
	PolygonUtils.add_quad_facing(st, a, b, c, d, desired_normal)
