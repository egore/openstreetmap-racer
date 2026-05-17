class_name Minimap
extends Control

## Draws a 2D top-down city minimap centered on the player car.
## The car's forward direction always points upward on the minimap.
## All geometry is clipped to a circle using geometric intersection.

@export var map_radius: float = 200.0  ## World-space radius shown on the minimap (meters)
@export var car_node_path: NodePath
@export var tile_manager_node_path: NodePath

var _car: VehicleBody3D = null
var _tile_manager: OSMTileManager = null
var _osm_data: OSMParser.OSMData = null

# Cached draw data for roads/buildings within a large radius
var _cached_road_segments: Array = []   # Array of { points: PackedVector3Array, highway: String }
var _cached_building_outlines: Array = []  # Array of PackedVector3Array
var _cache_center: Vector3 = Vector3.ZERO

# Pre-built circle polygon used for geometric clipping (built once in _ready)
var _clip_circle: PackedVector2Array

# Colors
const BG_COLOR := Color(0.15, 0.18, 0.15, 0.85)
const ROAD_COLOR := Color(0.85, 0.82, 0.75, 0.9)
const MAJOR_ROAD_COLOR := Color(0.95, 0.9, 0.8, 1.0)
const BUILDING_FILL := Color(0.45, 0.42, 0.38, 0.7)
const CAR_COLOR := Color(0.95, 0.3, 0.2, 1.0)
const BORDER_COLOR := Color(0.3, 0.35, 0.3, 0.9)

const MAJOR_HIGHWAYS := ["motorway", "trunk", "primary", "secondary", "tertiary",
	"motorway_link", "trunk_link", "primary_link"]

const CLIP_CIRCLE_SEGMENTS := 48


func _ready() -> void:
	call_deferred("_resolve_nodes")
	# Build clip circle once; will be rebuilt if size changes
	_build_clip_circle()


func _build_clip_circle() -> void:
	var radius := minf(size.x, size.y) / 2.0
	_clip_circle = PackedVector2Array()
	for i: int in range(CLIP_CIRCLE_SEGMENTS):
		var angle := TAU * float(i) / float(CLIP_CIRCLE_SEGMENTS)
		_clip_circle.append(Vector2(cos(angle), sin(angle)) * radius)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_build_clip_circle()


func _resolve_nodes() -> void:
	if car_node_path:
		_car = get_node_or_null(car_node_path) as VehicleBody3D
	if tile_manager_node_path:
		_tile_manager = get_node_or_null(tile_manager_node_path) as OSMTileManager
	if _tile_manager:
		_osm_data = _tile_manager._osm_data


func _process(_delta: float) -> void:
	if _car == null or _osm_data == null:
		_resolve_nodes()
		return
	var car_pos := _car.global_position
	var cache_rebuild_threshold := map_radius * 1.5
	if _cached_road_segments.is_empty() or car_pos.distance_to(_cache_center) > cache_rebuild_threshold:
		_rebuild_cache(car_pos)
	queue_redraw()


func _rebuild_cache(center: Vector3) -> void:
	_cache_center = center
	var cache_radius := map_radius * 3.0
	_cached_road_segments.clear()
	_cached_building_outlines.clear()

	if _osm_data == null:
		return

	for way: OSMParser.OSMWay in _osm_data.ways.values():
		var points := _get_way_points(way)
		if points.is_empty():
			continue

		var any_in_range := false
		for p: Vector3 in points:
			if Vector2(p.x - center.x, p.z - center.z).length() < cache_radius:
				any_in_range = true
				break
		if not any_in_range:
			continue

		if way.tags.has("highway"):
			_cached_road_segments.append({
				"points": points,
				"highway": way.tags.get("highway", "unclassified"),
			})
		elif way.tags.has("building"):
			_cached_building_outlines.append(points)


func _get_way_points(way: OSMParser.OSMWay) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for nid: int in way.node_ids:
		if _osm_data.nodes.has(nid):
			pts.append(_osm_data.nodes[nid].local_pos)
	return pts


func _draw() -> void:
	if _car == null:
		return

	var center_pos := size / 2.0
	var radius := minf(size.x, size.y) / 2.0
	var scale_factor := radius / map_radius

	var car_pos := _car.global_position

	# Car's forward direction in world space.
	# The car drives along its local +Z axis (car_controller.gd line 78).
	var car_forward := _car.global_transform.basis.z
	# atan2(x, z) gives the angle from +Z towards +X.
	var car_angle := atan2(car_forward.x, car_forward.z)

	# Set draw origin to center of the control
	draw_set_transform(center_pos)

	# Background circle
	draw_circle(Vector2.ZERO, radius, BG_COLOR)

	# Draw buildings (clipped to circle)
	for outline: PackedVector3Array in _cached_building_outlines:
		_draw_polygon_on_map(outline, car_pos, car_angle, scale_factor, radius, BUILDING_FILL)

	# Draw roads: minor first, then major on top
	for seg: Dictionary in _cached_road_segments:
		var highway: String = seg["highway"]
		if highway in MAJOR_HIGHWAYS:
			continue
		_draw_road_on_map(seg["points"], car_pos, car_angle, scale_factor, radius, ROAD_COLOR, 1.5)

	for seg: Dictionary in _cached_road_segments:
		var highway: String = seg["highway"]
		if highway not in MAJOR_HIGHWAYS:
			continue
		_draw_road_on_map(seg["points"], car_pos, car_angle, scale_factor, radius, MAJOR_ROAD_COLOR, 2.5)

	# Car indicator: triangle pointing up
	var tri_size := 6.0
	var tri := PackedVector2Array([
		Vector2(0, -tri_size * 1.4),
		Vector2(-tri_size * 0.7, tri_size * 0.7),
		Vector2(tri_size * 0.7, tri_size * 0.7),
	])
	draw_colored_polygon(tri, CAR_COLOR)

	# Border ring
	draw_arc(Vector2.ZERO, radius - 1.0, 0, TAU, 64, BORDER_COLOR, 2.5)

	draw_set_transform(Vector2.ZERO)


func _world_to_minimap(world_pos: Vector3, car_pos: Vector3, car_angle: float, scale_factor: float) -> Vector2:
	var dx := world_pos.x - car_pos.x
	var dz := world_pos.z - car_pos.z

	# Project offset onto car's local axes:
	#   car_forward in XZ = (sin(car_angle), cos(car_angle))  from basis.z
	#   car_right in XZ   = (cos(car_angle), -sin(car_angle))
	#
	# Screen mapping:
	#   screen X = -dot(offset, car_right)   (negated to match world handedness)
	#   screen Y = -dot(offset, car_forward) (ahead = screen up = -Y)

	var sin_a := sin(car_angle)
	var cos_a := cos(car_angle)
	var sx := -(dx * cos_a - dz * sin_a)
	var sy := -(dx * sin_a + dz * cos_a)

	return Vector2(sx, sy) * scale_factor


## Clip a polyline to the circle and draw visible segments.
func _draw_road_on_map(points: PackedVector3Array, car_pos: Vector3, car_angle: float,
		scale_factor: float, radius: float, color: Color, width: float) -> void:
	if points.size() < 2:
		return

	var screen_points := PackedVector2Array()
	for p: Vector3 in points:
		screen_points.append(_world_to_minimap(p, car_pos, car_angle, scale_factor))

	# Quick reject
	var any_visible := false
	for sp: Vector2 in screen_points:
		if sp.length() < radius + 20.0:
			any_visible = true
			break
	if not any_visible:
		return

	# Clip each line segment to the circle and draw visible parts
	var r_sq := radius * radius
	for i: int in range(screen_points.size() - 1):
		var a := screen_points[i]
		var b := screen_points[i + 1]
		var clipped := _clip_segment_to_circle(a, b, radius, r_sq)
		if clipped.size() == 2:
			draw_line(clipped[0], clipped[1], color, width, true)


## Clip a line segment (a->b) to a circle of given radius centered at origin.
## Returns empty array if fully outside, or [clipped_a, clipped_b].
func _clip_segment_to_circle(a: Vector2, b: Vector2, radius: float, r_sq: float) -> Array:
	var a_inside := a.length_squared() <= r_sq
	var b_inside := b.length_squared() <= r_sq

	if a_inside and b_inside:
		return [a, b]

	# Find intersection(s) of line segment with circle
	var d := b - a
	var f := a  # relative to origin (already is)
	var a_coeff := d.dot(d)
	var b_coeff := 2.0 * f.dot(d)
	var c_coeff := f.dot(f) - r_sq
	var discriminant := b_coeff * b_coeff - 4.0 * a_coeff * c_coeff

	if discriminant < 0.0:
		return []  # No intersection

	var sqrt_disc := sqrt(discriminant)
	var t1 := (-b_coeff - sqrt_disc) / (2.0 * a_coeff)
	var t2 := (-b_coeff + sqrt_disc) / (2.0 * a_coeff)

	# Clamp to segment range [0, 1]
	var t_enter := maxf(minf(t1, t2), 0.0)
	var t_exit := minf(maxf(t1, t2), 1.0)

	if t_enter > t_exit:
		return []  # Segment is outside

	var ca: Vector2 = a + d * t_enter if not a_inside else a
	var cb: Vector2 = a + d * t_exit if not b_inside else b
	return [ca, cb]


## Clip a polygon to the circle and draw it.
func _draw_polygon_on_map(points: PackedVector3Array, car_pos: Vector3, car_angle: float,
		scale_factor: float, radius: float, color: Color) -> void:
	if points.size() < 3:
		return

	var screen_points := PackedVector2Array()
	for p: Vector3 in points:
		screen_points.append(_world_to_minimap(p, car_pos, car_angle, scale_factor))

	# Quick reject
	var any_visible := false
	for sp: Vector2 in screen_points:
		if sp.length() < radius + 20.0:
			any_visible = true
			break
	if not any_visible:
		return

	# Intersect the polygon with the clip circle
	var clipped_polys := Geometry2D.intersect_polygons(screen_points, _clip_circle)
	for poly: PackedVector2Array in clipped_polys:
		if poly.size() >= 3:
			var indices := Geometry2D.triangulate_polygon(poly)
			if indices.size() > 0:
				draw_colored_polygon(poly, color)
