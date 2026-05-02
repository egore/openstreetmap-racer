class_name OSMRoadBuilder
extends RefCounted

## Builds 3D road meshes from OSM ways tagged with "highway".

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

	var highway_type: String = way.tags.get("highway", "unclassified")
	var width: float = ROAD_WIDTHS.get(highway_type, DEFAULT_WIDTH)
	var color: Color = ROAD_COLORS.get(highway_type, DEFAULT_COLOR)

	# Check for lanes tag to override width
	if way.tags.has("lanes"):
		var lanes: int = way.tags["lanes"].to_int()
		if lanes > 0:
			width = lanes * 3.5

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

	# Build a ribbon mesh along the polyline
	var half_w := width / 2.0
	var sidewalk_sides := _get_sidewalk_sides(way.tags)
	var has_left_sidewalk: bool = sidewalk_sides["left"]
	var has_right_sidewalk: bool = sidewalk_sides["right"]

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var forward := (p1 - p0).normalized()
		var lateral := Vector3(-forward.z, 0.0, forward.x).normalized()
		var right := lateral * half_w

		var v0 := Vector3(p0.x - right.x, ROAD_Y, p0.z - right.z)
		var v1 := Vector3(p0.x + right.x, ROAD_Y, p0.z + right.z)
		var v2 := Vector3(p1.x + right.x, ROAD_Y, p1.z + right.z)
		var v3 := Vector3(p1.x - right.x, ROAD_Y, p1.z - right.z)

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
			_add_sidewalk_segment(sidewalk_st, p0 - right, p1 - right, -lateral, i == 0, i == points.size() - 2)

		if has_right_sidewalk:
			_add_sidewalk_segment(sidewalk_st, p0 + right, p1 + right, lateral, i == 0, i == points.size() - 2)

	var mesh := st.commit()
	if has_left_sidewalk or has_right_sidewalk:
		mesh = sidewalk_st.commit(mesh)

	mesh_instance.mesh = mesh
	return mesh_instance

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

	var inner_start_bottom := Vector3(edge_start.x, SIDEWALK_BASE_Y, edge_start.z)
	var inner_end_bottom := Vector3(edge_end.x, SIDEWALK_BASE_Y, edge_end.z)
	var inner_start_top := Vector3(edge_start.x, SIDEWALK_BASE_Y + SIDEWALK_HEIGHT, edge_start.z)
	var inner_end_top := Vector3(edge_end.x, SIDEWALK_BASE_Y + SIDEWALK_HEIGHT, edge_end.z)

	var outer_start := edge_start + offset
	var outer_end := edge_end + offset
	var outer_start_bottom := Vector3(outer_start.x, SIDEWALK_BASE_Y, outer_start.z)
	var outer_end_bottom := Vector3(outer_end.x, SIDEWALK_BASE_Y, outer_end.z)
	var outer_start_top := Vector3(outer_start.x, SIDEWALK_BASE_Y + SIDEWALK_HEIGHT, outer_start.z)
	var outer_end_top := Vector3(outer_end.x, SIDEWALK_BASE_Y + SIDEWALK_HEIGHT, outer_end.z)

	_add_quad(st, inner_start_top, outer_start_top, outer_end_top, inner_end_top)
	_add_quad(st, outer_start_bottom, outer_start_top, outer_end_top, outer_end_bottom)
	_add_quad(st, inner_start_bottom, inner_end_bottom, inner_end_top, inner_start_top)

	if add_start_cap:
		_add_quad(st, outer_start_bottom, inner_start_bottom, inner_start_top, outer_start_top)

	if add_end_cap:
		_add_quad(st, inner_end_bottom, outer_end_bottom, outer_end_top, inner_end_top)

func _add_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	_add_tri(st, a, b, c)
	_add_tri(st, a, c, d)

func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := Plane(a, b, c).normal
	st.set_normal(normal)
	st.add_vertex(a)
	st.set_normal(normal)
	st.add_vertex(b)
	st.set_normal(normal)
	st.add_vertex(c)
