class_name BuildingFacadeBuilder
extends RefCounted

const OPENING_SHADER := preload("res://scripts/shaders/building_opening.gdshader")
const DETAIL_DISTANCE := 95.0
const MAX_OPENINGS := 384


static func build(root: Node3D, points: PackedVector3Array, base: float, height: float, style: Dictionary, id: int, context: BuildingNeighborhood = null) -> void:
	if not style.openings or height < 2.4:
		return
	var openings := BuildingDetailGeometry.surface()
	var frames := BuildingDetailGeometry.surface()
	var center := PolygonUtils.polygon_centroid(points)
	var street := context.nearest_street(center) if context != null else center
	var front := -1
	var best := -INF
	var tagged_doors := {}
	for edge: int in range(points.size() - 1):
		var a := points[edge]
		var b := points[edge + 1]
		var length := a.distance_to(b)
		if length < 2.0:
			continue
		var normal := (b - a).normalized().cross(Vector3.UP)
		var mid := (a + b) * 0.5
		if context != null:
			var doors := context.entrances_on(a, b)
			if not doors.is_empty():
				tagged_doors[edge] = doors
			if context.blocked(mid + normal * 0.2 + Vector3.UP * (base + 1.0), id):
				continue
		var score := length if street.is_equal_approx(center) else normal.dot((street - mid).normalized()) * 100.0 - mid.distance_to(street)
		if score > best:
			best = score
			front = edge
	var floors := clampi(roundi(height / 3.0), 1, 80)
	var tagged_floors := int(style.tags.get("building:levels", "0"))
	if tagged_floors > 0 and height / tagged_floors >= 2.4:
		floors = mini(tagged_floors, 80)
	var floor_height := height / floors
	var count := 0
	for edge: int in range(points.size() - 1):
		var a := points[edge] + Vector3.UP * base
		var b := points[edge + 1] + Vector3.UP * base
		var length := a.distance_to(b)
		if length < 2.0:
			continue
		var along := (b - a).normalized()
		var normal := along.cross(Vector3.UP)
		var bays := clampi(floori((length - 0.6) / float(style.bay_width)), 1, 64)
		var spacing := (length - 0.6) / bays
		var doors: PackedFloat32Array = tagged_doors.get(edge, PackedFloat32Array())
		if doors.is_empty() and tagged_doors.is_empty() and edge == front:
			doors.append(0.3 + spacing * 0.5)
		if base > 0.1:
			doors.clear()
		var door_width := 3.2 if style.warehouse or style.garage else 1.05
		door_width = minf(door_width, length - 0.8)
		var door_height := minf(2.7 if style.warehouse or style.garage else 2.2, height - 0.25)
		for door: float in doors:
			if door - door_width * 0.5 < 0.2 or door + door_width * 0.5 > length - 0.2:
				continue
			var p := a + along * door
			if count < MAX_OPENINGS and not _blocked(context, p, along, normal, door_width, door_height, id):
				_add_opening(openings, frames, p, along, door_width, door_height, float(style.seed + edge * 71) / 65536.0, 2.0 if style.warehouse or style.garage else 1.0)
				count += 1
		if style.garage:
			continue
		for floor_index: int in range(floors):
			if style.warehouse and floor_index == 0:
				continue
			var storefront: bool = style.shop and floor_index == 0 and edge == front
			var width := minf(spacing - 0.45, float(style.window_width))
			var window_height := minf(float(style.window_height), floor_height - 1.1)
			var sill := 0.8
			if storefront:
				width = spacing - 0.3
				window_height = minf(2.4, floor_height - 0.5)
				sill = 0.25
			for bay: int in range(bays):
				if count >= MAX_OPENINGS:
					break
				var u := 0.3 + (bay + 0.5) * spacing
				var overlaps_door := false
				if floor_index * floor_height + sill < door_height:
					for door: float in doors:
						if absf(u - door) < (width + door_width) * 0.5 + 0.2:
							overlaps_door = true
				if overlaps_door or width < 0.6:
					continue
				var p := a + along * u + Vector3.UP * (floor_index * floor_height + sill)
				if _blocked(context, p, along, normal, width, window_height, id):
					continue
				var seed_value := float(absi(hash("%d:%d:%d:%d" % [style.seed, edge, floor_index, bay])) % 256) / 255.0
				_add_opening(openings, frames, p, along, width, window_height, seed_value, 0.0)
				count += 1
	var mat := _opening_material(style.frame_color, style.door_color)
	var panes := BuildingDetailGeometry.finish(openings, "Openings", mat)
	if panes != null:
		panes.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		root.add_child(panes)
	var trim := BuildingDetailGeometry.finish(frames, "WindowTrim", BuildingDetailGeometry.matte(style.frame_color), DETAIL_DISTANCE)
	if trim != null:
		root.add_child(trim)


static var _opening_materials: Dictionary = {}


static func _opening_material(frame_color: Color, door_color: Color) -> ShaderMaterial:
	var key := [frame_color, door_color]
	if not _opening_materials.has(key):
		var mat := ShaderMaterial.new()
		mat.shader = OPENING_SHADER
		mat.set_shader_parameter("frame_color", frame_color)
		mat.set_shader_parameter("door_color", door_color)
		_opening_materials[key] = mat
	return _opening_materials[key]


static func _blocked(context: BuildingNeighborhood, p: Vector3, along: Vector3, normal: Vector3, width: float, height: float, id: int) -> bool:
	if context == null:
		return false
	for x: float in [-0.5, 0.0, 0.5]:
		for y: float in [0.1, 0.5, 0.9]:
			if context.blocked(p + along * width * x + normal * 0.18 + Vector3.UP * height * y, id):
				return true
	return false


static func _add_opening(st: SurfaceTool, frames: SurfaceTool, p: Vector3, along: Vector3, width: float, height: float, seed_value: float, kind: float) -> void:
	var normal := along.cross(Vector3.UP)
	var origin := p - along * width * 0.5 + normal * 0.025
	st.set_normal(normal)
	st.set_color(Color(seed_value, kind / 2.0, 0.0, 1.0))
	st.set_uv2(Vector2(width, height))
	for uv: Vector2 in [Vector2.ZERO, Vector2(0, 1), Vector2.ONE, Vector2.ZERO, Vector2.ONE, Vector2(1, 0)]:
		st.set_uv(uv)
		st.add_vertex(origin + along * width * uv.x + Vector3.UP * height * uv.y)
	var center := p + normal * 0.075
	for side: float in [-1.0, 1.0]:
		BuildingDetailGeometry.box(frames, center + along * side * (width * 0.5 - 0.04) + Vector3.UP * height * 0.5, Vector3(0.08, height, 0.14), along)
		BuildingDetailGeometry.box(frames, center + Vector3.UP * (height * (side + 1.0) * 0.5), Vector3(width + 0.04, 0.09, 0.14), along)
	if kind < 0.5:
		BuildingDetailGeometry.box(frames, center + Vector3.UP * height * 0.5, Vector3(0.05, height, 0.10), along)
		BuildingDetailGeometry.box(frames, center + normal * 0.055 - Vector3.UP * 0.045, Vector3(width + 0.22, 0.12, 0.3), along)
