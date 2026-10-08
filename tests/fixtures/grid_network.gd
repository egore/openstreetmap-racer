extends RefCounted

## A square grid of residential streets `spacing` m apart, rows along X (node
## order west -> east) and columns along Z, as a road graph.

const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")
const OSMParser := preload("res://scripts/osm_parser.gd")


static func build(size: int = 6, spacing: float = 200.0, one_way_rows: bool = false) -> TrafficRoadNetwork:
	var data := OSMParser.OSMData.new()
	for gx in size:
		for gz in size:
			var node := OSMParser.OSMNode.new()
			node.id = node_id(gx, gz)
			node.local_pos = Vector3(gx * spacing, 0, gz * spacing)
			data.nodes[node.id] = node
	var way_id := 1000
	for gz in size:
		var row := OSMParser.OSMWay.new()
		row.id = way_id
		way_id += 1
		for gx in size:
			row.node_ids.append(node_id(gx, gz))
		row.tags = {"highway": "residential"}
		if one_way_rows:
			row.tags["oneway"] = "yes"
		data.ways[row.id] = row
	for gx in size:
		var col := OSMParser.OSMWay.new()
		col.id = way_id
		way_id += 1
		for gz in size:
			col.node_ids.append(node_id(gx, gz))
		col.tags = {"highway": "residential"}
		data.ways[col.id] = col
	var net := TrafficRoadNetwork.new()
	net.build(data)
	return net


static func node_id(gx: int, gz: int) -> int:
	return 1 + gx + gz * 100
