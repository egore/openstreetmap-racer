class_name BuildingNeighborhood
extends RefCounted

const CELL_SIZE := 64.0
var _buildings: Dictionary = {}
var _by_id: Dictionary = {}
var _roads: Dictionary = {}
var _entrances: Dictionary = {}


static func for_data(data: OSMParser.OSMData) -> BuildingNeighborhood:
	if data.building_neighborhood == null:
		var context := BuildingNeighborhood.new()
		context._index(data)
		data.building_neighborhood = context
	return data.building_neighborhood as BuildingNeighborhood


func _index(data: OSMParser.OSMData) -> void:
	var relation_tags := {}
	for relation: OSMParser.OSMRelation in data.relations.values():
		if relation.tags.has("building") or relation.tags.get("type", "") == "building":
			for member: Dictionary in relation.members:
				if member["type"] == "way" and member["role"] in ["outer", "part"]:
					relation_tags[member["ref"]] = relation.tags
	for way: OSMParser.OSMWay in data.ways.values():
		var tags: Dictionary = relation_tags.get(way.id, way.tags)
		var points := PolygonUtils.way_to_points(way.node_ids, data.nodes)
		if points.size() < 2:
			continue
		if tags.has("building") or tags.has("building:part") or way.tags.has("building:part"):
			if tags.get("building", "") == "roof":
				continue
			var polygon := PackedVector2Array()
			var bounds := Rect2(Vector2(points[0].x, points[0].z), Vector2.ZERO)
			for p: Vector3 in points:
				var q := Vector2(p.x, p.z)
				polygon.append(q)
				bounds = bounds.expand(q)
			var entry := {"id": way.id, "polygon": polygon, "base": float(way.tags.get("min_height", "0")), "height": float(way.tags.get("height", str(float(way.tags.get("building:levels", "3")) * 3.0))), "part": way.tags.has("building:part"), "area": PolygonUtils.polygon_area_xz(points), "center": bounds.get_center()}
			_by_id[way.id] = entry
			for x: int in range(floori(bounds.position.x / CELL_SIZE), floori(bounds.end.x / CELL_SIZE) + 1):
				for z: int in range(floori(bounds.position.y / CELL_SIZE), floori(bounds.end.y / CELL_SIZE) + 1):
					_append(_buildings, Vector2i(x, z), entry)
		elif tags.has("highway") and not tags["highway"] in ["motorway", "motorway_link", "steps", "construction", "proposed"]:
			for i: int in range(points.size() - 1):
				var a := Vector2(points[i].x, points[i].z)
				var b := Vector2(points[i + 1].x, points[i + 1].z)
				var steps := maxi(1, ceili(a.distance_to(b) / (CELL_SIZE * 0.5)))
				var seen := {}
				for step: int in range(steps + 1):
					var cell := _cell(a.lerp(b, float(step) / steps))
					if not seen.has(cell):
						_append(_roads, cell, [a, b])
						seen[cell] = true
	for node: OSMParser.OSMNode in data.nodes.values():
		if node.tags.has("entrance") and not node.tags["entrance"] in ["no", "exit", "emergency"]:
			var p := Vector2(node.local_pos.x, node.local_pos.z)
			_append(_entrances, _cell(p), p)


func blocked(p: Vector3, own_id: int) -> bool:
	var q := Vector2(p.x, p.z)
	for entry: Dictionary in _buildings.get(_cell(q), []):
		var own: Dictionary = _by_id.get(own_id, {})
		# A containing outline is replaced by its parts, not a neighbouring wall.
		if not own.is_empty() and own.part and not entry.part and entry.area >= own.area and Geometry2D.is_point_in_polygon(own.center, entry.polygon):
			continue
		if entry.id != own_id and p.y >= entry.base and p.y < entry.height and Geometry2D.is_point_in_polygon(q, entry.polygon):
			return true
	return false


func nearest_street(p: Vector3) -> Vector3:
	var q := Vector2(p.x, p.z)
	var best := q
	var distance := 100.0
	var cell := _cell(q)
	for x: int in range(-2, 3):
		for z: int in range(-2, 3):
			for segment: Array in _roads.get(cell + Vector2i(x, z), []):
				var candidate := Geometry2D.get_closest_point_to_segment(q, segment[0], segment[1])
				if candidate.distance_to(q) < distance:
					distance = candidate.distance_to(q)
					best = candidate
	return Vector3(best.x, p.y, best.y)


func entrances_on(a: Vector3, b: Vector3) -> PackedFloat32Array:
	var start := Vector2(a.x, a.z)
	var end := Vector2(b.x, b.z)
	var result := PackedFloat32Array()
	var seen := {}
	var steps := maxi(1, ceili(start.distance_to(end) / (CELL_SIZE * 0.5)))
	for step: int in range(steps + 1):
		var cell := _cell(start.lerp(end, float(step) / steps))
		for x: int in range(-1, 2):
			for z: int in range(-1, 2):
				for p: Vector2 in _entrances.get(cell + Vector2i(x, z), []):
					if not seen.has(p) and p.distance_to(Geometry2D.get_closest_point_to_segment(p, start, end)) < 0.2:
						result.append((p - start).dot((end - start).normalized()))
						seen[p] = true
	return result


static func _cell(p: Vector2) -> Vector2i:
	return Vector2i(floori(p.x / CELL_SIZE), floori(p.y / CELL_SIZE))


static func _append(grid: Dictionary, cell: Vector2i, value: Variant) -> void:
	if not grid.has(cell):
		grid[cell] = []
	grid[cell].append(value)
