extends GdUnitTestSuite

## Unit tests for TrafficManager policy helpers that don't need the scene wired.
##
## TrafficManager mostly orchestrates the scene (camera, tile data, physics), but
## a few decisions are pure policy worth pinning in isolation. Right now that's
## the keep-right lane offset: how far to the right of a road's centreline a car
## on that road should drive, decided from the road's width and one-way status.

const TrafficManagerScript := preload("res://scripts/traffic/traffic_manager.gd")
const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")


func _make_manager() -> TrafficManager:
	# No car_path / tile_manager_path wired: _ready() warns and returns, leaving a
	# bare manager whose pure helpers we can call directly.
	var mgr: TrafficManager = TrafficManagerScript.new()
	add_child(mgr)
	auto_free(mgr)
	return mgr


func _road(width: float, one_way: bool) -> TrafficRoadNetwork.Road:
	var road := TrafficRoadNetwork.Road.new()
	road.width = width
	road.one_way = one_way
	return road


func test_two_way_road_offsets_into_right_half() -> void:
	# A two-way road splits into two lanes; a car sits in the centre of the right
	# half — a quarter of the full carriageway width to the right of the centre.
	var mgr := _make_manager()
	assert_float(mgr._lane_offset_for(_road(8.0, false))).is_equal_approx(2.0, 0.001)


func test_one_way_road_stays_centred() -> void:
	# A one-way road uses the whole carriageway for its single direction, so its
	# cars stay on the centreline (no lateral offset).
	var mgr := _make_manager()
	assert_float(mgr._lane_offset_for(_road(8.0, true))).is_equal_approx(0.0, 0.001)


func test_narrower_two_way_road_offsets_less() -> void:
	# The offset scales with width so cars stay within the drawn asphalt on
	# narrow residential streets as well as wide primaries.
	var mgr := _make_manager()
	assert_float(mgr._lane_offset_for(_road(5.0, false))).is_equal_approx(1.25, 0.001)
