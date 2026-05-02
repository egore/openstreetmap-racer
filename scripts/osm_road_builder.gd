class_name OSMRoadBuilder
extends RefCounted

## Builds 3D road meshes from OSM ways tagged with "highway" using
## profile-to-profile interpolation with straight segments and circular arcs.

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
const ROAD_Y := 0.02
const MIN_SEGMENT_LENGTH := 0.5
const EPSILON := 0.001
const ARC_STEP_DEGREES := 10.0

class RoadProfile:
	var center: Vector3
	var tangent: Vector3
	var right: Vector3
	var half_width: float
	var left_point: Vector3
	var right_point: Vector3

class RoadConnection:
	var left_points: PackedVector3Array
	var right_points: PackedVector3Array

func build_road(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	points = _sanitize_points(points)
	if points.size() < 2:
		return null

	var highway_type: String = way.tags.get("highway", "unclassified")
	var width: float = ROAD_WIDTHS.get(highway_type, DEFAULT_WIDTH)
	var color: Color = ROAD_COLORS.get(highway_type, DEFAULT_COLOR)

	if way.tags.has("lanes"):
		var lanes: int = way.tags["lanes"].to_int()
		if lanes > 0:
			width = lanes * 3.5

	var profiles := _build_profiles(points, width)
	if profiles.size() < 2:
		return null

	var left_edge := PackedVector3Array()
	var right_edge := PackedVector3Array()

	for i: int in range(profiles.size() - 1):
		var connection := _solve_profile_connection(profiles[i], profiles[i + 1])
		if connection.left_points.size() < 2 or connection.right_points.size() < 2:
			continue

		_append_strip_points(left_edge, connection.left_points)
		_append_strip_points(right_edge, connection.right_points)

	if left_edge.size() < 2 or right_edge.size() < 2:
		return null

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Road_%d" % way.id
	mesh_instance.mesh = _build_strip_mesh(left_edge, right_edge, color)
	return mesh_instance

func _sanitize_points(points: PackedVector3Array) -> PackedVector3Array:
	var result := PackedVector3Array()
	for i: int in range(points.size()):
		var point := points[i]
		var is_endpoint := i == 0 or i == points.size() - 1
		if is_endpoint or result.is_empty() or result[result.size() - 1].distance_to(point) > MIN_SEGMENT_LENGTH:
			result.append(point)
	return result

func _build_profiles(points: PackedVector3Array, width: float) -> Array[RoadProfile]:
	var profiles: Array[RoadProfile] = []
	var half_width := width / 2.0

	for i: int in range(points.size()):
		var tangent := _profile_tangent(points, i)
		if tangent.length() < EPSILON:
			continue
		var right := Vector3(-tangent.z, 0.0, tangent.x).normalized()
		var profile := RoadProfile.new()
		profile.center = points[i]
		profile.tangent = tangent
		profile.right = right
		profile.half_width = half_width
		profile.left_point = profile.center - right * half_width
		profile.right_point = profile.center + right * half_width
		profiles.append(profile)

	return profiles

func _profile_tangent(points: PackedVector3Array, index: int) -> Vector3:
	if points.size() < 2:
		return Vector3.ZERO

	if index == 0:
		return _flatten(points[1] - points[0]).normalized()
	if index == points.size() - 1:
		return _flatten(points[index] - points[index - 1]).normalized()

	var incoming := _flatten(points[index] - points[index - 1]).normalized()
	var outgoing := _flatten(points[index + 1] - points[index]).normalized()
	var tangent := incoming + outgoing
	if tangent.length() < EPSILON:
		return outgoing
	return tangent.normalized()

func _solve_profile_connection(from_profile: RoadProfile, to_profile: RoadProfile) -> RoadConnection:
	var connection := RoadConnection.new()
	var left_solution := _solve_edge_pair(from_profile.left_point, from_profile.tangent, to_profile.left_point, to_profile.tangent)
	var right_solution := _solve_edge_pair(from_profile.right_point, from_profile.tangent, to_profile.right_point, to_profile.tangent)

	connection.left_points = _resample_edge_solution(left_solution)
	connection.right_points = _resample_edge_solution(right_solution)

	var target_count := maxi(connection.left_points.size(), connection.right_points.size())
	if target_count < 2:
		return connection

	if connection.left_points.size() != target_count:
		connection.left_points = _resample_polyline_to_count(connection.left_points, target_count)
	if connection.right_points.size() != target_count:
		connection.right_points = _resample_polyline_to_count(connection.right_points, target_count)

	return connection

func _solve_edge_pair(start_point: Vector3, start_tangent: Vector3, end_point: Vector3, end_tangent: Vector3) -> Dictionary:
	var start_dir := _flatten(start_tangent).normalized()
	var end_dir := _flatten(end_tangent).normalized()
	var span := _flatten(end_point - start_point)

	if span.length() < MIN_SEGMENT_LENGTH:
		return {"type": "line", "points": PackedVector3Array([start_point, end_point])}

	var cross := _cross_2d(start_dir, end_dir)
	var dot := clampf(start_dir.dot(end_dir), -1.0, 1.0)

	if abs(cross) < 0.0001:
		if dot > 0.95:
			return _solve_parallel_edge_pair(start_point, start_dir, end_point)
		return _solve_s_curve_edge_pair(start_point, start_dir, end_point, end_dir)

	var intersection: Variant = _line_intersection(start_point, start_dir, end_point, end_dir)
	if intersection == null:
		return _solve_s_curve_edge_pair(start_point, start_dir, end_point, end_dir)

	var c: Vector3 = intersection
	var start_dist := c.distance_to(start_point)
	var end_dist := c.distance_to(end_point)
	if start_dist < EPSILON or end_dist < EPSILON:
		return {"type": "line", "points": PackedVector3Array([start_point, end_point])}

	var use_start_fixed := start_dist <= end_dist
	if use_start_fixed:
		return _solve_fillet_edge_pair(start_point, start_dir, end_point, end_dir, c)
	return _solve_fillet_edge_pair(end_point, end_dir, start_point, start_dir, c, true)

func _solve_fillet_edge_pair(fixed_point: Vector3, fixed_dir: Vector3, moving_point: Vector3, moving_dir: Vector3, intersection: Vector3, reverse_result: bool = false) -> Dictionary:
	var fixed_dist := intersection.distance_to(fixed_point)
	var move_sign: float = sign((intersection - moving_point).dot(moving_dir))
	if abs(move_sign) < EPSILON:
		move_sign = 1.0
	var tangent_point: Vector3 = intersection - moving_dir * fixed_dist * move_sign

	var fixed_normal := _left_normal(fixed_dir)
	var moving_normal := _left_normal(moving_dir)
	var center: Variant = _line_intersection(fixed_point, fixed_normal, tangent_point, moving_normal)
	if center == null:
		return _solve_s_curve_edge_pair(fixed_point, fixed_dir, moving_point, moving_dir, reverse_result)

	var radius: float = center.distance_to(fixed_point)
	if radius < EPSILON:
		return _solve_s_curve_edge_pair(fixed_point, fixed_dir, moving_point, moving_dir, reverse_result)

	var arc_points := _sample_arc(center, fixed_point, tangent_point, fixed_dir)
	var polyline := arc_points
	_append_unique_point(polyline, moving_point)

	if reverse_result:
		polyline = _reverse_points(polyline)

	return {"type": "polyline", "points": polyline}

func _solve_parallel_edge_pair(start_point: Vector3, start_dir: Vector3, end_point: Vector3) -> Dictionary:
	var offset := _flatten(end_point - start_point)
	var lateral := offset.dot(_left_normal(start_dir))
	if abs(lateral) < MIN_SEGMENT_LENGTH:
		return {"type": "line", "points": PackedVector3Array([start_point, end_point])}

	var radius: float = abs(lateral) / 2.0
	if radius < EPSILON:
		return {"type": "line", "points": PackedVector3Array([start_point, end_point])}

	var center: Vector3 = start_point + _left_normal(start_dir) * (radius * sign(lateral))
	var start_radius := _flatten(start_point - center)
	var end_radius := -start_radius
	var mid_point: Vector3 = center + end_radius
	var arc_points := _sample_arc_explicit(center, start_point, mid_point, sign(lateral) < 0.0)
	var polyline := arc_points
	_append_unique_point(polyline, end_point)
	return {"type": "polyline", "points": polyline}

func _solve_s_curve_edge_pair(start_point: Vector3, start_dir: Vector3, end_point: Vector3, end_dir: Vector3, reverse_result: bool = false) -> Dictionary:
	var midpoint_profile := _build_intermediary_profile(start_point, start_dir, end_point, end_dir)
	var first := _solve_fillet_or_line(start_point, start_dir, midpoint_profile.point, midpoint_profile.tangent)
	var second := _solve_fillet_or_line(midpoint_profile.point, midpoint_profile.tangent, end_point, end_dir)

	var first_points: PackedVector3Array = first["points"]
	var second_points: PackedVector3Array = second["points"]
	var polyline := PackedVector3Array(first_points)
	for i: int in range(second_points.size()):
		_append_unique_point(polyline, second_points[i])

	if reverse_result:
		polyline = _reverse_points(polyline)

	return {"type": "polyline", "points": polyline}

func _solve_fillet_or_line(start_point: Vector3, start_dir: Vector3, end_point: Vector3, end_dir: Vector3) -> Dictionary:
	var intersection: Variant = _line_intersection(start_point, start_dir, end_point, end_dir)
	if intersection == null:
		return {"type": "line", "points": PackedVector3Array([start_point, end_point])}

	var c: Vector3 = intersection
	var start_dist := c.distance_to(start_point)
	var end_dist := c.distance_to(end_point)
	if start_dist < EPSILON or end_dist < EPSILON:
		return {"type": "line", "points": PackedVector3Array([start_point, end_point])}

	if start_dist <= end_dist:
		return _solve_fillet_edge_pair(start_point, start_dir, end_point, end_dir, c)
	return _solve_fillet_edge_pair(end_point, end_dir, start_point, start_dir, c, true)

func _build_intermediary_profile(start_point: Vector3, start_dir: Vector3, end_point: Vector3, end_dir: Vector3) -> Dictionary:
	var distance := start_point.distance_to(end_point)
	var tangent_scale := distance * 1.25
	var m0 := start_dir * tangent_scale
	var m1 := end_dir * tangent_scale
	var t := 0.5
	var t2 := t * t
	var t3 := t2 * t

	var h00 := 2.0 * t3 - 3.0 * t2 + 1.0
	var h10 := t3 - 2.0 * t2 + t
	var h01 := -2.0 * t3 + 3.0 * t2
	var h11 := t3 - t2
	var point := start_point * h00 + m0 * h10 + end_point * h01 + m1 * h11

	var dh00 := 6.0 * t2 - 6.0 * t
	var dh10 := 3.0 * t2 - 4.0 * t + 1.0
	var dh01 := -6.0 * t2 + 6.0 * t
	var dh11 := 3.0 * t2 - 2.0 * t
	var tangent := start_point * dh00 + m0 * dh10 + end_point * dh01 + m1 * dh11
	if tangent.length() < EPSILON:
		tangent = _flatten(end_point - start_point).normalized()
	else:
		tangent = _flatten(tangent).normalized()

	return {
		"point": point,
		"tangent": tangent,
	}

func _resample_edge_solution(solution: Dictionary) -> PackedVector3Array:
	if not solution.has("points"):
		return PackedVector3Array()
	return solution["points"]

func _sample_arc(center: Vector3, start_point: Vector3, end_point: Vector3, start_tangent: Vector3) -> PackedVector3Array:
	var clockwise := _cross_2d(start_tangent, end_point - start_point) < 0.0
	return _sample_arc_explicit(center, start_point, end_point, clockwise)

func _sample_arc_explicit(center: Vector3, start_point: Vector3, end_point: Vector3, clockwise: bool) -> PackedVector3Array:
	var radius_vec_start := _flatten(start_point - center)
	var radius_vec_end := _flatten(end_point - center)
	var radius := radius_vec_start.length()
	if radius < EPSILON:
		return PackedVector3Array([start_point, end_point])

	var start_angle := atan2(radius_vec_start.z, radius_vec_start.x)
	var end_angle := atan2(radius_vec_end.z, radius_vec_end.x)
	var delta := wrapf(end_angle - start_angle, -PI, PI)
	if clockwise and delta > 0.0:
		delta -= TAU
	elif not clockwise and delta < 0.0:
		delta += TAU

	var segments := maxi(2, int(ceil(abs(rad_to_deg(delta)) / ARC_STEP_DEGREES)) + 1)
	var points := PackedVector3Array()
	for i: int in range(segments):
		var t := float(i) / float(segments - 1)
		var angle := start_angle + delta * t
		points.append(Vector3(center.x + cos(angle) * radius, ROAD_Y, center.z + sin(angle) * radius))
	return points

func _resample_polyline_to_count(points: PackedVector3Array, target_count: int) -> PackedVector3Array:
	if points.size() < 2 or target_count <= 2:
		return PackedVector3Array([points[0], points[points.size() - 1]])

	var lengths := PackedFloat32Array()
	lengths.append(0.0)
	var total := 0.0
	for i: int in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
		lengths.append(total)

	if total < EPSILON:
		var flat := PackedVector3Array()
		for i: int in range(target_count):
			flat.append(points[0])
		return flat

	var result := PackedVector3Array()
	for sample_index: int in range(target_count):
		var target_length := total * float(sample_index) / float(target_count - 1)
		var segment_index := 0
		while segment_index < lengths.size() - 2 and lengths[segment_index + 1] < target_length:
			segment_index += 1
		var segment_start := points[segment_index]
		var segment_end := points[segment_index + 1]
		var segment_length := lengths[segment_index + 1] - lengths[segment_index]
		if segment_length < EPSILON:
			result.append(segment_start)
			continue
		var local_t := (target_length - lengths[segment_index]) / segment_length
		result.append(segment_start.lerp(segment_end, local_t))

	return result

func _build_strip_mesh(left_edge: PackedVector3Array, right_edge: PackedVector3Array, color: Color) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	for i: int in range(min(left_edge.size(), right_edge.size()) - 1):
		var v0 := Vector3(left_edge[i].x, ROAD_Y, left_edge[i].z)
		var v1 := Vector3(right_edge[i].x, ROAD_Y, right_edge[i].z)
		var v2 := Vector3(right_edge[i + 1].x, ROAD_Y, right_edge[i + 1].z)
		var v3 := Vector3(left_edge[i + 1].x, ROAD_Y, left_edge[i + 1].z)

		st.set_normal(Vector3.UP)
		st.add_vertex(v0)
		st.set_normal(Vector3.UP)
		st.add_vertex(v2)
		st.set_normal(Vector3.UP)
		st.add_vertex(v1)

		st.set_normal(Vector3.UP)
		st.add_vertex(v0)
		st.set_normal(Vector3.UP)
		st.add_vertex(v3)
		st.set_normal(Vector3.UP)
		st.add_vertex(v2)

	return st.commit()

func _append_strip_points(target: PackedVector3Array, source: PackedVector3Array) -> void:
	for i: int in range(source.size()):
		_append_unique_point(target, source[i])

func _append_unique_point(points: PackedVector3Array, point: Vector3) -> void:
	if points.is_empty() or points[points.size() - 1].distance_to(point) > EPSILON:
		points.append(point)

func _reverse_points(points: PackedVector3Array) -> PackedVector3Array:
	var reversed := PackedVector3Array()
	for i: int in range(points.size() - 1, -1, -1):
		reversed.append(points[i])
	return reversed

func _flatten(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z)

func _left_normal(direction: Vector3) -> Vector3:
	var dir := _flatten(direction).normalized()
	return Vector3(dir.z, 0.0, -dir.x)

func _cross_2d(a: Vector3, b: Vector3) -> float:
	return a.x * b.z - a.z * b.x

func _line_intersection(point_a: Vector3, dir_a: Vector3, point_b: Vector3, dir_b: Vector3) -> Variant:
	var a := _flatten(dir_a)
	var b := _flatten(dir_b)
	var det := _cross_2d(a, b)
	if abs(det) < EPSILON:
		return null

	var delta := _flatten(point_b - point_a)
	var t := _cross_2d(delta, b) / det
	return Vector3(point_a.x + a.x * t, ROAD_Y, point_a.z + a.z * t)
