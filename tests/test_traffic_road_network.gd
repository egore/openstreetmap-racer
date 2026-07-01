extends GdUnitTestSuite

## Unit tests for TrafficRoadNetwork, the drivable-road graph the traffic system
## routes AI cars along.
##
## The network turns parsed OSM ways into a flat list of drivable roads carrying
## a width and a width-scaled car capacity. These tests pin the contract the
## spawner relies on:
##
##   1. Only drivable highway=* ways become roads (footways/cycleways/areas out).
##   2. Width comes from the highway class, overridable by lanes/width tags,
##      matching how the road *mesh* is drawn so cars sit on the asphalt.
##   3. Capacity scales with BOTH length and width — the "larger street = more
##      cars" rule the feature is built around.
##   4. Degenerate ways (single node, missing nodes) are dropped, not crashed on.

const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")
const OSMParser := preload("res://scripts/osm_parser.gd")


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Build an OSMData with a straight highway way of the given type running along
## +X for `length` meters (two nodes). Extra tags merge onto the way.
func _data_with_road(highway_type: String, length: float, extra: Dictionary = {}) -> OSMParser.OSMData:
	var data := OSMParser.OSMData.new()
	var n0 := OSMParser.OSMNode.new()
	n0.id = 1
	n0.local_pos = Vector3(0, 0, 0)
	var n1 := OSMParser.OSMNode.new()
	n1.id = 2
	n1.local_pos = Vector3(length, 0, 0)
	data.nodes[1] = n0
	data.nodes[2] = n1

	var way := OSMParser.OSMWay.new()
	way.id = 100
	way.node_ids = [1, 2]
	way.tags = {"highway": highway_type}
	for k: String in extra:
		way.tags[k] = extra[k]
	data.ways[100] = way
	return data


func _first_road(data: OSMParser.OSMData) -> TrafficRoadNetwork.Road:
	var net := TrafficRoadNetwork.new()
	net.build(data)
	var roads := net.get_roads()
	return roads[0] if roads.size() > 0 else null


# ─── Drivability filtering ───────────────────────────────────────────────────

func test_drivable_road_becomes_a_road() -> void:
	var net := TrafficRoadNetwork.new()
	net.build(_data_with_road("residential", 100.0))
	assert_int(net.road_count()).is_equal(1)


func test_footway_is_not_drivable() -> void:
	var net := TrafficRoadNetwork.new()
	net.build(_data_with_road("footway", 100.0))
	assert_int(net.road_count()).is_equal(0)


func test_cycleway_and_path_excluded() -> void:
	var net := TrafficRoadNetwork.new()
	net.build(_data_with_road("cycleway", 100.0))
	assert_int(net.road_count()).is_equal(0)
	net.build(_data_with_road("path", 100.0))
	assert_int(net.road_count()).is_equal(0)


func test_area_highway_excluded() -> void:
	# A pedestrian plaza polygon (area=yes) is not a line to drive down.
	var net := TrafficRoadNetwork.new()
	net.build(_data_with_road("pedestrian", 100.0, {"area": "yes"}))
	assert_int(net.road_count()).is_equal(0)


func test_non_highway_way_ignored() -> void:
	var data := OSMParser.OSMData.new()
	var way := OSMParser.OSMWay.new()
	way.id = 1
	way.node_ids = [1, 2]
	way.tags = {"building": "yes"}
	data.ways[1] = way
	var net := TrafficRoadNetwork.new()
	net.build(data)
	assert_int(net.road_count()).is_equal(0)


# ─── Width resolution ────────────────────────────────────────────────────────

func test_width_from_highway_type() -> void:
	var road := _first_road(_data_with_road("primary", 100.0))
	assert_float(road.width).is_equal_approx(8.0, 0.001)


func test_lanes_tag_overrides_width() -> void:
	var road := _first_road(_data_with_road("residential", 100.0, {"lanes": "4"}))
	assert_float(road.width).is_equal_approx(4 * 3.5, 0.001)


func test_explicit_width_tag_wins() -> void:
	var road := _first_road(_data_with_road("residential", 100.0, {"width": "15"}))
	assert_float(road.width).is_equal_approx(15.0, 0.001)


# ─── One-way detection ───────────────────────────────────────────────────────

func test_oneway_yes_is_one_way() -> void:
	var road := _first_road(_data_with_road("primary", 100.0, {"oneway": "yes"}))
	assert_bool(road.one_way).is_true()


func test_default_is_two_way() -> void:
	var road := _first_road(_data_with_road("primary", 100.0))
	assert_bool(road.one_way).is_false()


# ─── Capacity: the "bigger street = more cars" rule ──────────────────────────

func test_capacity_grows_with_length() -> void:
	var short_road := _first_road(_data_with_road("primary", 100.0))
	var long_road := _first_road(_data_with_road("primary", 400.0))
	assert_int(long_road.capacity).is_greater(short_road.capacity)


func test_wider_road_has_more_capacity_at_same_length() -> void:
	# Same length, wider class → more cars. This is the core feature contract.
	var residential := _first_road(_data_with_road("residential", 300.0))  # width 5
	var motorway := _first_road(_data_with_road("motorway", 300.0))        # width 12
	assert_int(motorway.capacity).is_greater(residential.capacity)


func test_capacity_pure_function_matches_lanes() -> void:
	# capacity_for is pure: a 2-lane-worth road (7 m ≈ 2 lanes) over 180 m should
	# hold about twice a 1-lane (3.5 m) road of the same length.
	var one_lane := TrafficRoadNetwork.capacity_for(180.0, 3.5)
	var two_lane := TrafficRoadNetwork.capacity_for(180.0, 7.0)
	assert_int(two_lane).is_greater(one_lane)


func test_tiny_width_yields_zero_capacity() -> void:
	assert_int(TrafficRoadNetwork.capacity_for(1000.0, 1.0)).is_equal(0)


func test_zero_length_yields_zero_capacity() -> void:
	assert_int(TrafficRoadNetwork.capacity_for(0.0, 8.0)).is_equal(0)


# ─── Degenerate input ────────────────────────────────────────────────────────

func test_single_node_way_dropped() -> void:
	var data := OSMParser.OSMData.new()
	var n := OSMParser.OSMNode.new()
	n.id = 1
	data.nodes[1] = n
	var way := OSMParser.OSMWay.new()
	way.id = 1
	way.node_ids = [1]
	way.tags = {"highway": "residential"}
	data.ways[1] = way
	var net := TrafficRoadNetwork.new()
	net.build(data)
	assert_int(net.road_count()).is_equal(0)


func test_missing_node_refs_dropped() -> void:
	# Way references nodes that aren't in the dataset → fewer than 2 points.
	var data := OSMParser.OSMData.new()
	var way := OSMParser.OSMWay.new()
	way.id = 1
	way.node_ids = [99, 98]
	way.tags = {"highway": "residential"}
	data.ways[1] = way
	var net := TrafficRoadNetwork.new()
	net.build(data)
	assert_int(net.road_count()).is_equal(0)


func test_build_null_data_is_empty() -> void:
	var net := TrafficRoadNetwork.new()
	net.build(null)
	assert_int(net.road_count()).is_equal(0)


func test_total_capacity_sums_roads() -> void:
	var data := _data_with_road("primary", 400.0)
	# Add a second drivable road.
	var n2 := OSMParser.OSMNode.new()
	n2.id = 3
	n2.local_pos = Vector3(0, 0, 300)
	data.nodes[3] = n2
	var way2 := OSMParser.OSMWay.new()
	way2.id = 101
	way2.node_ids = [1, 3]
	way2.tags = {"highway": "residential"}
	data.ways[101] = way2

	var net := TrafficRoadNetwork.new()
	net.build(data)
	var sum := 0
	for r: TrafficRoadNetwork.Road in net.get_roads():
		sum += r.capacity
	assert_int(net.total_capacity()).is_equal(sum)
