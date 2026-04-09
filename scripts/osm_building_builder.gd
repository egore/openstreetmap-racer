class_name OSMBuildingBuilder
extends RefCounted

## Builds 3D building meshes from OSM ways and relations tagged with "building".
## Supports roof:shape values: flat, gabled, hipped, pyramidal, skillion,
## half-hipped, gambrel, mansard, round, dome, onion, saltbox, sawtooth.

const DEFAULT_HEIGHT := 8.0       # meters if no height/levels tag
const FLOOR_HEIGHT := 3.0         # meters per floor
const BUILDING_Y := 0.0
const DEFAULT_ROOF_COLOR := Color(0.55, 0.35, 0.3)
const DEFAULT_ROOF_HEIGHT := 3.0  # meters for pitched roofs when not specified

const BUILDING_COLORS := {
	"residential": Color(0.75, 0.7, 0.6),
	"commercial": Color(0.65, 0.65, 0.7),
	"industrial": Color(0.6, 0.58, 0.55),
	"retail": Color(0.7, 0.65, 0.6),
	"apartments": Color(0.72, 0.68, 0.6),
	"house": Color(0.78, 0.72, 0.62),
	"garage": Color(0.6, 0.6, 0.58),
	"church": Color(0.8, 0.78, 0.72),
	"school": Color(0.7, 0.72, 0.65),
	"yes": Color(0.7, 0.68, 0.62),
}

const DEFAULT_BUILDING_COLOR := Color(0.7, 0.68, 0.62)

# Roof shape aliases: map common misspellings / synonyms to canonical names
const ROOF_SHAPE_ALIASES := {
	"pitched": "gabled",
	"lean_to": "skillion",
	"shed": "skillion",
}

func build_building_from_way(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> Node3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

	if points.size() < 3:
		return null

	return _build_building_mesh(points, way.tags, way.id)

func build_building_from_polygon(points: PackedVector3Array, tags: Dictionary, id: int) -> Node3D:
	if points.size() < 3:
		return null
	return _build_building_mesh(points, tags, id)

func _build_building_mesh(points: PackedVector3Array, tags: Dictionary, id: int) -> Node3D:
	# Normalize winding to CCW so all wall/roof code can assume consistent vertex order
	if not _is_polygon_ccw(points):
		points = _reverse_polygon(points)

	var height := _get_building_height(tags)
	var roof_shape := _get_roof_shape(tags)
	var roof_height := _get_roof_height(tags, roof_shape)
	var roof_color := _get_roof_color(tags)
	var building_type: String = tags.get("building", "yes")
	var wall_color: Color = BUILDING_COLORS.get(building_type, DEFAULT_BUILDING_COLOR)
	var roof_orientation: String = tags.get("roof:orientation", "along")

	# For non-flat roofs, the wall height is total height minus roof height
	var wall_height := height
	if roof_shape != "flat" and roof_shape != "":
		wall_height = maxf(height - roof_height, 2.0)

	var root := Node3D.new()
	root.name = "Building_%d" % id

	# Build walls
	var wall_mesh := _build_walls(points, wall_height, wall_color)
	if wall_mesh != null:
		root.add_child(wall_mesh)

	# Build roof based on shape
	var roof_nodes := _build_roof_shape(points, wall_height, roof_height, roof_color, wall_color, roof_shape, roof_orientation)
	for node: Node3D in roof_nodes:
		root.add_child(node)

	# Add floating label if building has a name tag
	if tags.has("name") and tags["name"] != "":
		var label := _create_building_label(tags["name"], points, height)
		root.add_child(label)

	return root

func _get_building_height(tags: Dictionary) -> float:
	if tags.has("height"):
		var h: float = tags["height"].to_float()
		if h > 0.0:
			return h
	if tags.has("building:levels"):
		var levels: int = tags["building:levels"].to_int()
		if levels > 0:
			return levels * FLOOR_HEIGHT
	return DEFAULT_HEIGHT

func _get_roof_shape(tags: Dictionary) -> String:
	var shape: String = tags.get("roof:shape", "flat")
	shape = shape.strip_edges().to_lower()
	if ROOF_SHAPE_ALIASES.has(shape):
		shape = ROOF_SHAPE_ALIASES[shape]
	return shape

func _get_roof_height(tags: Dictionary, roof_shape: String) -> float:
	if tags.has("roof:height"):
		var h: float = tags["roof:height"].to_float()
		if h > 0.0:
			return h
	if tags.has("roof:levels"):
		var levels: int = tags["roof:levels"].to_int()
		if levels > 0:
			return levels * FLOOR_HEIGHT
	if roof_shape == "flat":
		return 0.0
	return DEFAULT_ROOF_HEIGHT

func _get_roof_color(tags: Dictionary) -> Color:
	if tags.has("roof:colour"):
		var c: String = tags["roof:colour"].strip_edges().to_lower()
		var parsed := _parse_color(c)
		if parsed != Color.BLACK:
			return parsed
	return DEFAULT_ROOF_COLOR

func _parse_color(c: String) -> Color:
	if c.begins_with("#") and (c.length() == 7 or c.length() == 4):
		return Color.html(c)
	var named_colors := {
		"red": Color(0.7, 0.2, 0.15),
		"brown": Color(0.55, 0.35, 0.2),
		"grey": Color(0.5, 0.5, 0.5),
		"gray": Color(0.5, 0.5, 0.5),
		"black": Color(0.15, 0.15, 0.15),
		"white": Color(0.9, 0.9, 0.88),
		"green": Color(0.2, 0.5, 0.2),
		"blue": Color(0.2, 0.3, 0.6),
		"orange": Color(0.8, 0.45, 0.15),
		"yellow": Color(0.8, 0.75, 0.2),
	}
	if named_colors.has(c):
		return named_colors[c]
	return Color.BLACK

func _create_building_label(text: String, points: PackedVector3Array, height: float) -> Label3D:
	var label := Label3D.new()
	label.name = "Label"
	label.text = text
	label.pixel_size = 0.01
	label.font_size = 32
	label.outline_size = 8
	label.modulate = Color.WHITE
	label.outline_modulate = Color(0.1, 0.1, 0.1, 0.8)
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	label.no_depth_test = true
	var centroid := PolygonUtils.polygon_centroid(points)
	label.position = Vector3(centroid.x, BUILDING_Y + height + 1.0, centroid.z)
	return label

func _is_polygon_ccw(points: PackedVector3Array) -> bool:
	return PolygonUtils.is_polygon_ccw(points)

## Reverse polygon vertex order while keeping the closing duplicate vertex at the end.
func _reverse_polygon(points: PackedVector3Array) -> PackedVector3Array:
	var count := points.size()
	var closed := count > 1 and points[0].distance_to(points[count - 1]) < 0.01
	var inner_count := count - 1 if closed else count
	var result: PackedVector3Array = []
	for i: int in range(inner_count - 1, -1, -1):
		result.append(points[i])
	if closed:
		result.append(result[0])
	return result

func _build_walls(points: PackedVector3Array, height: float, color: Color) -> MeshInstance3D:
	# Points are always CCW (normalized in _build_building_mesh)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]

		var bl := Vector3(p0.x, BUILDING_Y, p0.z)
		var br := Vector3(p1.x, BUILDING_Y, p1.z)
		var tr := Vector3(p1.x, BUILDING_Y + height, p1.z)
		var tl := Vector3(p0.x, BUILDING_Y + height, p0.z)

		var wall_dir := (br - bl).normalized()
		var normal := Vector3(wall_dir.z, 0.0, -wall_dir.x).normalized()

		# CCW polygon: bl -> tr -> br, bl -> tl -> tr
		st.set_normal(normal)
		st.add_vertex(bl)
		st.set_normal(normal)
		st.add_vertex(tr)
		st.set_normal(normal)
		st.add_vertex(br)

		st.set_normal(normal)
		st.add_vertex(bl)
		st.set_normal(normal)
		st.add_vertex(tl)
		st.set_normal(normal)
		st.add_vertex(tr)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Walls"
	mesh_instance.mesh = st.commit()
	return mesh_instance

# ─── Roof shape dispatch ─────────────────────────────────────────────────────

func _build_roof_shape(points: PackedVector3Array, wall_h: float, roof_h: float,
		roof_color: Color, wall_color: Color, shape: String, orientation: String) -> Array[Node3D]:
	var base_y := BUILDING_Y + wall_h
	match shape:
		"gabled":
			return _roof_gabled(points, base_y, roof_h, roof_color, wall_color, orientation)
		"hipped":
			return _roof_hipped(points, base_y, roof_h, roof_color, orientation)
		"pyramidal":
			return _roof_pyramidal(points, base_y, roof_h, roof_color)
		"skillion":
			return _roof_skillion(points, base_y, roof_h, roof_color, wall_color, orientation)
		"half-hipped":
			return _roof_half_hipped(points, base_y, roof_h, roof_color, wall_color, orientation)
		"gambrel":
			return _roof_gambrel(points, base_y, roof_h, roof_color, wall_color, orientation)
		"mansard":
			return _roof_mansard(points, base_y, roof_h, roof_color, orientation)
		"round":
			return _roof_round(points, base_y, roof_h, roof_color, orientation)
		"dome":
			return _roof_dome(points, base_y, roof_h, roof_color)
		"onion":
			return _roof_onion(points, base_y, roof_h, roof_color)
		"saltbox":
			return _roof_saltbox(points, base_y, roof_h, roof_color, wall_color, orientation)
		"sawtooth":
			return _roof_sawtooth(points, base_y, roof_h, roof_color, wall_color, orientation)
		_:
			return _roof_flat(points, base_y, roof_color)

# ─── Helper: get ridge axis direction based on orientation tag ────────────────

func _get_ridge_dir(points: PackedVector3Array, orientation: String) -> Vector3:
	var longest := PolygonUtils.polygon_longest_edge_dir(points)
	if orientation == "across":
		return Vector3(-longest.z, 0.0, longest.x)
	return longest

func _get_perp_dir(ridge_dir: Vector3) -> Vector3:
	return Vector3(-ridge_dir.z, 0.0, ridge_dir.x)

# ─── Helper: add a triangle to SurfaceTool with auto-computed normal ─────────

func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := (b - a).cross(c - a).normalized()
	if normal.length_squared() < 0.001:
		normal = Vector3.UP
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_normal(normal)
	st.add_vertex(c)

func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_add_tri(st, a, b, c)
	_add_tri(st, a, c, d)

func _make_mesh(st: SurfaceTool, name_str: String) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = name_str
	mi.mesh = st.commit()
	return mi

func _new_st(color: Color) -> SurfaceTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)
	return st

# ─── Helper: compute eave and ridge points for rectangular-ish polygons ──────

## Returns { eave_pts: PackedVector3Array at base_y, ridge_start: Vector3, ridge_end: Vector3,
##   ridge_dir, perp_dir, min_proj, max_proj, min_perp, max_perp }
func _compute_ridge_geometry(points: PackedVector3Array, base_y: float, roof_h: float,
		orientation: String) -> Dictionary:
	var ridge_dir := _get_ridge_dir(points, orientation)
	var perp_dir := _get_perp_dir(ridge_dir)
	var centroid := PolygonUtils.polygon_centroid(points)

	var min_proj := INF
	var max_proj := -INF
	var min_perp := INF
	var max_perp := -INF

	for p: Vector3 in points:
		var proj := PolygonUtils.project_xz(p, centroid, ridge_dir)
		var perp := PolygonUtils.project_xz(p, centroid, perp_dir)
		min_proj = min(min_proj, proj)
		max_proj = max(max_proj, proj)
		min_perp = min(min_perp, perp)
		max_perp = max(max_perp, perp)

	var ridge_y := base_y + roof_h
	var ridge_start := centroid + ridge_dir * min_proj
	ridge_start.y = ridge_y
	var ridge_end := centroid + ridge_dir * max_proj
	ridge_end.y = ridge_y

	return {
		"ridge_dir": ridge_dir,
		"perp_dir": perp_dir,
		"centroid": centroid,
		"min_proj": min_proj,
		"max_proj": max_proj,
		"min_perp": min_perp,
		"max_perp": max_perp,
		"ridge_start": ridge_start,
		"ridge_end": ridge_end,
		"ridge_y": ridge_y,
		"base_y": base_y,
	}

# ─── Flat roof ────────────────────────────────────────────────────────────────

func _roof_flat(points: PackedVector3Array, base_y: float, color: Color) -> Array[Node3D]:
	var mi := PolygonUtils.build_flat_polygon_mesh(points, color, base_y)
	if mi != null:
		mi.name = "Roof"
		return [mi]
	return []

# ─── Gabled roof ─────────────────────────────────────────────────────────────

func _roof_gabled(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var ridge_start: Vector3 = rg["ridge_start"]
	var ridge_end: Vector3 = rg["ridge_end"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj

	var st_roof := _new_st(roof_color)
	var st_gable := _new_st(wall_color)

	# For each polygon edge, project it onto the ridge to form a roof slope quad.
	# Skip edges that are roughly perpendicular to the ridge (gable ends).
	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var eave0 := Vector3(p0.x, base_y, p0.z)
		var eave1 := Vector3(p1.x, base_y, p1.z)

		# Project each eave vertex along perp_dir onto the ridge line
		var proj0 := clampf(PolygonUtils.project_xz(p0, centroid, ridge_dir), min_proj, max_proj)
		var proj1 := clampf(PolygonUtils.project_xz(p1, centroid, ridge_dir), min_proj, max_proj)
		var t0 := clampf((proj0 - min_proj) / maxf(proj_span, 0.001), 0.0, 1.0)
		var t1 := clampf((proj1 - min_proj) / maxf(proj_span, 0.001), 0.0, 1.0)
		var ridge0: Vector3 = ridge_start.lerp(ridge_end, t0)
		var ridge1: Vector3 = ridge_start.lerp(ridge_end, t1)

		# Check if this edge is roughly parallel to the ridge (side edge = roof slope)
		var edge_dir := (Vector3(p1.x, 0, p1.z) - Vector3(p0.x, 0, p0.z)).normalized()
		var dot_ridge := absf(edge_dir.dot(ridge_dir))

		if dot_ridge > 0.5:
			# Side edge: create roof slope quad from eave to ridge
			_add_quad(st_roof, eave0, eave1, ridge1, ridge0)

	# Gable triangles at the two ends
	_add_gable_ends(st_gable, points, base_y, rg)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st_roof, "Roof"))
	result.append(_make_mesh(st_gable, "Gables"))
	return result

func _add_gable_ends(st: SurfaceTool, points: PackedVector3Array, base_y: float, rg: Dictionary) -> void:
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var centroid: Vector3 = rg["centroid"]
	var ridge_y: float = rg["ridge_y"]

	# Find vertices closest to each end of the ridge
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var threshold := (max_proj - min_proj) * 0.05

	# Collect vertices near each gable end
	for end_proj: float in [min_proj, max_proj]:
		var gable_verts: Array[Vector3] = []
		for i: int in range(points.size() - 1):
			var proj := PolygonUtils.project_xz(points[i], centroid, ridge_dir)
			if absf(proj - end_proj) < threshold + 0.5:
				gable_verts.append(points[i])

		if gable_verts.size() >= 2:
			# Sort by perpendicular distance
			var perp_dir: Vector3 = rg["perp_dir"]
			gable_verts.sort_custom(func(a: Vector3, b: Vector3) -> bool:
				return PolygonUtils.project_xz(a, centroid, perp_dir) < PolygonUtils.project_xz(b, centroid, perp_dir))
			var left := gable_verts[0]
			var right := gable_verts[gable_verts.size() - 1]
			var ridge_pt := (Vector3(left.x, 0, left.z) + Vector3(right.x, 0, right.z)) / 2.0
			ridge_pt.y = ridge_y
			var bl := Vector3(left.x, base_y, left.z)
			var br := Vector3(right.x, base_y, right.z)
			_add_tri(st, bl, br, ridge_pt)

# ─── Hipped roof ─────────────────────────────────────────────────────────────

func _roof_hipped(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, orientation: String) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)

	# Inset the ridge so hip ends slope inward
	var proj_span: float = float(rg["max_proj"]) - float(rg["min_proj"])
	var perp_span := absf(float(rg["max_perp"]) - float(rg["min_perp"]))
	var inset := minf(perp_span * 0.5, proj_span * 0.3)

	var centroid: Vector3 = rg["centroid"]
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var ridge_y: float = rg["ridge_y"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]

	var ridge_start: Vector3 = centroid + ridge_dir * (min_proj + inset)
	ridge_start.y = ridge_y
	var ridge_end: Vector3 = centroid + ridge_dir * (max_proj - inset)
	ridge_end.y = ridge_y

	var st := _new_st(roof_color)

	# Fan from each edge to nearest ridge point
	var rs_proj: float = min_proj + inset
	var re_proj: float = max_proj - inset
	for i: int in range(points.size() - 1):
		var p0 := Vector3(points[i].x, base_y, points[i].z)
		var p1 := Vector3(points[i + 1].x, base_y, points[i + 1].z)
		var mid := (p0 + p1) / 2.0
		var proj := PolygonUtils.project_xz(mid, centroid, ridge_dir)

		if proj <= rs_proj:
			_add_tri(st, p0, p1, ridge_start)
		elif proj >= re_proj:
			_add_tri(st, p0, p1, ridge_end)
		else:
			# Side face: quad from edge to ridge segment
			var t0 := clampf((PolygonUtils.project_xz(p0, centroid, ridge_dir) - rs_proj) / (re_proj - rs_proj), 0.0, 1.0)
			var t1 := clampf((PolygonUtils.project_xz(p1, centroid, ridge_dir) - rs_proj) / (re_proj - rs_proj), 0.0, 1.0)
			var r0: Vector3 = ridge_start.lerp(ridge_end, t0)
			var r1: Vector3 = ridge_start.lerp(ridge_end, t1)
			_add_quad(st, p0, p1, r1, r0)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	return result

# ─── Pyramidal roof ──────────────────────────────────────────────────────────

func _roof_pyramidal(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var apex := Vector3(centroid.x, base_y + roof_h, centroid.z)

	var st := _new_st(roof_color)
	for i: int in range(points.size() - 1):
		var p0 := Vector3(points[i].x, base_y, points[i].z)
		var p1 := Vector3(points[i + 1].x, base_y, points[i + 1].z)
		_add_tri(st, p0, p1, apex)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	return result

# ─── Skillion roof (mono-pitch) ──────────────────────────────────────────────

func _roof_skillion(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_perp: float = rg["min_perp"]
	var perp_span := absf(float(rg["max_perp"]) - min_perp)

	# Compute the roof Y for each vertex based on perpendicular position
	var roof_points: PackedVector3Array = []
	for p: Vector3 in points:
		var perp := PolygonUtils.project_xz(p, centroid, perp_dir)
		var t := clampf((perp - min_perp) / maxf(perp_span, 0.001), 0.0, 1.0)
		roof_points.append(Vector3(p.x, base_y + roof_h * t, p.z))

	# Roof surface: triangulated sloped polygon
	var st_roof := _new_st(roof_color)
	var indices := PolygonUtils.triangulate_xz(roof_points)
	if indices.size() > 0:
		for idx: int in range(0, indices.size(), 3):
			_add_tri(st_roof, roof_points[indices[idx]], roof_points[indices[idx + 1]], roof_points[indices[idx + 2]])

	# Wall extension quads: fill the gap between wall top (base_y) and roof on each edge
	var st_wall := _new_st(wall_color)
	for i: int in range(points.size() - 1):
		var y0 := roof_points[i].y
		var y1 := roof_points[i + 1].y
		if y0 > base_y + 0.01 or y1 > base_y + 0.01:
			var wall_bl := Vector3(points[i].x, base_y, points[i].z)
			var wall_br := Vector3(points[i + 1].x, base_y, points[i + 1].z)
			var wall_tr := Vector3(points[i + 1].x, y1, points[i + 1].z)
			var wall_tl := Vector3(points[i].x, y0, points[i].z)
			_add_quad(st_wall, wall_bl, wall_br, wall_tr, wall_tl)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st_roof, "Roof"))
	result.append(_make_mesh(st_wall, "SkillionWalls"))
	return result

# ─── Half-hipped roof ────────────────────────────────────────────────────────

func _roof_half_hipped(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)

	var proj_span: float = float(rg["max_proj"]) - float(rg["min_proj"])
	var perp_span := absf(float(rg["max_perp"]) - float(rg["min_perp"]))
	var inset := minf(perp_span * 0.25, proj_span * 0.15)

	var centroid: Vector3 = rg["centroid"]
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var ridge_y: float = rg["ridge_y"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]

	var ridge_start: Vector3 = centroid + ridge_dir * (min_proj + inset)
	ridge_start.y = ridge_y
	var ridge_end: Vector3 = centroid + ridge_dir * (max_proj - inset)
	ridge_end.y = ridge_y

	var st := _new_st(roof_color)
	var st_gable := _new_st(wall_color)

	var rs_proj: float = min_proj + inset
	var re_proj: float = max_proj - inset

	for i: int in range(points.size() - 1):
		var p0 := Vector3(points[i].x, base_y, points[i].z)
		var p1 := Vector3(points[i + 1].x, base_y, points[i + 1].z)
		var mid := (p0 + p1) / 2.0
		var proj := PolygonUtils.project_xz(mid, centroid, ridge_dir)

		if proj <= rs_proj:
			# Hip end triangle
			_add_tri(st, p0, p1, ridge_start)
		elif proj >= re_proj:
			_add_tri(st, p0, p1, ridge_end)
		else:
			var t0 := clampf((PolygonUtils.project_xz(p0, centroid, ridge_dir) - rs_proj) / (re_proj - rs_proj), 0.0, 1.0)
			var t1 := clampf((PolygonUtils.project_xz(p1, centroid, ridge_dir) - rs_proj) / (re_proj - rs_proj), 0.0, 1.0)
			var r0: Vector3 = ridge_start.lerp(ridge_end, t0)
			var r1: Vector3 = ridge_start.lerp(ridge_end, t1)
			_add_quad(st, p0, p1, r1, r0)

	# Gable walls below the hip portion
	_add_gable_ends(st_gable, points, base_y, rg)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	result.append(_make_mesh(st_gable, "Gables"))
	return result

# ─── Gambrel roof ────────────────────────────────────────────────────────────

func _roof_gambrel(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String) -> Array[Node3D]:
	# Gambrel: two slopes on each side - steep lower, shallow upper
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var ridge_start: Vector3 = rg["ridge_start"]
	var ridge_end: Vector3 = rg["ridge_end"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj
	var min_perp: float = rg["min_perp"]
	var max_perp: float = rg["max_perp"]
	var perp_span := absf(max_perp - min_perp)
	var half_perp := perp_span / 2.0
	var break_frac := 0.5  # break point at 50% from eave to ridge
	var break_y := base_y + roof_h * 0.65  # Y at the break point

	var st := _new_st(roof_color)
	var st_gable := _new_st(wall_color)

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]

		# Check if this edge is roughly parallel to the ridge (side edge = roof slope)
		var edge_dir := (Vector3(p1.x, 0, p1.z) - Vector3(p0.x, 0, p0.z)).normalized()
		var dot_ridge := absf(edge_dir.dot(ridge_dir))

		if dot_ridge > 0.5:
			var eave0 := Vector3(p0.x, base_y, p0.z)
			var eave1 := Vector3(p1.x, base_y, p1.z)

			# Project eave points onto ridge line
			var proj0 := clampf(PolygonUtils.project_xz(p0, centroid, ridge_dir), min_proj, max_proj)
			var proj1 := clampf(PolygonUtils.project_xz(p1, centroid, ridge_dir), min_proj, max_proj)
			var t0 := clampf((proj0 - min_proj) / maxf(proj_span, 0.001), 0.0, 1.0)
			var t1 := clampf((proj1 - min_proj) / maxf(proj_span, 0.001), 0.0, 1.0)
			var ridge0: Vector3 = ridge_start.lerp(ridge_end, t0)
			var ridge1: Vector3 = ridge_start.lerp(ridge_end, t1)

			# Break point: midway between eave and ridge (in XZ)
			var break0 := eave0.lerp(ridge0, break_frac)
			break0.y = break_y
			var break1 := eave1.lerp(ridge1, break_frac)
			break1.y = break_y

			# Lower steep slope: eave to break
			_add_quad(st, eave0, eave1, break1, break0)
			# Upper shallow slope: break to ridge
			_add_quad(st, break0, break1, ridge1, ridge0)

	_add_gable_ends(st_gable, points, base_y, rg)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	result.append(_make_mesh(st_gable, "Gables"))
	return result

# ─── Mansard roof ────────────────────────────────────────────────────────────

func _roof_mansard(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, orientation: String) -> Array[Node3D]:
	# Mansard: steep sides with a flat or nearly flat top
	var inset_amount := 1.5  # meters to inset for the flat top
	var top_y := base_y + roof_h

	var top_points := PolygonUtils.shrink_polygon_xz(points, inset_amount)

	var st := _new_st(roof_color)

	# Steep side faces: connect base polygon to inset polygon at top
	if top_points.size() >= 3:
		# For each base edge, find nearest top points
		for i: int in range(points.size() - 1):
			var p0 := Vector3(points[i].x, base_y, points[i].z)
			var p1 := Vector3(points[i + 1].x, base_y, points[i + 1].z)

			# Find closest top polygon vertex to each base vertex
			var t0 := _find_closest_xz(points[i], top_points)
			var t1 := _find_closest_xz(points[i + 1], top_points)
			var tp0 := Vector3(t0.x, top_y, t0.z)
			var tp1 := Vector3(t1.x, top_y, t1.z)

			_add_quad(st, p0, p1, tp1, tp0)

		# Flat top
		var top_mi := PolygonUtils.build_flat_polygon_mesh(top_points, roof_color, top_y)
		if top_mi != null:
			top_mi.name = "RoofTop"
			var result: Array[Node3D] = []
			result.append(_make_mesh(st, "Roof"))
			result.append(top_mi)
			return result

	# Fallback to pyramidal if shrink fails
	return _roof_pyramidal(points, base_y, roof_h, roof_color)

func _find_closest_xz(ref: Vector3, candidates: PackedVector3Array) -> Vector3:
	var best := candidates[0]
	var best_dist := Vector2(ref.x - best.x, ref.z - best.z).length_squared()
	for i: int in range(1, candidates.size()):
		var d := Vector2(ref.x - candidates[i].x, ref.z - candidates[i].z).length_squared()
		if d < best_dist:
			best_dist = d
			best = candidates[i]
	return best

# ─── Round roof ──────────────────────────────────────────────────────────────

func _roof_round(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, orientation: String) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var perp_span := absf(float(rg["max_perp"]) - float(rg["min_perp"]))
	var perp_mid: float = (float(rg["min_perp"]) + float(rg["max_perp"])) / 2.0

	var ridge_dir: Vector3 = rg["ridge_dir"]
	var st := _new_st(roof_color)
	var segments := 8  # number of arc segments

	# For each polygon edge pair, create an arched cross-section (only for side edges)
	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]

		# Only generate arc for side edges (parallel to ridge)
		var edge_dir := (Vector3(p1.x, 0, p1.z) - Vector3(p0.x, 0, p0.z)).normalized()
		var dot_ridge := absf(edge_dir.dot(ridge_dir))
		if dot_ridge < 0.5:
			continue

		# Generate arc vertices for each of the two base points
		for seg: int in range(segments):
			var t0 := float(seg) / segments
			var t1 := float(seg + 1) / segments

			var v00 := _round_roof_vertex(p0, t0, centroid, perp_dir, perp_mid, perp_span, base_y, roof_h)
			var v01 := _round_roof_vertex(p0, t1, centroid, perp_dir, perp_mid, perp_span, base_y, roof_h)
			var v10 := _round_roof_vertex(p1, t0, centroid, perp_dir, perp_mid, perp_span, base_y, roof_h)
			var v11 := _round_roof_vertex(p1, t1, centroid, perp_dir, perp_mid, perp_span, base_y, roof_h)

			_add_quad(st, v00, v10, v11, v01)

	# Gable ends (semicircular)
	var st_gable := _new_st(roof_color)
	_add_round_gable_ends(st_gable, points, base_y, roof_h, rg, segments)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	result.append(_make_mesh(st_gable, "RoofEnds"))
	return result

func _round_roof_vertex(base_pt: Vector3, t: float, centroid: Vector3,
		perp_dir: Vector3, perp_mid: float, perp_span: float,
		base_y: float, roof_h: float) -> Vector3:
	# t goes from 0 (one eave) to 1 (other eave) across the arch
	var angle := t * PI
	var perp_offset := cos(angle) * perp_span * 0.5
	var height := sin(angle) * roof_h

	var perp := PolygonUtils.project_xz(base_pt, centroid, perp_dir)
	# Override: place vertex along the arc
	var arc_perp := perp_mid + perp_offset
	var delta_perp := arc_perp - perp
	return Vector3(
		base_pt.x + perp_dir.x * delta_perp,
		base_y + height,
		base_pt.z + perp_dir.z * delta_perp
	)

func _add_round_gable_ends(st: SurfaceTool, points: PackedVector3Array, base_y: float,
		roof_h: float, rg: Dictionary, segments: int) -> void:
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var perp_mid: float = (float(rg["min_perp"]) + float(rg["max_perp"])) / 2.0
	var perp_span := absf(float(rg["max_perp"]) - float(rg["min_perp"]))

	for end_proj: float in [float(rg["min_proj"]), float(rg["max_proj"])]:
		var end_center: Vector3 = centroid + ridge_dir * end_proj
		end_center.y = base_y

		for seg: int in range(segments):
			var t0 := float(seg) / segments
			var t1 := float(seg + 1) / segments
			var angle0 := t0 * PI
			var angle1 := t1 * PI

			var v0 := Vector3(
				end_center.x + perp_dir.x * cos(angle0) * perp_span * 0.5,
				base_y + sin(angle0) * roof_h,
				end_center.z + perp_dir.z * cos(angle0) * perp_span * 0.5
			)
			var v1 := Vector3(
				end_center.x + perp_dir.x * cos(angle1) * perp_span * 0.5,
				base_y + sin(angle1) * roof_h,
				end_center.z + perp_dir.z * cos(angle1) * perp_span * 0.5
			)
			var vc := Vector3(end_center.x, base_y, end_center.z)
			_add_tri(st, vc, v0, v1)

# ─── Dome roof ───────────────────────────────────────────────────────────────

func _roof_dome(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var bounds := PolygonUtils.polygon_bounds_xz(points)
	var radius_x := (bounds[1] - bounds[0]) / 2.0
	var radius_z := (bounds[3] - bounds[2]) / 2.0

	var st := _new_st(roof_color)
	var rings := 8
	var slices := 16

	for ring: int in range(rings):
		var phi0 := (float(ring) / rings) * PI * 0.5
		var phi1 := (float(ring + 1) / rings) * PI * 0.5

		for slice: int in range(slices):
			var theta0 := (float(slice) / slices) * TAU
			var theta1 := (float(slice + 1) / slices) * TAU

			var v00 := _dome_vertex(centroid, radius_x, radius_z, roof_h, base_y, phi0, theta0)
			var v01 := _dome_vertex(centroid, radius_x, radius_z, roof_h, base_y, phi0, theta1)
			var v10 := _dome_vertex(centroid, radius_x, radius_z, roof_h, base_y, phi1, theta0)
			var v11 := _dome_vertex(centroid, radius_x, radius_z, roof_h, base_y, phi1, theta1)

			_add_quad(st, v00, v01, v11, v10)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	return result

func _dome_vertex(center: Vector3, rx: float, rz: float, h: float, base_y: float,
		phi: float, theta: float) -> Vector3:
	return Vector3(
		center.x + cos(theta) * sin(phi) * rx,
		base_y + cos(phi) * h,
		center.z + sin(theta) * sin(phi) * rz
	)

# ─── Onion dome roof ────────────────────────────────────────────────────────

func _roof_onion(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var bounds := PolygonUtils.polygon_bounds_xz(points)
	var radius_x := (bounds[1] - bounds[0]) / 2.0
	var radius_z := (bounds[3] - bounds[2]) / 2.0

	var st := _new_st(roof_color)
	var rings := 12
	var slices := 16

	for ring: int in range(rings):
		var t0 := float(ring) / rings
		var t1 := float(ring + 1) / rings

		for slice: int in range(slices):
			var theta0 := (float(slice) / slices) * TAU
			var theta1 := (float(slice + 1) / slices) * TAU

			var v00 := _onion_vertex(centroid, radius_x, radius_z, roof_h, base_y, t0, theta0)
			var v01 := _onion_vertex(centroid, radius_x, radius_z, roof_h, base_y, t0, theta1)
			var v10 := _onion_vertex(centroid, radius_x, radius_z, roof_h, base_y, t1, theta0)
			var v11 := _onion_vertex(centroid, radius_x, radius_z, roof_h, base_y, t1, theta1)

			_add_quad(st, v00, v01, v11, v10)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	return result

func _onion_vertex(center: Vector3, rx: float, rz: float, h: float, base_y: float,
		t: float, theta: float) -> Vector3:
	# Onion profile: bulges out wider than base, then tapers to point
	# t goes from 0 (base) to 1 (apex)
	var y := base_y + t * h
	var profile_r: float
	if t < 0.4:
		# Bulge outward (wider than base)
		profile_r = 1.0 + 0.3 * sin(t / 0.4 * PI)
	else:
		# Taper to point
		var tt := (t - 0.4) / 0.6
		profile_r = (1.0 + 0.3 * sin(PI)) * (1.0 - tt)  # Simplify: just taper from max at 0.4
		profile_r = 1.3 * (1.0 - tt * tt)  # Smooth taper
	return Vector3(
		center.x + cos(theta) * rx * profile_r,
		y,
		center.z + sin(theta) * rz * profile_r
	)

# ─── Saltbox roof ────────────────────────────────────────────────────────────

func _roof_saltbox(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String) -> Array[Node3D]:
	# Saltbox: asymmetric gable - ridge is off-center, one slope longer than the other
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var ridge_start: Vector3 = rg["ridge_start"]
	var ridge_end: Vector3 = rg["ridge_end"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj
	var min_perp: float = rg["min_perp"]
	var max_perp: float = rg["max_perp"]
	var perp_span := absf(max_perp - min_perp)
	var perp_mid: float = (min_perp + max_perp) / 2.0

	# Ridge offset: 1/3 from one side (offset toward max_perp side)
	var ridge_perp_offset := perp_span * 0.17
	# Shift the ridge line in the perp direction
	var ridge_offset_vec := perp_dir * ridge_perp_offset
	var offset_ridge_start := ridge_start + ridge_offset_vec
	var offset_ridge_end := ridge_end + ridge_offset_vec

	var st := _new_st(roof_color)
	var st_gable := _new_st(wall_color)

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]

		# Check if this edge is roughly parallel to the ridge (side edge = roof slope)
		var edge_dir := (Vector3(p1.x, 0, p1.z) - Vector3(p0.x, 0, p0.z)).normalized()
		var dot_ridge := absf(edge_dir.dot(ridge_dir))

		if dot_ridge > 0.5:
			var eave0 := Vector3(p0.x, base_y, p0.z)
			var eave1 := Vector3(p1.x, base_y, p1.z)

			# Project eave points onto the offset ridge line
			var proj0 := clampf(PolygonUtils.project_xz(p0, centroid, ridge_dir), min_proj, max_proj)
			var proj1 := clampf(PolygonUtils.project_xz(p1, centroid, ridge_dir), min_proj, max_proj)
			var t0 := clampf((proj0 - min_proj) / maxf(proj_span, 0.001), 0.0, 1.0)
			var t1 := clampf((proj1 - min_proj) / maxf(proj_span, 0.001), 0.0, 1.0)
			var ridge0: Vector3 = offset_ridge_start.lerp(offset_ridge_end, t0)
			var ridge1: Vector3 = offset_ridge_start.lerp(offset_ridge_end, t1)

			_add_quad(st, eave0, eave1, ridge1, ridge0)

	_add_gable_ends(st_gable, points, base_y, rg)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	result.append(_make_mesh(st_gable, "Gables"))
	return result

# ─── Sawtooth roof ───────────────────────────────────────────────────────────

func _roof_sawtooth(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String) -> Array[Node3D]:
	# Sawtooth: repeated asymmetric ridges (like factory roofs)
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation)
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_perp: float = rg["min_perp"]
	var perp_span := absf(float(rg["max_perp"]) - min_perp)

	var tooth_count := maxi(int(perp_span / 4.0), 2)  # one tooth every ~4 meters
	var tooth_width := perp_span / tooth_count

	# Compute the roof Y for each vertex based on sawtooth profile
	var roof_points: PackedVector3Array = []
	for p: Vector3 in points:
		var perp := PolygonUtils.project_xz(p, centroid, perp_dir)
		var y := _sawtooth_y(perp, min_perp, tooth_width, tooth_count, base_y, roof_h)
		roof_points.append(Vector3(p.x, y, p.z))

	# Roof surface: triangulated polygon at varying heights
	var st_roof := _new_st(roof_color)
	var indices := PolygonUtils.triangulate_xz(roof_points)
	if indices.size() > 0:
		for idx: int in range(0, indices.size(), 3):
			_add_tri(st_roof, roof_points[indices[idx]], roof_points[indices[idx + 1]], roof_points[indices[idx + 2]])

	# Wall faces: fill the gap between wall top (base_y) and roof on each edge
	var st_wall := _new_st(wall_color)
	for i: int in range(points.size() - 1):
		var y0 := roof_points[i].y
		var y1 := roof_points[i + 1].y
		if y0 > base_y + 0.01 or y1 > base_y + 0.01:
			var wall_bl := Vector3(points[i].x, base_y, points[i].z)
			var wall_br := Vector3(points[i + 1].x, base_y, points[i + 1].z)
			var wall_tr := Vector3(points[i + 1].x, y1, points[i + 1].z)
			var wall_tl := Vector3(points[i].x, y0, points[i].z)
			_add_quad(st_wall, wall_bl, wall_br, wall_tr, wall_tl)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st_roof, "Roof"))
	result.append(_make_mesh(st_wall, "SawtoothWalls"))
	return result

func _sawtooth_y(perp: float, min_perp: float, tooth_width: float, tooth_count: int,
		base_y: float, roof_h: float) -> float:
	var offset := perp - min_perp
	var tooth_pos := fmod(offset, tooth_width)
	if tooth_pos < 0:
		tooth_pos += tooth_width
	# Ramp up then drop: gradual slope up, vertical drop
	var t := tooth_pos / tooth_width
	return base_y + roof_h * t
