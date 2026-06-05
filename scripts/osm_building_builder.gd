class_name OSMBuildingBuilder
extends RefCounted

## Builds 3D building meshes from OSM ways and relations tagged with "building".
## Supports roof:shape values: flat, gabled, hipped, pyramidal, skillion,
## half-hipped, gambrel, mansard, round, dome, onion, saltbox, sawtooth.
## Supports roof:direction (compass bearing 0-360) which takes priority over
## roof:orientation for specifying ridge direction.
##
## building=roof is treated as an open structure (canopy / porch / petrol-station
## roof): a roof held up by thin support posts with no enclosing walls, rather
## than a solid block. See https://wiki.openstreetmap.org/wiki/Tag:building%3Droof
## (building:part=roof remains a normal walled roof part of a larger building.)

const DEFAULT_HEIGHT := 8.0       # meters if no height/levels tag
const FLOOR_HEIGHT := 3.0         # meters per floor
const BUILDING_Y := 0.0
const DEFAULT_ROOF_COLOR := Color(0.55, 0.35, 0.3)
const DEFAULT_ROOF_HEIGHT := 3.0  # meters for pitched roofs when not specified
const ROOF_SUPPORT_RADIUS := 0.12 # meters; radius of support posts for building=roof
const ROOF_SLAB_THICKNESS := 0.3  # meters; thickness of a flat building=roof slab

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

const MATERIAL_COLORS := {
	"brick": Color(0.65, 0.35, 0.25),
	"plaster": Color(0.85, 0.82, 0.75),
	"wood": Color(0.6, 0.45, 0.3),
	"concrete": Color(0.65, 0.65, 0.65),
	"metal": Color(0.6, 0.6, 0.65),
	"glass": Color(0.6, 0.75, 0.85),
	"stone": Color(0.55, 0.55, 0.5),
	"sandstone": Color(0.8, 0.7, 0.5),
	"limestone": Color(0.8, 0.78, 0.7),
	"granite": Color(0.5, 0.5, 0.5),
	"marble": Color(0.9, 0.88, 0.85),
	"render": Color(0.85, 0.82, 0.75),
	"stucco": Color(0.85, 0.8, 0.7),
	"cement_block": Color(0.6, 0.6, 0.58),
	"steel": Color(0.55, 0.55, 0.6),
}

# Roof shape aliases: map common misspellings / synonyms to canonical names
const ROOF_SHAPE_ALIASES := {
	"pitched": "gabled",
	"lean_to": "skillion",
	"shed": "skillion",
}

const ROOF_MATERIAL_COLORS := {
	"roof_tiles": Color(0.7, 0.35, 0.25),
	"tile": Color(0.7, 0.35, 0.25),
	"slate": Color(0.35, 0.35, 0.4),
	"metal": Color(0.5, 0.5, 0.55),
	"copper": Color(0.45, 0.7, 0.55),
	"tar_paper": Color(0.2, 0.2, 0.2),
	"eternit": Color(0.5, 0.5, 0.5),
	"gravel": Color(0.55, 0.55, 0.5),
	"grass": Color(0.35, 0.55, 0.25),
	"glass": Color(0.6, 0.75, 0.85),
	"thatch": Color(0.7, 0.6, 0.35),
	"concrete": Color(0.6, 0.6, 0.6),
	"stone": Color(0.5, 0.5, 0.48),
	"zinc": Color(0.55, 0.55, 0.58),
	"tin": Color(0.55, 0.55, 0.55),
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
	# Capture footprint elevation, then flatten points to y=0 so all geometry is
	# built in local space relative to BUILDING_Y. The root node is raised to the
	# terrain height afterward (see below), keeping walls and roofs coplanar.
	var ground_y := _average_footprint_y(points)
	for i: int in range(points.size()):
		points[i] = Vector3(points[i].x, 0.0, points[i].z)

	# Normalize winding to CCW so all wall/roof code can assume consistent vertex order
	points = PolygonUtils.normalize_to_ccw(points)

	var height := _get_building_height(tags)
	var min_height := _get_min_height(tags)
	var roof_shape := _get_roof_shape(tags)
	var roof_orientation: String = tags.get("roof:orientation", "along")
	var roof_height := _get_roof_height(tags, roof_shape, points, roof_orientation)
	var roof_color := _get_roof_color(tags)
	var building_type: String = tags.get("building", tags.get("building:part", "yes"))
	var wall_color: Color = BUILDING_COLORS.get(building_type, DEFAULT_BUILDING_COLOR)
	if tags.has("building:colour"):
		var parsed := _parse_color(tags["building:colour"].strip_edges().to_lower())
		if parsed != Color.BLACK:
			wall_color = parsed
	elif tags.has("building:color"):
		var parsed := _parse_color(tags["building:color"].strip_edges().to_lower())
		if parsed != Color.BLACK:
			wall_color = parsed
	elif tags.has("building:material"):
		var mat_name: String = tags["building:material"].strip_edges().to_lower()
		if MATERIAL_COLORS.has(mat_name):
			wall_color = MATERIAL_COLORS[mat_name]
	var roof_direction: float = -1.0
	if tags.has("roof:direction"):
		roof_direction = tags["roof:direction"].to_float()

	var root := Node3D.new()
	root.name = "Building_%d" % id

	# Lift the whole building onto the terrain. All wall/roof geometry below is
	# built relative to BUILDING_Y (0); translating the rigid root by the footprint
	# elevation places it on the DEM without re-deriving every roof vertex.
	root.position.y = ground_y

	# building=roof is an open structure (canopy/porch): just a roof held up by
	# thin supports, with no enclosing walls. See
	# https://wiki.openstreetmap.org/wiki/Tag:building%3Droof
	# (Note: building:part=roof is a real roof part of a larger building and is
	#  handled via the normal wall+roof path below, so we key off the top-level
	#  "building" tag specifically rather than the merged building_type.)
	if tags.get("building", "") == "roof":
		_build_open_roof(root, points, height, min_height, roof_height, roof_color, wall_color, roof_shape, roof_orientation, roof_direction)
		if tags.has("name") and tags["name"] != "":
			root.add_child(_create_building_label(tags["name"], points, height))
		return root

	# For non-flat roofs, the wall height is total height minus roof height minus min_height
	var wall_height := height - min_height
	if roof_shape != "flat" and roof_shape != "":
		wall_height = maxf(height - min_height - roof_height, 2.0)

	# Build walls (raised by min_height when building is elevated)
	var wall_base := BUILDING_Y + min_height
	var wall_mesh := _build_walls(points, wall_height, wall_color, wall_base)
	if wall_mesh != null:
		root.add_child(wall_mesh)

	# Build roof based on shape (roof sits on top of the walls)
	var roof_nodes := _build_roof_shape(points, min_height + wall_height, roof_height, roof_color, wall_color, roof_shape, roof_orientation, roof_direction)
	for node: Node3D in roof_nodes:
		root.add_child(node)

	# Add floating label if building has a name tag
	if tags.has("name") and tags["name"] != "":
		var label := _create_building_label(tags["name"], points, height)
		root.add_child(label)

	return root

## Build an open roof structure (building=roof): a roof held up by thin support
## posts, with no enclosing walls. The roof underside ("ceiling") sits at
## (height - roof_height) and the posts run from the ground up to that ceiling.
## All geometry is built relative to BUILDING_Y; the caller's root carries the
## terrain offset.
func _build_open_roof(root: Node3D, points: PackedVector3Array, height: float,
		min_height: float, roof_height: float, roof_color: Color, wall_color: Color,
		roof_shape: String, roof_orientation: String, roof_direction: float) -> void:
	# Effective roof thickness/height. A flat roof has no pitch, so give it a thin
	# slab so it reads as a solid roof rather than a paper-thin plane.
	var effective_roof_h := roof_height
	if roof_shape == "flat" or roof_shape == "":
		effective_roof_h = ROOF_SLAB_THICKNESS

	# Ceiling is the underside of the roof; posts reach up to it.
	var ceiling_y := maxf(height - effective_roof_h, min_height + 0.5)

	# Support posts at each footprint vertex (skip the duplicated closing vertex).
	var post_color := wall_color
	for i: int in range(points.size() - 1):
		var post := _build_support_post(points[i], BUILDING_Y, ceiling_y, post_color)
		if post != null:
			post.name = "Support_%d" % i
			root.add_child(post)

	# Roof sits on top of the posts at the ceiling height.
	if roof_shape == "flat" or roof_shape == "":
		# Solid slab: top face + bottom face + thin sides.
		var slab := _build_roof_slab(points, ceiling_y, effective_roof_h, roof_color)
		if slab != null:
			root.add_child(slab)
	else:
		var roof_nodes := _build_roof_shape(points, ceiling_y, roof_height, roof_color, wall_color, roof_shape, roof_orientation, roof_direction)
		for node: Node3D in roof_nodes:
			root.add_child(node)

## Build a single vertical support post (square prism) from base_y to top_y at xz.
func _build_support_post(xz: Vector3, base_y: float, top_y: float, color: Color) -> MeshInstance3D:
	if top_y <= base_y:
		return null
	var st := _new_st(color)
	var r := ROOF_SUPPORT_RADIUS
	var cx := xz.x
	var cz := xz.z
	# Four corners of the square cross-section (CCW when viewed from above)
	var c0 := Vector3(cx - r, 0.0, cz - r)
	var c1 := Vector3(cx + r, 0.0, cz - r)
	var c2 := Vector3(cx + r, 0.0, cz + r)
	var c3 := Vector3(cx - r, 0.0, cz + r)
	var corners := [c0, c1, c2, c3]
	# Side walls
	for i: int in range(4):
		var a: Vector3 = corners[i]
		var b: Vector3 = corners[(i + 1) % 4]
		var bl := Vector3(a.x, base_y, a.z)
		var br := Vector3(b.x, base_y, b.z)
		var tr := Vector3(b.x, top_y, b.z)
		var tl := Vector3(a.x, top_y, a.z)
		_add_quad(st, bl, br, tr, tl)
	return _make_mesh(st, "Support")

## Build a flat roof as a solid slab with thickness (top, bottom, and side faces).
func _build_roof_slab(points: PackedVector3Array, base_y: float, thickness: float, color: Color) -> MeshInstance3D:
	var top_y := base_y + thickness
	var st := _new_st(color)
	# Top face (CCW, upward normal) and bottom face (downward normal)
	var indices := PolygonUtils.triangulate_xz(points)
	for i: int in range(0, indices.size(), 3):
		var ia: int = indices[i]
		var ib: int = indices[i + 1]
		var ic: int = indices[i + 2]
		# Top face
		_add_tri(st,
			Vector3(points[ia].x, top_y, points[ia].z),
			Vector3(points[ib].x, top_y, points[ib].z),
			Vector3(points[ic].x, top_y, points[ic].z))
		# Bottom face (reversed winding so it faces down)
		_add_tri(st,
			Vector3(points[ia].x, base_y, points[ia].z),
			Vector3(points[ic].x, base_y, points[ic].z),
			Vector3(points[ib].x, base_y, points[ib].z))
	# Side faces around the perimeter
	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var bl := Vector3(p0.x, base_y, p0.z)
		var br := Vector3(p1.x, base_y, p1.z)
		var tr := Vector3(p1.x, top_y, p1.z)
		var tl := Vector3(p0.x, top_y, p0.z)
		_add_quad(st, bl, br, tr, tl)
	return _make_mesh(st, "Roof")

## Parse a height string value to meters. Handles:
## - bare numbers (assumed meters): "12", "12.5"
## - explicit meters: "12 m", "12m"
## - feet: "40'", "40 ft", "40ft"
## - feet and inches: "40'6\"", though this is rare
func _parse_height(value: String) -> float:
	var s := value.strip_edges()
	if s.is_empty():
		return 0.0
	# Check for feet indicator
	if s.ends_with("'") or s.ends_with("ft"):
		var num_str := s.replace("ft", "").replace("'", "").strip_edges()
		var ft := num_str.to_float()
		return ft * 0.3048
	# Check for explicit meters suffix
	if s.ends_with("m"):
		var num_str := s.left(s.length() - 1).strip_edges()
		return num_str.to_float()
	# Bare number (assumed meters)
	return s.to_float()

## Average terrain elevation across a footprint's nodes. Used to seat the whole
## building on the DEM. Returns 0.0 for a flat world (node.y all zero).
func _average_footprint_y(points: PackedVector3Array) -> float:
	if points.is_empty():
		return 0.0
	var sum := 0.0
	for p: Vector3 in points:
		sum += p.y
	return sum / points.size()

func _get_min_height(tags: Dictionary) -> float:
	if tags.has("min_height"):
		var h: float = _parse_height(tags["min_height"])
		if h > 0.0:
			return h
	if tags.has("building:min_level"):
		var levels: int = tags["building:min_level"].to_int()
		if levels > 0:
			return levels * FLOOR_HEIGHT
	return 0.0

func _get_building_height(tags: Dictionary) -> float:
	if tags.has("height"):
		var h: float = _parse_height(tags["height"])
		if h > 0.0:
			return h
	if tags.has("building:levels"):
		var levels: int = tags["building:levels"].to_int()
		if levels > 0:
			# building:levels counts only facade floors (excluding roof levels).
			# To get total height we must also add roof levels.
			var roof_levels: int = 0
			if tags.has("roof:levels"):
				roof_levels = tags["roof:levels"].to_int()
			return (levels + roof_levels) * FLOOR_HEIGHT
	return DEFAULT_HEIGHT

func _get_roof_shape(tags: Dictionary) -> String:
	var shape: String = tags.get("roof:shape", "flat")
	shape = shape.strip_edges().to_lower()
	if ROOF_SHAPE_ALIASES.has(shape):
		shape = ROOF_SHAPE_ALIASES[shape]
	return shape

func _get_roof_height(tags: Dictionary, roof_shape: String, points: PackedVector3Array = PackedVector3Array(), orientation: String = "along") -> float:
	if tags.has("roof:height"):
		var h: float = _parse_height(tags["roof:height"])
		if h > 0.0:
			return h
	if tags.has("roof:levels"):
		var levels: int = tags["roof:levels"].to_int()
		if levels > 0:
			return levels * FLOOR_HEIGHT
	if tags.has("roof:angle"):
		var angle_deg: float = tags["roof:angle"].to_float()
		if angle_deg > 0.0 and angle_deg < 90.0 and points.size() >= 3:
			# Compute the building width perpendicular to the ridge
			var ridge_dir := PolygonUtils.polygon_longest_edge_dir(points)
			if orientation == "across":
				ridge_dir = Vector3(-ridge_dir.z, 0.0, ridge_dir.x)
			var perp_dir := Vector3(-ridge_dir.z, 0.0, ridge_dir.x)
			var centroid := PolygonUtils.polygon_centroid(points)
			var min_perp := INF
			var max_perp := -INF
			for p: Vector3 in points:
				var proj := PolygonUtils.project_xz(p, centroid, perp_dir)
				min_perp = min(min_perp, proj)
				max_perp = max(max_perp, proj)
			var half_width := absf(max_perp - min_perp) / 2.0
			return tan(deg_to_rad(angle_deg)) * half_width
	if roof_shape == "flat":
		return 0.0
	return DEFAULT_ROOF_HEIGHT

func _get_roof_color(tags: Dictionary) -> Color:
	if tags.has("roof:colour"):
		var c: String = tags["roof:colour"].strip_edges().to_lower()
		var parsed := _parse_color(c)
		if parsed != Color.BLACK:
			return parsed
	elif tags.has("roof:color"):
		var c: String = tags["roof:color"].strip_edges().to_lower()
		var parsed := _parse_color(c)
		if parsed != Color.BLACK:
			return parsed
	if tags.has("roof:material"):
		var mat_name: String = tags["roof:material"].strip_edges().to_lower()
		if ROOF_MATERIAL_COLORS.has(mat_name):
			return ROOF_MATERIAL_COLORS[mat_name]
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

func _build_walls(points: PackedVector3Array, height: float, color: Color, base_y: float = 0.0) -> MeshInstance3D:
	# Points are always CCW (normalized in _build_building_mesh)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]

		var bl := Vector3(p0.x, base_y, p0.z)
		var br := Vector3(p1.x, base_y, p1.z)
		var tr_v := Vector3(p1.x, base_y + height, p1.z)
		var tl := Vector3(p0.x, base_y + height, p0.z)

		var wall_dir := (br - bl).normalized()
		var normal := Vector3(wall_dir.z, 0.0, -wall_dir.x).normalized()

		# CCW polygon: bl -> tr_v -> br, bl -> tl -> tr_v
		st.set_normal(normal)
		st.add_vertex(bl)
		st.set_normal(normal)
		st.add_vertex(tr_v)
		st.set_normal(normal)
		st.add_vertex(br)

		st.set_normal(normal)
		st.add_vertex(bl)
		st.set_normal(normal)
		st.add_vertex(tl)
		st.set_normal(normal)
		st.add_vertex(tr_v)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Walls"
	mesh_instance.mesh = st.commit()
	return mesh_instance

# ─── Roof shape dispatch ─────────────────────────────────────────────────────

func _build_roof_shape(points: PackedVector3Array, wall_h: float, roof_h: float,
		roof_color: Color, wall_color: Color, shape: String, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var base_y := BUILDING_Y + wall_h
	match shape:
		"gabled":
			return _roof_gabled(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"hipped":
			return _roof_hipped(points, base_y, roof_h, roof_color, orientation, roof_direction)
		"pyramidal":
			return _roof_pyramidal(points, base_y, roof_h, roof_color)
		"skillion":
			return _roof_skillion(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"half-hipped":
			return _roof_half_hipped(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"gambrel":
			return _roof_gambrel(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"mansard":
			return _roof_mansard(points, base_y, roof_h, roof_color, orientation)
		"round":
			return _roof_round(points, base_y, roof_h, roof_color, orientation, roof_direction)
		"dome":
			return _roof_dome(points, base_y, roof_h, roof_color)
		"onion":
			return _roof_onion(points, base_y, roof_h, roof_color)
		"saltbox":
			return _roof_saltbox(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		"sawtooth":
			return _roof_sawtooth(points, base_y, roof_h, roof_color, wall_color, orientation, roof_direction)
		_:
			return _roof_flat(points, base_y, roof_color)

# ─── Helper: get ridge axis direction based on orientation tag ────────────────

func _get_ridge_dir(points: PackedVector3Array, orientation: String, roof_direction: float = -1.0) -> Vector3:
	if roof_direction >= 0.0:
		var d_rad := deg_to_rad(roof_direction)
		# roof:direction is the compass bearing the roof faces (perpendicular to ridge).
		# Compass: 0=north(-Z), 90=east(+X), 180=south(+Z), 270=west(-X).
		# Ridge is perpendicular to the facing direction, rotated 90° CW in XZ.
		return Vector3(cos(d_rad), 0.0, sin(d_rad)).normalized()
	var longest := PolygonUtils.polygon_longest_edge_dir(points)
	if orientation == "across":
		return Vector3(-longest.z, 0.0, longest.x)
	return longest

func _get_perp_dir(ridge_dir: Vector3) -> Vector3:
	return Vector3(-ridge_dir.z, 0.0, ridge_dir.x)

# ─── Helper: add a triangle to SurfaceTool with auto-computed normal ─────────

func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	PolygonUtils.add_tri(st, a, b, c)

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
		orientation: String, roof_direction: float = -1.0) -> Dictionary:
	var ridge_dir := _get_ridge_dir(points, orientation, roof_direction)
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

# ─── Linear profile helper ───────────────────────────────────────────────────
# Generic roof builder using the linear profile approach from UrbanEye3D.
# A profile is defined as an array of Vector2(x, y) where x goes from 0.0 to
# 1.0 across the building width (perpendicular to ridge) and y is the height
# fraction (0.0 = base, 1.0 = peak).
#
# The building polygon is sliced into strips along each profile breakpoint
# (e.g. the ridge for a gabled roof) using Geometry2D.intersect_polygons.
# Each strip is triangulated independently so no triangle ever crosses a
# breakpoint line, preventing the "collapsed ridge" artefact that 2D
# triangulation produces on L-shaped / concave buildings.

func _build_linear_profile_roof(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float, profile: Array[Vector2]) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_perp: float = rg["min_perp"]
	var max_perp: float = rg["max_perp"]
	var perp_span := absf(max_perp - min_perp)
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj

	# Collect the interior profile breakpoint x-values (excluding 0 and 1)
	var break_xs: Array[float] = []
	for bp: Vector2 in profile:
		if bp.x > 0.001 and bp.x < 0.999:
			break_xs.append(bp.x)
	break_xs.sort()

	# Build the list of strip boundaries: [0.0, break1, break2, ..., 1.0]
	var boundaries: Array[float] = [0.0]
	boundaries.append_array(break_xs)
	boundaries.append(1.0)

	# Convert polygon to 2D (XZ → XY) for clipping, stripping closing vertex
	var n := points.size()
	var closed := n > 1 and points[0].distance_to(points[n - 1]) < 0.01
	var inner_n := n - 1 if closed else n
	var poly_2d: PackedVector2Array = []
	for idx: int in range(inner_n):
		poly_2d.append(Vector2(points[idx].x, points[idx].z))

	# 2D axes for building the clip rectangles
	var perp_2d := Vector2(perp_dir.x, perp_dir.z)
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var ridge_2d := Vector2(ridge_dir.x, ridge_dir.z)
	var centroid_2d := Vector2(centroid.x, centroid.z)
	# Extend clip rectangles well past the building along the ridge
	var extend := proj_span + 20.0

	var st_roof := _new_st(roof_color)
	var st_gable := _new_st(wall_color)

	# For each strip between adjacent profile breakpoints, clip the polygon
	# to that strip, then triangulate the clipped region.
	for si: int in range(boundaries.size() - 1):
		var bx0 := boundaries[si]
		var bx1 := boundaries[si + 1]

		# The strip runs between two lines at perp positions bx0 and bx1.
		# Convert to world-space offsets from centroid.
		var perp0_off := min_perp + bx0 * perp_span  # offset from centroid along perp_dir
		var perp1_off := min_perp + bx1 * perp_span

		# Build clip rectangle: a wide band along the ridge direction
		# between the two perp lines. Corners at:
		#   centroid + perp_dir * perp_off ± ridge_dir * extend
		var c0 := centroid_2d + perp_2d * perp0_off - ridge_2d * extend
		var c1 := centroid_2d + perp_2d * perp0_off + ridge_2d * extend
		var c2 := centroid_2d + perp_2d * perp1_off + ridge_2d * extend
		var c3 := centroid_2d + perp_2d * perp1_off - ridge_2d * extend
		var clip_rect := PackedVector2Array([c0, c1, c2, c3])

		var clips := Geometry2D.intersect_polygons(poly_2d, clip_rect)
		for clip: PackedVector2Array in clips:
			var tri_indices := Geometry2D.triangulate_polygon(clip)
			if tri_indices.is_empty():
				continue
			for ti: int in range(0, tri_indices.size(), 3):
				var v: Array[Vector3] = []
				for vi: int in range(3):
					var cp := clip[tri_indices[ti + vi]]
					var perp := (cp.x - centroid.x) * perp_dir.x + (cp.y - centroid.z) * perp_dir.z
					var px := clampf((perp - min_perp) / maxf(perp_span, 0.001), 0.0, 1.0)
					var h_frac := _sample_profile(profile, px)
					v.append(Vector3(cp.x, base_y + roof_h * h_frac, cp.y))
				_add_tri(st_roof, v[0], v[1], v[2])

	# Gable wall patches: use the subdivided polygon for edge-by-edge patches.
	var sub_points := _subdivide_at_profile_breaks(points, centroid, perp_dir, min_perp, perp_span, break_xs)
	var n_sub := sub_points.size()
	for i: int in range(n_sub - 1):
		var p0 := sub_points[i]
		var p1 := sub_points[i + 1]
		var perp_v0 := PolygonUtils.project_xz(p0, centroid, perp_dir)
		var perp_v1 := PolygonUtils.project_xz(p1, centroid, perp_dir)
		var px0 := clampf((perp_v0 - min_perp) / maxf(perp_span, 0.001), 0.0, 1.0)
		var px1 := clampf((perp_v1 - min_perp) / maxf(perp_span, 0.001), 0.0, 1.0)
		var ry0 := base_y + roof_h * _sample_profile(profile, px0)
		var ry1 := base_y + roof_h * _sample_profile(profile, px1)

		if ry0 > base_y + 0.01 or ry1 > base_y + 0.01:
			var bl := Vector3(p0.x, base_y, p0.z)
			var br := Vector3(p1.x, base_y, p1.z)
			var tr := Vector3(p1.x, ry1, p1.z)
			var tl := Vector3(p0.x, ry0, p0.z)
			if ry0 <= base_y + 0.01:
				_add_tri(st_gable, bl, tr, br)
			elif ry1 <= base_y + 0.01:
				_add_tri(st_gable, bl, tl, br)
			else:
				_add_tri(st_gable, bl, tr, br)
				_add_tri(st_gable, bl, tl, tr)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st_roof, "Roof"))
	result.append(_make_mesh(st_gable, "Gables"))
	return result

## Subdivide polygon edges where they cross profile breakpoint lines.
## For a gabled roof with profile [0:0, 0.5:1, 1:0], the breakpoint at x=0.5
## is the ridge line. Any edge crossing that line gets a new vertex inserted
## at the crossing point, so wall patches can be built edge-by-edge.
func _subdivide_at_profile_breaks(points: PackedVector3Array, centroid: Vector3,
		perp_dir: Vector3, min_perp: float, perp_span: float,
		break_xs: Array[float]) -> PackedVector3Array:
	if break_xs.is_empty() or perp_span < 0.001:
		return points

	# Convert break x-values [0,1] to perpendicular world-space positions
	var break_perps: Array[float] = []
	for bx: float in break_xs:
		break_perps.append(min_perp + bx * perp_span)

	var result: PackedVector3Array = []
	var n := points.size()
	for i: int in range(n - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		result.append(p0)

		var perp0 := PolygonUtils.project_xz(p0, centroid, perp_dir)
		var perp1 := PolygonUtils.project_xz(p1, centroid, perp_dir)

		# Collect all breakpoints that lie strictly between perp0 and perp1
		var crossings: Array[float] = []
		for bp: float in break_perps:
			if (perp0 < bp - 0.001 and bp + 0.001 < perp1) or (perp1 < bp - 0.001 and bp + 0.001 < perp0):
				crossings.append(bp)

		# Sort crossings by distance from p0
		if crossings.size() > 1:
			if perp0 > perp1:
				crossings.sort()
				crossings.reverse()
			else:
				crossings.sort()

		# Insert interpolated vertices at each crossing
		for bp: float in crossings:
			var t := (bp - perp0) / (perp1 - perp0)
			var px := p0.x + (p1.x - p0.x) * t
			var pz := p0.z + (p1.z - p0.z) * t
			result.append(Vector3(px, 0.0, pz))

	# Add closing vertex
	if n > 0:
		result.append(points[n - 1])
	return result

## Sample a piecewise-linear profile at position x (0.0 to 1.0).
## Profile is an array of Vector2(x_pos, height_fraction) sorted by x_pos.
func _sample_profile(profile: Array[Vector2], x: float) -> float:
	if profile.is_empty():
		return 0.0
	if x <= profile[0].x:
		return profile[0].y
	for i: int in range(profile.size() - 1):
		if x <= profile[i + 1].x:
			var t := (x - profile[i].x) / maxf(profile[i + 1].x - profile[i].x, 0.001)
			return lerpf(profile[i].y, profile[i + 1].y, t)
	return profile[profile.size() - 1].y

# ─── Flat roof ────────────────────────────────────────────────────────────────

func _roof_flat(points: PackedVector3Array, base_y: float, color: Color) -> Array[Node3D]:
	var mi := PolygonUtils.build_flat_polygon_mesh(points, color, base_y)
	if mi != null:
		mi.name = "Roof"
		return [mi]
	return []

# ─── Gabled roof ─────────────────────────────────────────────────────────────
# Delegates to the linear profile system with a V-shaped gabled profile:
# [0:0, 0.5:1, 1:0]. The profile system handles edge subdivision at the ridge
# breakpoint so rectangular buildings get a proper ridge peak.

func _roof_gabled(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	return _build_linear_profile_roof(points, base_y, roof_h, roof_color, wall_color,
		orientation, roof_direction,
		# Gabled profile: V-shape, peak at centre
		[Vector2(0.0, 0.0), Vector2(0.5, 1.0), Vector2(1.0, 0.0)])

# ─── Hipped roof ─────────────────────────────────────────────────────────────
# Each polygon edge fans to the nearest ridge point. For edges near the hip
# ends, a triangle connects to the ridge endpoint. For side edges, a quad
# connects to the corresponding ridge segment. Per-vertex projection ensures
# correct geometry on arbitrary ngon shapes.

func _roof_hipped(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)

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

	# Fan from each edge to nearest ridge point(s), using per-vertex projection
	var rs_proj: float = min_proj + inset
	var re_proj: float = max_proj - inset
	var ridge_span := re_proj - rs_proj
	for i: int in range(points.size() - 1):
		var p0 := Vector3(points[i].x, base_y, points[i].z)
		var p1 := Vector3(points[i + 1].x, base_y, points[i + 1].z)

		# Per-vertex projections onto the ridge direction
		var proj0 := PolygonUtils.project_xz(p0, centroid, ridge_dir)
		var proj1 := PolygonUtils.project_xz(p1, centroid, ridge_dir)

		# Classify each vertex: before ridge start, on ridge segment, or after ridge end
		# For vertices in the hip zone, connect to the nearest ridge endpoint
		# For vertices along the ridge, connect to the corresponding ridge position
		var r0: Vector3 = _hipped_ridge_point(proj0, rs_proj, re_proj, ridge_span, ridge_start, ridge_end)
		var r1: Vector3 = _hipped_ridge_point(proj1, rs_proj, re_proj, ridge_span, ridge_start, ridge_end)

		# If both vertices map to the same ridge point, it's a triangle
		if r0.distance_to(r1) < 0.01:
			_add_tri(st, p1, p0, r0)
		else:
			_add_quad(st, p1, p0, r0, r1)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	return result

## Map a vertex's ridge-direction projection to its ridge point for hipped roofs.
func _hipped_ridge_point(proj: float, rs_proj: float, re_proj: float,
		ridge_span: float, ridge_start: Vector3, ridge_end: Vector3) -> Vector3:
	if proj <= rs_proj:
		return ridge_start
	elif proj >= re_proj:
		return ridge_end
	else:
		var t := clampf((proj - rs_proj) / maxf(ridge_span, 0.001), 0.0, 1.0)
		return ridge_start.lerp(ridge_end, t)

# ─── Pyramidal roof ──────────────────────────────────────────────────────────
# Uses the conic profile approach: linear taper from base to apex.
# This is equivalent to the old simple centroid+apex fan but uses the shared
# conic profile infrastructure for consistency.

func _roof_pyramidal(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	# Pyramidal profile: straight line from base (scale=1, h=0) to apex (scale=0, h=1)
	var profile: Array[Vector2] = [Vector2(1.0, 0.0), Vector2(0.0, 1.0)]
	return _build_conic_profile_roof(points, base_y, roof_h, roof_color, centroid, profile)

# ─── Skillion roof (mono-pitch) ──────────────────────────────────────────────

func _roof_skillion(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)
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

	# Wall extension: fill the gap between wall top (base_y) and sloped roof.
	# Winding matches _build_walls for CCW polygons: (bl, tl/tr, br).
	var st_wall := _new_st(wall_color)
	for i: int in range(points.size() - 1):
		var y0 := roof_points[i].y
		var y1 := roof_points[i + 1].y
		if y0 > base_y + 0.01 or y1 > base_y + 0.01:
			var wall_bl := Vector3(points[i].x, base_y, points[i].z)
			var wall_br := Vector3(points[i + 1].x, base_y, points[i + 1].z)
			var wall_tr := Vector3(points[i + 1].x, y1, points[i + 1].z)
			var wall_tl := Vector3(points[i].x, y0, points[i].z)

			if y0 <= base_y + 0.01:
				_add_tri(st_wall, wall_bl, wall_tr, wall_br)
			elif y1 <= base_y + 0.01:
				_add_tri(st_wall, wall_bl, wall_tl, wall_br)
			else:
				_add_tri(st_wall, wall_bl, wall_tr, wall_br)
				_add_tri(st_wall, wall_bl, wall_tl, wall_tr)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st_roof, "Roof"))
	result.append(_make_mesh(st_wall, "SkillionWalls"))
	return result

# ─── Half-hipped roof ────────────────────────────────────────────────────────
# A gabled roof with small hip triangles replacing the top part of each gable end.
# Uses the strip-sliced approach from _build_linear_profile_roof with
# additional height blending in the hip zones near the building ends.

func _roof_half_hipped(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_perp: float = rg["min_perp"]
	var max_perp: float = rg["max_perp"]
	var perp_span := absf(max_perp - min_perp)
	var perp_mid := (min_perp + max_perp) / 2.0
	var half_span := perp_span / 2.0

	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj

	# Hip inset: how far from the end the ridge starts
	var inset := minf(perp_span * 0.25, proj_span * 0.15)
	var rs_proj := min_proj + inset
	var re_proj := max_proj - inset

	# Strip-slice the polygon along the ridge line (perp x=0.5)
	var break_xs: Array[float] = [0.5]

	var n := points.size()
	var closed := n > 1 and points[0].distance_to(points[n - 1]) < 0.01
	var inner_n := n - 1 if closed else n
	var poly_2d: PackedVector2Array = []
	for idx: int in range(inner_n):
		poly_2d.append(Vector2(points[idx].x, points[idx].z))

	var perp_2d := Vector2(perp_dir.x, perp_dir.z)
	var ridge_2d := Vector2(ridge_dir.x, ridge_dir.z)
	var centroid_2d := Vector2(centroid.x, centroid.z)
	var extend := proj_span + 20.0

	var boundaries: Array[float] = [0.0]
	boundaries.append_array(break_xs)
	boundaries.append(1.0)

	var st_roof := _new_st(roof_color)
	var st_gable := _new_st(wall_color)

	# Triangulate each strip with hip-blended heights
	for si: int in range(boundaries.size() - 1):
		var bx0 := boundaries[si]
		var bx1 := boundaries[si + 1]
		var perp0_off := min_perp + bx0 * perp_span
		var perp1_off := min_perp + bx1 * perp_span

		var c0 := centroid_2d + perp_2d * perp0_off - ridge_2d * extend
		var c1 := centroid_2d + perp_2d * perp0_off + ridge_2d * extend
		var c2 := centroid_2d + perp_2d * perp1_off + ridge_2d * extend
		var c3 := centroid_2d + perp_2d * perp1_off - ridge_2d * extend
		var clip_rect := PackedVector2Array([c0, c1, c2, c3])

		var clips := Geometry2D.intersect_polygons(poly_2d, clip_rect)
		for clip: PackedVector2Array in clips:
			var tri_indices := Geometry2D.triangulate_polygon(clip)
			if tri_indices.is_empty():
				continue
			for ti: int in range(0, tri_indices.size(), 3):
				var v: Array[Vector3] = []
				for vi: int in range(3):
					var cp := clip[tri_indices[ti + vi]]
					var perp := (cp.x - centroid.x) * perp_dir.x + (cp.y - centroid.z) * perp_dir.z
					var dist_from_centre := absf(perp - perp_mid)
					var t := 1.0 - clampf(dist_from_centre / maxf(half_span, 0.001), 0.0, 1.0)
					var h := base_y + roof_h * t
					# Hip blending near ends
					var proj := (cp.x - centroid.x) * ridge_dir.x + (cp.y - centroid.z) * ridge_dir.z
					if proj < rs_proj:
						var end_t := clampf((proj - min_proj) / maxf(inset, 0.001), 0.0, 1.0)
						h = lerpf(base_y, h, end_t)
					elif proj > re_proj:
						var end_t := clampf((max_proj - proj) / maxf(inset, 0.001), 0.0, 1.0)
						h = lerpf(base_y, h, end_t)
					v.append(Vector3(cp.x, h, cp.y))
				_add_tri(st_roof, v[0], v[1], v[2])

	# Gable/hip wall patches
	var sub_points := _subdivide_at_profile_breaks(points, centroid, perp_dir, min_perp, perp_span, break_xs)
	var n_sub := sub_points.size()
	for i: int in range(n_sub - 1):
		var p0 := sub_points[i]
		var p1 := sub_points[i + 1]
		var perp_v0 := PolygonUtils.project_xz(p0, centroid, perp_dir)
		var perp_v1 := PolygonUtils.project_xz(p1, centroid, perp_dir)
		var dist0 := absf(perp_v0 - perp_mid)
		var dist1 := absf(perp_v1 - perp_mid)
		var t0 := 1.0 - clampf(dist0 / maxf(half_span, 0.001), 0.0, 1.0)
		var t1 := 1.0 - clampf(dist1 / maxf(half_span, 0.001), 0.0, 1.0)
		var ry0 := base_y + roof_h * t0
		var ry1 := base_y + roof_h * t1
		# Hip blending
		var proj0 := PolygonUtils.project_xz(p0, centroid, ridge_dir)
		var proj1 := PolygonUtils.project_xz(p1, centroid, ridge_dir)
		if proj0 < rs_proj:
			ry0 = lerpf(base_y, ry0, clampf((proj0 - min_proj) / maxf(inset, 0.001), 0.0, 1.0))
		elif proj0 > re_proj:
			ry0 = lerpf(base_y, ry0, clampf((max_proj - proj0) / maxf(inset, 0.001), 0.0, 1.0))
		if proj1 < rs_proj:
			ry1 = lerpf(base_y, ry1, clampf((proj1 - min_proj) / maxf(inset, 0.001), 0.0, 1.0))
		elif proj1 > re_proj:
			ry1 = lerpf(base_y, ry1, clampf((max_proj - proj1) / maxf(inset, 0.001), 0.0, 1.0))

		if ry0 > base_y + 0.01 or ry1 > base_y + 0.01:
			var bl := Vector3(p0.x, base_y, p0.z)
			var br := Vector3(p1.x, base_y, p1.z)
			var tr := Vector3(p1.x, ry1, p1.z)
			var tl := Vector3(p0.x, ry0, p0.z)
			if ry0 <= base_y + 0.01:
				_add_tri(st_gable, bl, tr, br)
			elif ry1 <= base_y + 0.01:
				_add_tri(st_gable, bl, tl, br)
			else:
				_add_tri(st_gable, bl, tr, br)
				_add_tri(st_gable, bl, tl, tr)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st_roof, "Roof"))
	result.append(_make_mesh(st_gable, "Gables"))
	return result

# ─── Gambrel roof ────────────────────────────────────────────────────────────
# Uses a linear profile approach: gambrel profile has steep lower slope and
# shallow upper slope on each side. Profile from UrbanEye3D's LinearProfiles:
# {0.0:0.0, 0.25:0.75, 0.5:1.0, 0.75:0.75, 1.0:0.0}

func _roof_gambrel(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	return _build_linear_profile_roof(points, base_y, roof_h, roof_color, wall_color,
		orientation, roof_direction,
		# Gambrel profile: steep lower slope, shallow upper
		[Vector2(0.0, 0.0), Vector2(0.25, 0.75), Vector2(0.5, 1.0), Vector2(0.75, 0.75), Vector2(1.0, 0.0)])

# ─── Mansard roof ────────────────────────────────────────────────────────────
# Mansard: steep sloped sides with a flat or nearly-flat top.
# Uses centroid-based inset scaling (like UrbanEye3D's MesherMansard) to create
# the inner polygon, ensuring correct vertex correspondence on any ngon shape.
# The lower steep faces connect outer and inner polygon edges 1:1, then a hipped
# upper portion sits on top.

func _roof_mansard(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, _orientation: String) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var n := points.size() - 1  # exclude closing vertex
	if n < 3:
		return _roof_pyramidal(points, base_y, roof_h, roof_color)

	# Inset polygon by scaling toward centroid (like UrbanEye3D).
	# This preserves vertex count and correspondence, unlike Geometry2D.offset_polygon
	# which may change vertex count.
	var inset_frac := 0.3  # scale inner polygon to 70% of outer
	var lower_h := roof_h * 0.5  # lower steep part is half the roof height
	var lower_y := base_y + lower_h
	var top_y := base_y + roof_h

	var inner_points: PackedVector3Array = []
	for i: int in range(n):
		var px := centroid.x + (points[i].x - centroid.x) * (1.0 - inset_frac)
		var pz := centroid.z + (points[i].z - centroid.z) * (1.0 - inset_frac)
		inner_points.append(Vector3(px, 0.0, pz))
	inner_points.append(inner_points[0])  # close polygon

	var st := _new_st(roof_color)

	# Lower steep side faces: quads connecting outer base edge to inner edge at lower_y
	for i: int in range(n):
		var ni := (i + 1) % n
		var p0 := Vector3(points[i].x, base_y, points[i].z)
		var p1 := Vector3(points[ni].x, base_y, points[ni].z)
		var t0 := Vector3(inner_points[i].x, lower_y, inner_points[i].z)
		var t1 := Vector3(inner_points[ni].x, lower_y, inner_points[ni].z)
		_add_quad(st, p1, p0, t0, t1)

	# Upper portion: pyramidal from inner polygon to apex
	var apex := Vector3(centroid.x, top_y, centroid.z)
	for i: int in range(n):
		var ni := (i + 1) % n
		var t0 := Vector3(inner_points[i].x, lower_y, inner_points[i].z)
		var t1 := Vector3(inner_points[ni].x, lower_y, inner_points[ni].z)
		_add_tri(st, t1, t0, apex)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	return result

# ─── Round roof ──────────────────────────────────────────────────────────────
# Uses the linear profile approach with a semicircular profile.
# Profile from UrbanEye3D's LinearProfiles.ROUND (17 sample points).

func _roof_round(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	# Semicircular profile (sampled at 16 points + endpoints)
	var profile: Array[Vector2] = _make_round_profile(16)
	return _build_linear_profile_roof(points, base_y, roof_h, roof_color, roof_color,
		orientation, roof_direction, profile)

## Round (semicircular) profile: cos/sin arc from 0 to PI mapped to [0,1] range.
func _make_round_profile(segments: int) -> Array[Vector2]:
	var profile: Array[Vector2] = []
	for i: int in range(segments + 1):
		var t := float(i) / segments
		var angle := t * PI
		# x position across the width [0,1], height follows sin curve
		profile.append(Vector2(t, sin(angle)))
	return profile

# ─── Dome roof ───────────────────────────────────────────────────────────────
# Uses per-vertex centroid scaling (like UrbanEye3D's MesherConicProfile):
# each polygon vertex is scaled toward the centroid along concentric rings
# following a dome profile. This naturally handles any polygon shape.

func _roof_dome(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var rings := 8
	var dome_profile: Array[Vector2] = _make_dome_profile(rings)

	return _build_conic_profile_roof(points, base_y, roof_h, roof_color, centroid, dome_profile)

# ─── Conic profile helper (shared by dome, onion, pyramidal) ─────────────────
# Inspired by UrbanEye3D's MesherConicProfile: creates concentric rings of
# vertices by scaling each polygon vertex toward the centroid. The profile
# defines how much to scale (x) and the height (y) at each ring.
# This works on any polygon shape, not just circles or rectangles.

func _build_conic_profile_roof(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, center: Vector3, profile: Array[Vector2]) -> Array[Node3D]:
	var st := _new_st(roof_color)
	var n := points.size() - 1  # exclude closing vertex
	if n < 3:
		return []
	var rows := profile.size() - 1

	# Build vertex rings: ring 0 = base polygon, ring j = scaled toward center
	# profile[j].x = scale factor (1.0 at base, 0.0 at apex)
	# profile[j].y = relative height (0.0 at base, 1.0 at apex)
	var rings: Array[PackedVector3Array] = []
	for j: int in range(rows + 1):
		var ring: PackedVector3Array = []
		var scale_factor: float = profile[j].x
		var ring_y := base_y + roof_h * profile[j].y
		for i: int in range(n):
			var px := center.x + (points[i].x - center.x) * scale_factor
			var pz := center.z + (points[i].z - center.z) * scale_factor
			ring.append(Vector3(px, ring_y, pz))
		rings.append(ring)

	# Create quad strips between adjacent rings
	for j: int in range(rows - 1):
		var lower := rings[j]
		var upper := rings[j + 1]
		for i: int in range(n):
			var ni := (i + 1) % n
			_add_quad(st, lower[i], lower[ni], upper[ni], upper[i])

	# Top ring to apex: triangles
	var top_ring := rings[rows - 1]
	var apex := Vector3(center.x, base_y + roof_h * profile[rows].y, center.z)
	for i: int in range(n):
		var ni := (i + 1) % n
		_add_tri(st, top_ring[i], top_ring[ni], apex)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st, "Roof"))
	return result

## Dome profile: quarter-circle from base (scale=1, h=0) to apex (scale=0, h=1).
func _make_dome_profile(rings: int) -> Array[Vector2]:
	var profile: Array[Vector2] = []
	for j: int in range(rings + 1):
		var t := float(j) / rings
		var angle := t * PI * 0.5
		# x = scale factor (how much of the base polygon shape to keep)
		# y = height fraction
		profile.append(Vector2(cos(angle), sin(angle)))
	return profile

# ─── Onion dome roof ────────────────────────────────────────────────────────
# Uses the same conic profile approach as dome: per-vertex centroid scaling
# with an onion-shaped profile (bulges wider than base, then tapers).
# Profile control points from UrbanEye3D's MesherConicProfile.

func _roof_onion(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var onion_profile := _make_onion_profile()

	return _build_conic_profile_roof(points, base_y, roof_h, roof_color, centroid, onion_profile)

## Onion profile: bulges outward (wider than base), then tapers to a point.
## Control points adapted from UrbanEye3D's onionProfile().
## Vector2(x=scale_factor, y=height_fraction).
func _make_onion_profile() -> Array[Vector2]:
	return [
		Vector2(1.0000, 0.0000),  # base
		Vector2(1.2971, 0.0999),  # bulge outward
		Vector2(1.2971, 0.2462),  # max bulge
		Vector2(1.1273, 0.3608),  # narrowing
		Vector2(0.6219, 0.4785),  # rapid taper
		Vector2(0.2131, 0.5984),  # near tip
		Vector2(0.1003, 0.7243),  # close to tip
		Vector2(0.0000, 1.0000),  # apex
	]

# ─── Saltbox roof ────────────────────────────────────────────────────────────
# Uses the linear profile approach with an asymmetric profile (ridge at 1/3).
# Profile from UrbanEye3D's LinearProfiles.SALTBOX.

func _roof_saltbox(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	return _build_linear_profile_roof(points, base_y, roof_h, roof_color, wall_color,
		orientation, roof_direction,
		# Saltbox profile: peak at 1/3 from one side
		[Vector2(0.0, 0.0), Vector2(0.3333, 1.0), Vector2(1.0, 0.0)])

# ─── Sawtooth roof ───────────────────────────────────────────────────────────

func _roof_sawtooth(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	# Sawtooth: repeated asymmetric ridges (like factory roofs)
	var rg := _compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)
	var min_perp: float = rg["min_perp"]
	var perp_span := absf(float(rg["max_perp"]) - min_perp)

	var tooth_count := maxi(int(perp_span / 4.0), 2)  # one tooth every ~4 meters
	var tooth_width := perp_span / tooth_count

	var st_roof := _new_st(roof_color)
	var st_wall := _new_st(wall_color)

	# Build the roof as strips across the building for each tooth.
	# Each tooth produces: a sloped ramp quad and a vertical drop quad.
	_build_sawtooth_roof_surface(st_roof, st_wall, wall_color, points, base_y, roof_h, rg, min_perp, perp_span, tooth_count, tooth_width)

	# End walls: draw sawtooth cross-section at each end (edges along ridge direction)
	_add_sawtooth_end_walls(st_wall, points, base_y, roof_h, rg, min_perp, perp_span, tooth_count, tooth_width)

	var result: Array[Node3D] = []
	result.append(_make_mesh(st_roof, "Roof"))
	result.append(_make_mesh(st_wall, "SawtoothWalls"))
	return result

func _build_sawtooth_roof_surface(st_roof: SurfaceTool, st_wall: SurfaceTool,
		_wall_color: Color, _points: PackedVector3Array, base_y: float, roof_h: float,
		rg: Dictionary, min_perp: float, _perp_span: float,
		tooth_count: int, tooth_width: float) -> void:
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]

	# For each tooth, build a sloped ramp quad and a vertical drop quad.
	# The ramp spans from min_proj to max_proj (along the ridge) and from
	# tooth_start to tooth_end (along the perp direction).
	for tooth: int in range(tooth_count):
		var ts_perp := min_perp + tooth * tooth_width
		var te_perp := min_perp + (tooth + 1) * tooth_width

		# Four corners of this tooth strip at the building footprint edges
		# Near side (min_proj) and far side (max_proj), at tooth start and end
		var near_start := centroid + ridge_dir * min_proj + perp_dir * ts_perp
		var near_end := centroid + ridge_dir * min_proj + perp_dir * te_perp
		var far_start := centroid + ridge_dir * max_proj + perp_dir * ts_perp
		var far_end := centroid + ridge_dir * max_proj + perp_dir * te_perp

		# Ramp: slopes from base_y at tooth start to base_y + roof_h at tooth end
		var ramp_ns := Vector3(near_start.x, base_y, near_start.z)
		var ramp_ne := Vector3(near_end.x, base_y + roof_h, near_end.z)
		var ramp_fs := Vector3(far_start.x, base_y, far_start.z)
		var ramp_fe := Vector3(far_end.x, base_y + roof_h, far_end.z)

		# Sloped ramp quad (facing up)
		_add_quad(st_roof, ramp_ns, ramp_fs, ramp_fe, ramp_ne)

		# Vertical drop at tooth end (except for the last tooth at the building edge)
		if tooth < tooth_count - 1:
			# The drop goes from base_y + roof_h down to base_y at te_perp
			var drop_near_top := Vector3(near_end.x, base_y + roof_h, near_end.z)
			var drop_near_bot := Vector3(near_end.x, base_y, near_end.z)
			var drop_far_top := Vector3(far_end.x, base_y + roof_h, far_end.z)
			var drop_far_bot := Vector3(far_end.x, base_y, far_end.z)

			# Vertical face (facing toward increasing perp = toward the next tooth)
			_add_quad(st_wall, drop_near_top, drop_far_top, drop_far_bot, drop_near_bot)

func _add_sawtooth_end_walls(st: SurfaceTool, points: PackedVector3Array,
		base_y: float, roof_h: float, rg: Dictionary, min_perp: float,
		_perp_span: float, tooth_count: int, tooth_width: float) -> void:
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj
	var threshold := proj_span * 0.05

	for end_proj: float in [min_proj, max_proj]:
		# Find the two corner vertices at this end
		var end_verts: Array[Vector3] = []
		for i: int in range(points.size() - 1):
			var proj := PolygonUtils.project_xz(points[i], centroid, ridge_dir)
			if absf(proj - end_proj) < threshold + 0.5:
				end_verts.append(points[i])

		if end_verts.size() < 2:
			continue

		# Sort by perpendicular position
		var pd := perp_dir
		end_verts.sort_custom(func(a: Vector3, b: Vector3) -> bool:
			return PolygonUtils.project_xz(a, centroid, pd) < PolygonUtils.project_xz(b, centroid, pd))
		var left := end_verts[0]
		var right := end_verts[end_verts.size() - 1]

		# Walk along the edge from left to right, subdividing by sawtooth teeth.
		# The edge runs along perp_dir from left to right.
		var left_perp := PolygonUtils.project_xz(left, centroid, perp_dir)
		var right_perp := PolygonUtils.project_xz(right, centroid, perp_dir)
		var edge_start := Vector3(left.x, 0, left.z)
		var edge_end := Vector3(right.x, 0, right.z)
		var edge_len := right_perp - left_perp
		if absf(edge_len) < 0.001:
			continue

		# For each tooth, compute the ramp and drop geometry on this end wall
		for tooth: int in range(tooth_count):
			# Perpendicular positions of tooth start and end
			var tooth_start_perp := min_perp + tooth * tooth_width
			var tooth_end_perp := min_perp + (tooth + 1) * tooth_width

			# Clamp to the actual edge extent
			var ts_perp := clampf(tooth_start_perp, left_perp, right_perp)
			var te_perp := clampf(tooth_end_perp, left_perp, right_perp)
			if te_perp - ts_perp < 0.001:
				continue

			# Interpolate XZ positions along the edge
			var ts_frac := (ts_perp - left_perp) / edge_len
			var te_frac := (te_perp - left_perp) / edge_len
			var ts_xz := edge_start.lerp(edge_end, ts_frac)
			var te_xz := edge_start.lerp(edge_end, te_frac)

			# Bottom corners at base_y
			var bl := Vector3(ts_xz.x, base_y, ts_xz.z)
			var br := Vector3(te_xz.x, base_y, te_xz.z)

			# Top of ramp: tooth end is at base_y + roof_h
			var tr_v := Vector3(te_xz.x, base_y + roof_h, te_xz.z)

			# Ramp triangle: from bottom-left, bottom-right, top-right
			# (the ramp goes from base_y at tooth start up to base_y + roof_h at tooth end)
			if end_proj == min_proj:
				_add_tri(st, br, bl, tr_v)
			else:
				_add_tri(st, bl, br, tr_v)
