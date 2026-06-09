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
	var roof_nodes := RoofBuilder.build_roof_shape(points, min_height + wall_height, roof_height, roof_color, wall_color, roof_shape, roof_orientation, roof_direction)
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
		var roof_nodes := RoofBuilder.build_roof_shape(points, ceiling_y, roof_height, roof_color, wall_color, roof_shape, roof_orientation, roof_direction)
		for node: Node3D in roof_nodes:
			root.add_child(node)

## Build a single vertical support post (square prism) from base_y to top_y at xz.
func _build_support_post(xz: Vector3, base_y: float, top_y: float, color: Color) -> MeshInstance3D:
	if top_y <= base_y:
		return null
	var st := RoofGeometry.new_st(color)
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
		RoofGeometry.add_quad(st, bl, br, tr, tl)
	return RoofGeometry.make_mesh(st, "Support")

## Build a flat roof as a solid slab with thickness (top, bottom, and side faces).
func _build_roof_slab(points: PackedVector3Array, base_y: float, thickness: float, color: Color) -> MeshInstance3D:
	var top_y := base_y + thickness
	var st := RoofGeometry.new_st(color)
	# Top face (CCW, upward normal) and bottom face (downward normal)
	var indices := PolygonUtils.triangulate_xz(points)
	for i: int in range(0, indices.size(), 3):
		var ia: int = indices[i]
		var ib: int = indices[i + 1]
		var ic: int = indices[i + 2]
		# Top face
		RoofGeometry.add_tri(st,
			Vector3(points[ia].x, top_y, points[ia].z),
			Vector3(points[ib].x, top_y, points[ib].z),
			Vector3(points[ic].x, top_y, points[ic].z))
		# Bottom face (reversed winding so it faces down)
		RoofGeometry.add_tri(st,
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
		RoofGeometry.add_quad(st, bl, br, tr, tl)
	return RoofGeometry.make_mesh(st, "Roof")

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
	# Respect scene depth so labels are occluded by buildings/terrain in front
	# of them instead of shining through. Disabling this draws on top of all geometry.
	label.no_depth_test = false
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
