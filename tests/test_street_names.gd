extends GdUnitTestSuite

## Street-name announcements: the road graph knows street names, the tracker
## decides when to announce one, and the banner shows it.

const StreetNameTrackerScript := preload("res://scripts/street_name_tracker.gd")
const StreetBannerScript := preload("res://scripts/street_banner.gd")
const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")
const OSMParser := preload("res://scripts/osm_parser.gd")


## Two named streets crossing at node 1 (the origin): one east-west along X,
## one north-south along Z.
func _crossroads() -> TrafficRoadNetwork:
	var data := OSMParser.OSMData.new()
	var coords := {1: Vector3.ZERO, 2: Vector3(-100, 0, 0), 3: Vector3(100, 0, 0),
		4: Vector3(0, 0, -100), 5: Vector3(0, 0, 100)}
	for id: int in coords:
		var node := OSMParser.OSMNode.new()
		node.id = id
		node.local_pos = coords[id]
		data.nodes[id] = node
	for spec: Array in [[10, [2, 1, 3], "Oostdijk", "N57"], [11, [4, 1, 5], "Molenweg", ""]]:
		var way := OSMParser.OSMWay.new()
		way.id = spec[0]
		way.node_ids.assign(spec[1])
		way.tags = {"highway": "secondary", "name": spec[2]}
		if spec[3] != "":
			way.tags["ref"] = spec[3]
		data.ways[way.id] = way
	var net := TrafficRoadNetwork.new()
	net.build(data)
	return net


func _feed(tracker: StreetNameTrackerScript, street: String, seconds: float) -> Array[String]:
	var announced: Array[String] = []
	var t := 0.0
	while t < seconds - 0.0001:
		var said := tracker.update(street, 0.1)
		if said != "":
			announced.append(said)
		t += 0.1
	return announced


func test_roads_carry_their_street_name_and_ref() -> void:
	var road := _crossroads().road_under(Vector3(50, 0, 1), Vector3.RIGHT)
	assert_str(road.name).is_equal("Oostdijk")
	assert_str(road.ref).is_equal("N57")


func test_at_a_junction_the_road_along_the_heading_wins() -> void:
	var net := _crossroads()
	assert_str(net.road_under(Vector3(1, 0, 1), Vector3.RIGHT).name).is_equal("Oostdijk")
	assert_str(net.road_under(Vector3(1, 0, 1), Vector3.BACK).name).is_equal("Molenweg")


func test_off_the_carriageway_there_is_no_road() -> void:
	assert_object(_crossroads().road_under(Vector3(50, 0, 20), Vector3.RIGHT)).is_null()


func test_a_street_is_announced_once_after_settling() -> void:
	var tracker := StreetNameTrackerScript.new()
	assert_array(_feed(tracker, "Oostdijk", 0.3)).is_empty()
	assert_array(_feed(tracker, "Oostdijk", 2.0)).contains_exactly(["Oostdijk"])


func test_clipping_a_side_street_is_not_announced() -> void:
	var tracker := StreetNameTrackerScript.new()
	_feed(tracker, "Oostdijk", 1.0)
	assert_array(_feed(tracker, "Molenweg", 0.3)).is_empty()
	assert_array(_feed(tracker, "Oostdijk", 1.0)).is_empty()


func test_an_unnamed_link_between_the_same_street_is_ignored() -> void:
	var tracker := StreetNameTrackerScript.new()
	_feed(tracker, "Oostdijk", 1.0)
	_feed(tracker, "", 2.0)
	assert_array(_feed(tracker, "Oostdijk", 1.0)).is_empty()
	assert_array(_feed(tracker, "Molenweg", 1.0)).contains_exactly(["Molenweg"])


func test_banner_text_prefers_the_name_and_shows_class_and_ref() -> void:
	var road := _crossroads().road_under(Vector3(50, 0, 1), Vector3.RIGHT)
	assert_str(StreetBannerScript.display_name(road)).is_equal("Oostdijk")
	assert_str(StreetBannerScript.detail_for(road)).is_equal("SECONDARY ROAD  /  N57")
	road.name = ""
	assert_str(StreetBannerScript.display_name(road)).is_equal("N57")
	assert_str(StreetBannerScript.display_name(null)).is_equal("")


func test_main_scene_wires_the_banner_to_the_car_and_traffic() -> void:
	var scene: Node = auto_free(preload("res://scenes/main.tscn").instantiate())
	scene.get_node("Car")._engine_sound.free()
	var banner := scene.get_node("HUD/StreetBanner")
	assert_object(banner.get_node_or_null(banner.car_node_path)).is_not_null()
	assert_object(banner.get_node_or_null(banner.traffic_manager_node_path)).is_not_null()
