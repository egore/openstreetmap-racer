class_name PolygonUtils
extends RefCounted

## Shared polygon geometry utilities for building flat meshes, resolving area colors, etc.

const AREA_COLORS := {
	"landuse": {
		"residential": Color(0.7, 0.7, 0.65),
		"industrial": Color(0.6, 0.55, 0.5),
		"commercial": Color(0.75, 0.65, 0.6),
		"farmland": Color(0.55, 0.7, 0.35),
		"forest": Color(0.2, 0.5, 0.15),
		"grass": Color(0.4, 0.7, 0.3),
	},
	"natural": {
		"water": Color(0.2, 0.4, 0.8),
		"wood": Color(0.15, 0.45, 0.1),
		"scrub": Color(0.4, 0.55, 0.25),
	},
	"leisure": {
		"park": Color(0.35, 0.7, 0.3),
		"pitch": Color(0.3, 0.65, 0.25),
	},
	"amenity": {
		"parking": Color(0.55, 0.55, 0.55),           # asphalt grey for surface lots
		"bicycle_parking": Color(0.5, 0.5, 0.55),
		"motorcycle_parking": Color(0.5, 0.5, 0.55),
		"school": Color(0.85, 0.78, 0.6),             # warm tan campus ground
		"university": Color(0.82, 0.75, 0.6),
		"kindergarten": Color(0.9, 0.82, 0.6),
		"fire_station": Color(0.7, 0.4, 0.35),        # muted brick red
		"hospital": Color(0.85, 0.7, 0.7),
		"college": Color(0.82, 0.75, 0.6),
	},
	"shop": {
		"supermarket": Color(0.7, 0.6, 0.7),
	},
	"power": {
		"generator": Color(0.45, 0.45, 0.5),
	},
	"man_made": {
		"wastewater_plant": Color(0.5, 0.52, 0.55),   # concrete treatment basins
		"water_works": Color(0.5, 0.52, 0.55),
		"works": Color(0.55, 0.5, 0.48),              # industrial works ground
		"reservoir_covered": Color(0.45, 0.5, 0.55),
		"storage_tank": Color(0.55, 0.55, 0.58),
		"wastewater": Color(0.5, 0.52, 0.55),
	},
	"area:highway": {
		"traffic_island": Color(0.6, 0.6, 0.58),
	},
}

const DEFAULT_AREA_COLOR := Color(0.3, 0.6, 0.3)

## Resolve an area color from OSM tags. Returns DEFAULT_AREA_COLOR when no match.
static func get_area_color(tags: Dictionary) -> Color:
	for category: String in AREA_COLORS:
		if tags.has(category):
			var value: String = tags[category]
			var sub: Dictionary = AREA_COLORS[category]
			if sub.has(value):
				return sub[value]
			return DEFAULT_AREA_COLOR
	return DEFAULT_AREA_COLOR

## Collect world positions for a way's node_ids from osm_data.
static func way_to_points(way_node_ids: Array[int], osm_data_nodes: Dictionary) -> PackedVector3Array:
	var points: PackedVector3Array = []
	for nid: int in way_node_ids:
		if osm_data_nodes.has(nid):
			points.append(osm_data_nodes[nid].local_pos)
	return points

## Triangulate a 3D polygon (XZ plane) and return the index array.
## Returns an empty array when triangulation fails.
static func triangulate_xz(points: PackedVector3Array) -> PackedInt32Array:
	var pts_2d: PackedVector2Array = []
	for p: Vector3 in points:
		pts_2d.append(Vector2(p.x, p.z))
	return Geometry2D.triangulate_polygon(pts_2d)

## Build a flat colored MeshInstance3D from a 3D polygon at the given Y height.
## Returns null when fewer than 3 points or triangulation fails.
## Build a triangulated flat polygon mesh.
## When drape_terrain is true, each vertex keeps its own elevation (points[idx].y)
## and y is added as an offset, so the polygon follows the DEM. When false (the
## default, used by roofs), every vertex sits at the single height y.
static func build_flat_polygon_mesh(points: PackedVector3Array, color: Color, y: float = 0.01, drape_terrain: bool = false) -> MeshInstance3D:
	if points.size() < 3:
		return null

	var indices := triangulate_xz(points)
	if indices.size() == 0:
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	for i: int in range(indices.size()):
		var idx: int = indices[i]
		var vy: float = (points[idx].y + y) if drape_terrain else y
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(points[idx].x, vy, points[idx].z))

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = st.commit()
	return mesh_instance

## Check if the XZ-projected polygon winds counter-clockwise (shoelace formula).
static func is_polygon_ccw(points: PackedVector3Array) -> bool:
	var signed_area := 0.0
	for i: int in range(points.size() - 1):
		signed_area += points[i].x * points[i + 1].z - points[i + 1].x * points[i].z
	return signed_area < 0.0

## Reverse a polygon's vertex order while preserving the closing duplicate vertex
## at the end (if the input was closed). Used to flip winding direction.
static func reverse_polygon(points: PackedVector3Array) -> PackedVector3Array:
	var count := points.size()
	var closed := count > 1 and points[0].distance_to(points[count - 1]) < 0.01
	var inner_count := count - 1 if closed else count
	var result: PackedVector3Array = []
	for i: int in range(inner_count - 1, -1, -1):
		result.append(points[i])
	if closed and result.size() > 0:
		result.append(result[0])
	return result

## Return the polygon wound counter-clockwise. OSM ways are authored CW or CCW
## arbitrarily; downstream geometry that depends on a consistent vertex order
## (outward wall normals, etc.) should normalize through this single entry point.
static func normalize_to_ccw(points: PackedVector3Array) -> PackedVector3Array:
	if is_polygon_ccw(points):
		return points
	return reverse_polygon(points)

## Shading normal used by add_tri for triangle (a, b, c): (b - a) x (c - a).
## NOTE: This is the OPPOSITE sign of Godot's winding-front / culling normal
## (Plane(a, b, c).normal). Call sites in the building builder choose their
## vertex winding to make this convention point outward, so it is preserved here.
static func tri_shading_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	return (b - a).cross(c - a)

## Emit a triangle (a -> b -> c) to a SurfaceTool with an auto-computed shading
## normal (see tri_shading_normal). Degenerate triangles fall back to UP.
static func add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := tri_shading_normal(a, b, c)
	if normal.length_squared() < 0.000001:
		normal = Vector3.UP
	else:
		normal = normal.normalized()
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_normal(normal)
	st.add_vertex(c)

## Emit a quad (a, b, c, d in order) to a SurfaceTool so that its visible front
## face (per backface culling) points along desired_normal, regardless of the
## input vertex winding. The shading normal is set explicitly to desired_normal
## so lighting and culling agree. This is the winding-agnostic path for geometry
## built from OSM ways whose CW/CCW direction is not known in advance.
static func add_quad_facing(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3, desired_normal: Vector3) -> void:
	# Culling uses the winding-front normal Plane(a, b, c).normal == -tri_shading_normal.
	# Pick the winding whose front face points along desired_normal.
	var front_normal := -tri_shading_normal(a, b, c)
	if front_normal.dot(desired_normal) >= 0.0:
		_add_tri_with_normal(st, a, b, c, desired_normal)
		_add_tri_with_normal(st, a, c, d, desired_normal)
	else:
		_add_tri_with_normal(st, a, c, b, desired_normal)
		_add_tri_with_normal(st, a, d, c, desired_normal)

## Emit a triangle with an explicit shading normal (used by add_quad_facing so
## the lit normal matches the requested facing direction rather than the winding).
static func _add_tri_with_normal(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_normal(normal)
	st.add_vertex(c)

## Emit a 4-sided prism ("tube") of half-extent `radius` running from p0 to p1.
## A cheap stand-in for a cylinder (4 side quads, no end caps) used for thin
## linear structures like power cables and gantry beams that read fine as a
## square cross-section from a distance. Faces are emitted outward-facing so the
## tube is visible from any angle. Degenerate (zero-length) segments are skipped.
static func add_tube_segment(st: SurfaceTool, p0: Vector3, p1: Vector3, radius: float) -> void:
	var dir := (p1 - p0)
	if dir.length_squared() < 0.000001:
		return
	dir = dir.normalized()
	# Pick any axis not parallel to the tube to seed the cross-section frame.
	var up := Vector3.UP
	if absf(dir.dot(up)) > 0.99:
		up = Vector3.FORWARD
	var side := dir.cross(up).normalized() * radius
	var vert := dir.cross(side).normalized() * radius
	var ring0: Array[Vector3] = [p0 + side, p0 + vert, p0 - side, p0 - vert]
	var ring1: Array[Vector3] = [p1 + side, p1 + vert, p1 - side, p1 - vert]
	for k: int in range(4):
		var n := (k + 1) % 4
		var outward: Vector3 = ((ring0[k] - p0) + (ring1[k] - p1)).normalized()
		add_quad_facing(st, ring0[k], ring0[n], ring1[n], ring1[k], outward)

## Compute the centroid of a polygon in the XZ plane.
static func polygon_centroid(points: PackedVector3Array) -> Vector3:
	var cx := 0.0
	var cz := 0.0
	var count := points.size()
	# Exclude the closing duplicate vertex if present
	if count > 1 and points[0].distance_to(points[count - 1]) < 0.01:
		count -= 1
	if count == 0:
		return Vector3.ZERO
	for i: int in range(count):
		cx += points[i].x
		cz += points[i].z
	return Vector3(cx / count, 0.0, cz / count)

## Return the AABB min/max in XZ plane as [min_x, max_x, min_z, max_z].
static func polygon_bounds_xz(points: PackedVector3Array) -> Array[float]:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p: Vector3 in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.z)
		max_z = max(max_z, p.z)
	return [min_x, max_x, min_z, max_z]

## Find the direction along the longest edge of the polygon (XZ plane, normalized).
static func polygon_longest_edge_dir(points: PackedVector3Array) -> Vector3:
	var best_len := 0.0
	var best_dir := Vector3(1, 0, 0)
	for i: int in range(points.size() - 1):
		var d := points[i + 1] - points[i]
		d.y = 0.0
		var l := d.length()
		if l > best_len:
			best_len = l
			best_dir = d / l
	return best_dir

## Shrink (inset) a polygon in the XZ plane by a fixed distance.
## Returns empty array if the polygon degenerates.
static func shrink_polygon_xz(points: PackedVector3Array, amount: float) -> PackedVector3Array:
	var pts2d: PackedVector2Array = []
	var count := points.size()
	if count > 1 and points[0].distance_to(points[count - 1]) < 0.01:
		count -= 1
	for i: int in range(count):
		pts2d.append(Vector2(points[i].x, points[i].z))
	var result := Geometry2D.offset_polygon(pts2d, -amount)
	if result.size() == 0:
		return PackedVector3Array()
	var out: PackedVector3Array = []
	for p2: Vector2 in result[0]:
		out.append(Vector3(p2.x, 0.0, p2.y))
	# Close the polygon
	if out.size() > 0:
		out.append(out[0])
	return out

## Project a 3D point onto a line defined by origin + direction in XZ, return signed distance.
static func project_xz(point: Vector3, origin: Vector3, direction: Vector3) -> float:
	return (point.x - origin.x) * direction.x + (point.z - origin.z) * direction.z


# ─── Terrain-draped polyline subdivision ──────────────────────────────────────

## Subdivide a polyline so that no segment is longer than max_step meters,
## re-sampling elevation from the HeightProvider at every new intermediate
## point. This makes roads, waterways and other ribbons follow the terrain
## rather than linearly interpolating between sparse OSM nodes.
##
## Returns the original points unchanged when no HeightProvider is available
## or when every segment is already short enough.
static func subdivide_polyline_to_terrain(
		points: PackedVector3Array,
		hp: HeightProvider,
		max_step: float,
) -> PackedVector3Array:
	if points.size() < 2:
		return points
	if hp == null or not hp.is_ready():
		return points

	var result: PackedVector3Array = []
	result.append(points[0])

	for i: int in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		# Distance in the XZ plane (horizontal length of the segment).
		var dx := b.x - a.x
		var dz := b.z - a.z
		var seg_len := sqrt(dx * dx + dz * dz)

		if seg_len <= max_step:
			# Segment is short enough — keep the original endpoint.
			result.append(b)
		else:
			# Subdivide: insert evenly-spaced intermediate points.
			var n_sub := int(ceil(seg_len / max_step))
			for s: int in range(1, n_sub + 1):
				var t := float(s) / float(n_sub)
				var px := a.x + dx * t
				var pz := a.z + dz * t
				var py := hp.sample_local_xz(px, pz)
				result.append(Vector3(px, py, pz))

	return result


# ─── Terrain-draped polygon mesh ─────────────────────────────────────────────

## Build a polygon mesh that conforms to the terrain grid by subdividing the
## polygon into terrain-cell-sized pieces and sampling the HeightProvider at
## every vertex. This prevents large area polygons from floating above or
## clipping through the undulating terrain.
##
## When no HeightProvider is supplied (flat world), falls back to the simple
## build_flat_polygon_mesh.
##
## grid_step is the terrain cell size (tile_size / terrain_subdivisions).
## y_offset is added to the sampled elevation to prevent z-fighting with the
## ground mesh (typically 0.01–0.02).
## clip_rect limits the grid iteration to a specific world-space rectangle
## (Vector4: min_x, max_x, min_z, max_z). Large polygons spanning many tiles
## MUST pass the current tile bounds here to avoid iterating over thousands
## of grid cells. When null the polygon's own AABB is used (only safe for
## small polygons).
static func build_terrain_draped_mesh(
		points: PackedVector3Array,
		color: Color,
		hp: HeightProvider,
		grid_step: float,
		y_offset: float = 0.01,
		clip_rect: Variant = null,  # null or Array[float] [min_x, max_x, min_z, max_z]
) -> MeshInstance3D:
	if points.size() < 3:
		return null
	if hp == null or not hp.is_ready():
		return build_flat_polygon_mesh(points, color, y_offset, true)

	# Convert the polygon to 2D (XZ plane) for clipping operations.
	var poly_2d: PackedVector2Array = []
	var count := points.size()
	# Strip the closing duplicate if present.
	if count > 1 and points[0].distance_to(points[count - 1]) < 0.01:
		count -= 1
	for i: int in range(count):
		poly_2d.append(Vector2(points[i].x, points[i].z))

	# Determine the grid iteration bounds. When a clip_rect is provided (the
	# current tile bounds), use it instead of the polygon's full AABB so we
	# only process the cells that belong to this tile.
	var min_x: float
	var max_x: float
	var min_z: float
	var max_z: float
	if clip_rect != null:
		min_x = clip_rect[0]
		max_x = clip_rect[1]
		min_z = clip_rect[2]
		max_z = clip_rect[3]
	else:
		var bounds := polygon_bounds_xz(points)
		min_x = bounds[0]
		max_x = bounds[1]
		min_z = bounds[2]
		max_z = bounds[3]

	var grid_x0 := floorf(min_x / grid_step) * grid_step
	var grid_z0 := floorf(min_z / grid_step) * grid_step
	var grid_x1 := ceilf(max_x / grid_step) * grid_step
	var grid_z1 := ceilf(max_z / grid_step) * grid_step

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	var has_tris := false
	var cell_x := grid_x0
	while cell_x < grid_x1 - 0.001:
		var cell_z := grid_z0
		var next_x := cell_x + grid_step
		while cell_z < grid_z1 - 0.001:
			var next_z := cell_z + grid_step
			# Build the grid cell rectangle.
			var cell_rect: PackedVector2Array = PackedVector2Array([
				Vector2(cell_x, cell_z),
				Vector2(cell_x, next_z),
				Vector2(next_x, next_z),
				Vector2(next_x, cell_z),
			])

			# Intersect cell with the polygon.
			var clips := Geometry2D.intersect_polygons(cell_rect, poly_2d)
			for clip: PackedVector2Array in clips:
				var indices := Geometry2D.triangulate_polygon(clip)
				if indices.size() == 0:
					continue
				for idx: int in indices:
					var p2 := clip[idx]
					var wy := hp.sample_local_xz(p2.x, p2.y) + y_offset
					st.set_normal(Vector3.UP)
					st.add_vertex(Vector3(p2.x, wy, p2.y))
					has_tris = true

			cell_z = next_z
		cell_x = next_x

	if not has_tris:
		return null

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = st.commit()
	return mesh_instance


## Return true when tags represent a scrub area (natural=scrub).
static func is_scrub(tags: Dictionary) -> bool:
	return tags.get("natural", "") == "scrub"


# ─── Scrub ball scattering ───────────────────────────────────────────────────

## Density of scrub balls per square meter.  Adjust to taste.
const SCRUB_DENSITY := 0.15
## Minimum / maximum diameter of scrub balls (meters).
const SCRUB_MIN_DIAMETER := 1.0
const SCRUB_MAX_DIAMETER := 3.0
## Palette of greens used for scrub balls (random per ball).
const SCRUB_COLORS: Array[Color] = [
	Color(0.25, 0.50, 0.15),
	Color(0.30, 0.55, 0.20),
	Color(0.35, 0.45, 0.18),
	Color(0.28, 0.52, 0.12),
	Color(0.40, 0.58, 0.22),
]
## Darker ground colour underneath the scrub balls.
const SCRUB_GROUND_COLOR := Color(0.35, 0.45, 0.20)

## Build a Node3D for a scrub area: a flat ground polygon plus scattered green
## balls of varying size rendered via MultiMeshInstance3D.
##
## hp may be null (flat world).  When present, balls sit on terrain.
## y_offset lifts the ground polygon to prevent z-fighting.
static func build_scrub_area(
		points: PackedVector3Array,
		hp: HeightProvider,
		grid_step: float,
		y_offset: float = 0.01,
		clip_rect: Variant = null,
) -> Node3D:
	if points.size() < 3:
		return null

	var root := Node3D.new()

	# --- ground polygon ---
	var ground: MeshInstance3D
	if hp != null and hp.is_ready() and grid_step > 0.0:
		ground = build_terrain_draped_mesh(points, SCRUB_GROUND_COLOR, hp, grid_step, y_offset, clip_rect)
	else:
		ground = build_flat_polygon_mesh(points, SCRUB_GROUND_COLOR, y_offset, true)
	if ground != null:
		ground.name = "ScrubGround"
		root.add_child(ground)

	# --- scatter positions inside polygon ---
	var scatter_points := _scatter_points_in_polygon(points, hp)
	if scatter_points.size() == 0:
		if ground != null:
			return root
		return null

	# --- build MultiMesh of spheres ---
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.instance_count = scatter_points.size()

	# Shared sphere mesh (low-poly: 8 rings x 12 sectors is fine at distance)
	var sphere := SphereMesh.new()
	sphere.radius = 0.5
	sphere.height = 1.0
	sphere.radial_segments = 12
	sphere.rings = 8
	# Use vertex colours from the MultiMesh.
	var mat := StandardMaterial3D.new()
	mat.vertex_color_use_as_albedo = true
	sphere.material = mat
	mm.mesh = sphere

	var rng := RandomNumberGenerator.new()
	# Deterministic seed from first polygon vertex so rebuilds are stable.
	rng.seed = hash(Vector2(points[0].x, points[0].z))

	for i: int in range(scatter_points.size()):
		var pos: Vector3 = scatter_points[i]
		var diameter := rng.randf_range(SCRUB_MIN_DIAMETER, SCRUB_MAX_DIAMETER)
		var scale_val := diameter  # sphere mesh is 1 m, so scale == diameter
		var t := Transform3D()
		t = t.scaled(Vector3(scale_val, scale_val, scale_val))
		# Place centre of ball at ground + half radius so it sits *on* the surface.
		t.origin = Vector3(pos.x, pos.y + diameter * 0.5, pos.z)
		mm.set_instance_transform(i, t)
		mm.set_instance_color(i, SCRUB_COLORS[rng.randi() % SCRUB_COLORS.size()])

	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.name = "ScrubBalls"
	root.add_child(mmi)

	return root


## Scatter random sample points inside a polygon using rejection sampling on
## its AABB.  Returns world-space positions with Y set from the
## HeightProvider (or 0 when flat).
static func _scatter_points_in_polygon(
		points: PackedVector3Array,
		hp: HeightProvider,
) -> Array[Vector3]:
	var result: Array[Vector3] = []
	var bounds := polygon_bounds_xz(points)
	var min_x := bounds[0]
	var max_x := bounds[1]
	var min_z := bounds[2]
	var max_z := bounds[3]
	var area := (max_x - min_x) * (max_z - min_z)
	if area < 1.0:
		return result

	var poly_2d: PackedVector2Array = []
	var count := points.size()
	if count > 1 and points[0].distance_to(points[count - 1]) < 0.01:
		count -= 1
	for i: int in range(count):
		poly_2d.append(Vector2(points[i].x, points[i].z))

	# Number of candidate points proportional to polygon AABB area.
	var n_candidates := int(area * SCRUB_DENSITY)
	# Cap to avoid performance issues on huge polygons.
	n_candidates = min(n_candidates, 4000)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector2(points[0].x, points[0].z)) + 1

	for _j: int in range(n_candidates):
		var px := rng.randf_range(min_x, max_x)
		var pz := rng.randf_range(min_z, max_z)
		if Geometry2D.is_point_in_polygon(Vector2(px, pz), poly_2d):
			var py := 0.0
			if hp != null and hp.is_ready():
				py = hp.sample_local_xz(px, pz)
			result.append(Vector3(px, py, pz))

	return result


## Test whether a polygon fully covers a terrain tile. Used by the tile
## manager to skip the visible terrain mesh under opaque area polygons.
## Only checks the four tile corners (fast reject via AABB + 4 PIP tests).
static func polygon_covers_tile(
		points: PackedVector3Array,
		tile_origin_x: float,
		tile_origin_z: float,
		tile_size: float,
		_grid_step: float  # unused, kept for API compat
) -> bool:
	# Fast AABB reject: if the polygon's bounding box doesn't fully contain the
	# tile rectangle, it can't possibly cover it.
	var bounds := polygon_bounds_xz(points)
	if bounds[0] > tile_origin_x or bounds[1] < tile_origin_x + tile_size:
		return false
	if bounds[2] > tile_origin_z or bounds[3] < tile_origin_z + tile_size:
		return false

	var poly_2d: PackedVector2Array = []
	var count := points.size()
	if count > 1 and points[0].distance_to(points[count - 1]) < 0.01:
		count -= 1
	for i: int in range(count):
		poly_2d.append(Vector2(points[i].x, points[i].z))

	# Check the four tile corners. If all are inside the polygon, the tile is
	# fully covered (convex or concave polygons with re-entrants narrow enough
	# to miss a corner are acceptable false-negatives — they just keep the
	# terrain visible, which is safe).
	var tx1 := tile_origin_x + tile_size
	var tz1 := tile_origin_z + tile_size
	if not Geometry2D.is_point_in_polygon(Vector2(tile_origin_x, tile_origin_z), poly_2d):
		return false
	if not Geometry2D.is_point_in_polygon(Vector2(tx1, tile_origin_z), poly_2d):
		return false
	if not Geometry2D.is_point_in_polygon(Vector2(tile_origin_x, tz1), poly_2d):
		return false
	if not Geometry2D.is_point_in_polygon(Vector2(tx1, tz1), poly_2d):
		return false
	return true
