class_name OSMParser
extends RefCounted

## Parses .osm XML files into structured data (nodes, ways, relations).

class OSMNode:
	var id: int
	var lat: float
	var lon: float
	var tags: Dictionary = {}
	var local_pos: Vector3 = Vector3.ZERO  # computed after parsing

class OSMWay:
	var id: int
	var node_ids: Array[int] = []
	var tags: Dictionary = {}

class OSMRelation:
	var id: int
	var members: Array[Dictionary] = []  # {type, ref, role}
	var tags: Dictionary = {}

class OSMData:
	var nodes: Dictionary = {}       # id -> OSMNode
	var ways: Dictionary = {}        # id -> OSMWay
	var relations: Dictionary = {}   # id -> OSMRelation
	var bounds: Rect2 = Rect2()      # lat/lon bounds
	var center_lat: float = 0.0
	var center_lon: float = 0.0

static func parse_file(path: String) -> OSMData:
	var data := OSMData.new()
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("OSMParser: Cannot open file: %s" % path)
		return data

	var xml := XMLParser.new()
	var err := xml.open(path)
	if err != OK:
		push_error("OSMParser: XML parse error for: %s" % path)
		return data

	var current_node: OSMNode = null
	var current_way: OSMWay = null
	var current_relation: OSMRelation = null

	while xml.read() == OK:
		if xml.get_node_type() == XMLParser.NODE_ELEMENT:
			var name := xml.get_node_name()

			if name == "bounds":
				var minlat := xml.get_named_attribute_value_safe("minlat").to_float()
				var minlon := xml.get_named_attribute_value_safe("minlon").to_float()
				var maxlat := xml.get_named_attribute_value_safe("maxlat").to_float()
				var maxlon := xml.get_named_attribute_value_safe("maxlon").to_float()
				data.bounds = Rect2(minlon, minlat, maxlon - minlon, maxlat - minlat)
				data.center_lat = (minlat + maxlat) / 2.0
				data.center_lon = (minlon + maxlon) / 2.0

			elif name == "node":
				current_node = OSMNode.new()
				current_node.id = xml.get_named_attribute_value_safe("id").to_int()
				current_node.lat = xml.get_named_attribute_value_safe("lat").to_float()
				current_node.lon = xml.get_named_attribute_value_safe("lon").to_float()
				if xml.is_empty():
					data.nodes[current_node.id] = current_node
					current_node = null

			elif name == "way":
				current_way = OSMWay.new()
				current_way.id = xml.get_named_attribute_value_safe("id").to_int()
				if xml.is_empty():
					data.ways[current_way.id] = current_way
					current_way = null

			elif name == "relation":
				current_relation = OSMRelation.new()
				current_relation.id = xml.get_named_attribute_value_safe("id").to_int()
				if xml.is_empty():
					data.relations[current_relation.id] = current_relation
					current_relation = null

			elif name == "tag":
				var k := xml.get_named_attribute_value_safe("k")
				var v := xml.get_named_attribute_value_safe("v")
				if current_node != null:
					current_node.tags[k] = v
				elif current_way != null:
					current_way.tags[k] = v
				elif current_relation != null:
					current_relation.tags[k] = v

			elif name == "nd":
				if current_way != null:
					var ref := xml.get_named_attribute_value_safe("ref").to_int()
					current_way.node_ids.append(ref)

			elif name == "member":
				if current_relation != null:
					var member := {
						"type": xml.get_named_attribute_value_safe("type"),
						"ref": xml.get_named_attribute_value_safe("ref").to_int(),
						"role": xml.get_named_attribute_value_safe("role"),
					}
					current_relation.members.append(member)

		elif xml.get_node_type() == XMLParser.NODE_ELEMENT_END:
			var name := xml.get_node_name()
			if name == "node" and current_node != null:
				data.nodes[current_node.id] = current_node
				current_node = null
			elif name == "way" and current_way != null:
				data.ways[current_way.id] = current_way
				current_way = null
			elif name == "relation" and current_relation != null:
				data.relations[current_relation.id] = current_relation
				current_relation = null

	# If no bounds tag, compute from nodes
	if data.bounds.size == Vector2.ZERO and data.nodes.size() > 0:
		var min_lat := INF
		var max_lat := -INF
		var min_lon := INF
		var max_lon := -INF
		for node: OSMNode in data.nodes.values():
			min_lat = min(min_lat, node.lat)
			max_lat = max(max_lat, node.lat)
			min_lon = min(min_lon, node.lon)
			max_lon = max(max_lon, node.lon)
		data.bounds = Rect2(min_lon, min_lat, max_lon - min_lon, max_lat - min_lat)
		data.center_lat = (min_lat + max_lat) / 2.0
		data.center_lon = (min_lon + max_lon) / 2.0

	# Compute local positions for all nodes
	for node: OSMNode in data.nodes.values():
		node.local_pos = _latlon_to_local(node.lat, node.lon, data.center_lat, data.center_lon)

	print("OSMParser: Loaded %d nodes, %d ways, %d relations" % [
		data.nodes.size(), data.ways.size(), data.relations.size()
	])
	return data

## Convert lat/lon to local meter-based coordinates (Y-up, X=east, Z=south)
static func _latlon_to_local(lat: float, lon: float, ref_lat: float, ref_lon: float) -> Vector3:
	var lat_rad := deg_to_rad(ref_lat)
	var meters_per_deg_lat := 111132.0
	var meters_per_deg_lon := 111132.0 * cos(lat_rad)
	var x := (lon - ref_lon) * meters_per_deg_lon
	var z := -(lat - ref_lat) * meters_per_deg_lat  # negative because Z goes south in Godot
	return Vector3(x, 0.0, z)
