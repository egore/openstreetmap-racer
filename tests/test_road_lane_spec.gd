extends GdUnitTestSuite

## Unit tests for RoadLaneSpec — the OSM lane-tag parser that drives the
## procedural lane markings in the asphalt shader.
##
## These pin the tag-precedence rules from
## https://wiki.openstreetmap.org/wiki/Lanes as the project interprets them:
##   • explicit lanes:forward/backward win over `lanes`
##   • `lanes` + oneway derive a sensible per-direction split
##   • unpaved/soft types carry no markings at all

const RoadLaneSpec := preload("res://scripts/road_lane_spec.gd")


func test_default_two_way_road() -> void:
	# No lane tags: a plain residential road is two lanes, one per direction.
	var spec := RoadLaneSpec.from_tags("residential", {})
	assert_int(spec.lane_count).is_equal(2)
	assert_int(spec.forward_lanes).is_equal(1)
	assert_int(spec.backward_lanes).is_equal(1)
	assert_bool(spec.one_way).is_false()
	assert_bool(spec.marked).is_true()
	assert_bool(spec.has_center_line()).is_true()


func test_explicit_lanes_even_split() -> void:
	var spec := RoadLaneSpec.from_tags("primary", {"lanes": "4"})
	assert_int(spec.lane_count).is_equal(4)
	assert_int(spec.forward_lanes).is_equal(2)
	assert_int(spec.backward_lanes).is_equal(2)
	assert_bool(spec.has_center_line()).is_true()


func test_explicit_lanes_odd_split_favours_forward() -> void:
	# 3 lanes two-way: the extra lane goes to the forward side (e.g. a climbing
	# lane). Still has a centre line dividing the directions.
	var spec := RoadLaneSpec.from_tags("secondary", {"lanes": "3"})
	assert_int(spec.lane_count).is_equal(3)
	assert_int(spec.forward_lanes).is_equal(2)
	assert_int(spec.backward_lanes).is_equal(1)
	assert_bool(spec.has_center_line()).is_true()


func test_oneway_has_no_center_line() -> void:
	var spec := RoadLaneSpec.from_tags("primary", {"lanes": "3", "oneway": "yes"})
	assert_int(spec.lane_count).is_equal(3)
	assert_int(spec.forward_lanes).is_equal(3)
	assert_int(spec.backward_lanes).is_equal(0)
	assert_bool(spec.one_way).is_true()
	assert_bool(spec.has_center_line()).is_false()


func test_oneway_default_single_lane() -> void:
	# oneway with no lanes tag → assume a single lane.
	var spec := RoadLaneSpec.from_tags("service", {"oneway": "yes"})
	assert_int(spec.lane_count).is_equal(1)
	assert_bool(spec.one_way).is_true()
	assert_bool(spec.has_center_line()).is_false()


func test_directional_lanes_win() -> void:
	# lanes:forward/backward take precedence and can be asymmetric.
	var spec := RoadLaneSpec.from_tags("primary", {
		"lanes": "3", "lanes:forward": "2", "lanes:backward": "1",
	})
	assert_int(spec.forward_lanes).is_equal(2)
	assert_int(spec.backward_lanes).is_equal(1)
	assert_int(spec.lane_count).is_equal(3)
	assert_bool(spec.has_center_line()).is_true()


func test_directional_lanes_fill_missing_from_total() -> void:
	# Only lanes:backward given, plus total lanes → forward is the remainder.
	var spec := RoadLaneSpec.from_tags("primary", {
		"lanes": "3", "lanes:backward": "1",
	})
	assert_int(spec.backward_lanes).is_equal(1)
	assert_int(spec.forward_lanes).is_equal(2)


func test_roundabout_is_one_way() -> void:
	var spec := RoadLaneSpec.from_tags("tertiary", {"junction": "roundabout"})
	assert_bool(spec.one_way).is_true()
	assert_bool(spec.has_center_line()).is_false()


func test_unmarked_types_carry_no_markings() -> void:
	for t: String in ["footway", "path", "cycleway", "track", "pedestrian"]:
		var spec := RoadLaneSpec.from_tags(t, {})
		assert_bool(spec.marked) \
			.override_failure_message("%s should be unmarked" % t).is_false()


func test_service_road_is_undivided() -> void:
	# A narrow service road/alley keeps no centre line even two-way.
	var spec := RoadLaneSpec.from_tags("service", {})
	assert_bool(spec.marked).is_true()
	assert_bool(spec.has_center_line()).is_false()


func test_reversed_oneway_still_one_way() -> void:
	var spec := RoadLaneSpec.from_tags("primary", {"lanes": "2", "oneway": "-1"})
	assert_bool(spec.one_way).is_true()
	assert_int(spec.forward_lanes).is_equal(2)
