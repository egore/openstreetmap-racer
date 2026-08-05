extends GdUnitTestSuite

## Tests for RoadProfile — the shared cross-section rules (width, kerbs, layers).
##
## These matter more than they look: RoadJunctionSolver and OSMWayBuilder BOTH
## call width_for(), and if they ever disagreed the intersection caps would not
## meet the ribbon mouths and every junction in the world would show a crack.
## The sidewalk tests additionally pin a real bug fix — the old builder treated
## OSM `separate` as "draw a kerb" when it means precisely the opposite.

const OSMParser := preload("res://scripts/osm_parser.gd")
const RoadProfile := preload("res://scripts/road_profile.gd")


func _way(tags: Dictionary) -> OSMParser.OSMWay:
	var w := OSMParser.OSMWay.new()
	w.id = 1
	w.node_ids = [1, 2] as Array[int]
	w.tags = tags
	return w


# ─── Width ───────────────────────────────────────────────────────────────────

func test_explicit_width_tag_wins() -> void:
	var w := _way({"highway": "residential", "width": "9.5"})
	assert_float(RoadProfile.width_for(w)).is_equal_approx(9.5, 0.001)


func test_explicit_width_beats_lane_count() -> void:
	# A measured width is ground truth even when the lane count suggests otherwise.
	var w := _way({"highway": "primary", "lanes": "6", "width": "7"})
	assert_float(RoadProfile.width_for(w)).is_equal_approx(7.0, 0.001)


func test_width_scales_with_lane_count() -> void:
	var two := _way({"highway": "tertiary", "lanes": "2"})
	var four := _way({"highway": "tertiary", "lanes": "4"})
	assert_float(RoadProfile.width_for(four)) \
		.override_failure_message("4 lanes must be wider than 2") \
		.is_greater(RoadProfile.width_for(two))


func test_oneway_single_lane_is_narrower_than_two_way() -> void:
	# The key real-world case: a oneway tertiary with no lanes tag is ONE lane
	# and must not render as wide as the two-lane road it branches from.
	var two_way := _way({"highway": "tertiary"})
	var one_way := _way({"highway": "tertiary", "oneway": "yes"})
	assert_float(RoadProfile.width_for(one_way)) \
		.override_failure_message("a one-way single lane must be narrower") \
		.is_less(RoadProfile.width_for(two_way))


func test_lane_width_never_goes_below_a_real_lane() -> void:
	# Even a narrow class scaled down must keep lanes drivable.
	var w := _way({"highway": "service", "lanes": "2"})
	var per_lane: float = RoadProfile.width_for(w) / 2.0
	assert_float(per_lane).is_greater_equal(RoadLaneSpec.LANE_WIDTH - 0.001)


func test_soft_ways_keep_their_literal_default() -> void:
	# A footway is not a carriageway; the (defaulted) lane count must not widen it.
	var foot := _way({"highway": "footway"})
	assert_float(RoadProfile.width_for(foot)) \
		.is_equal_approx(RoadProfile.ROAD_WIDTHS["footway"], 0.001)


func test_unknown_highway_type_gets_default_width() -> void:
	var w := _way({"highway": "some_future_tag"})
	assert_float(RoadProfile.width_for(w)).is_greater(0.0)


func test_zero_or_garbage_width_tag_falls_back() -> void:
	var zero := _way({"highway": "residential", "width": "0"})
	assert_float(RoadProfile.width_for(zero)).is_greater(0.0)
	var junk := _way({"highway": "residential", "width": "wide"})
	assert_float(RoadProfile.width_for(junk)).is_greater(0.0)


# ─── Road classification ─────────────────────────────────────────────────────

func test_platform_is_not_a_road() -> void:
	assert_bool(RoadProfile.is_road(_way({"highway": "platform"}))).is_false()


func test_footway_is_a_road_but_not_drivable() -> void:
	var foot := _way({"highway": "footway"})
	assert_bool(RoadProfile.is_road(foot)).is_true()
	assert_bool(RoadProfile.is_drivable(foot)) \
		.override_failure_message("a footway must not form road junctions") \
		.is_false()


func test_residential_is_drivable() -> void:
	assert_bool(RoadProfile.is_drivable(_way({"highway": "residential"}))).is_true()


func test_soft_types_are_not_paved() -> void:
	assert_bool(RoadProfile.is_paved("footway")).is_false()
	assert_bool(RoadProfile.is_paved("residential")).is_true()


# ─── Sidewalks (the inverted-`separate` bug) ─────────────────────────────────

func test_sidewalk_both_draws_both_kerbs() -> void:
	var s := RoadProfile.sidewalk_sides({"sidewalk": "both"})
	assert_bool(s["left"]).is_true()
	assert_bool(s["right"]).is_true()


func test_sidewalk_left_draws_only_left() -> void:
	var s := RoadProfile.sidewalk_sides({"sidewalk": "left"})
	assert_bool(s["left"]).is_true()
	assert_bool(s["right"]).is_false()


func test_sidewalk_no_draws_nothing() -> void:
	var s := RoadProfile.sidewalk_sides({"sidewalk": "no"})
	assert_bool(s["left"]).is_false()
	assert_bool(s["right"]).is_false()


func test_sidewalk_separate_draws_no_inline_kerb() -> void:
	# REGRESSION: `separate` means the footway is mapped as its own way, so an
	# inline kerb here would duplicate that geometry. The old code drew a kerb
	# ONLY in this case, which was exactly backwards.
	var s := RoadProfile.sidewalk_sides({"sidewalk": "separate"})
	assert_bool(s["left"]) \
		.override_failure_message("sidewalk=separate must NOT draw an inline kerb") \
		.is_false()
	assert_bool(s["right"]) \
		.override_failure_message("sidewalk=separate must NOT draw an inline kerb") \
		.is_false()


func test_per_side_tags_override_the_general_tag() -> void:
	var s := RoadProfile.sidewalk_sides({"sidewalk": "both", "sidewalk:left": "no"})
	assert_bool(s["left"]).is_false()
	assert_bool(s["right"]).is_true()


func test_sidewalk_both_key_sets_both_sides() -> void:
	var yes := RoadProfile.sidewalk_sides({"sidewalk:both": "yes"})
	assert_bool(yes["left"]).is_true()
	assert_bool(yes["right"]).is_true()
	var sep := RoadProfile.sidewalk_sides({"sidewalk:both": "separate"})
	assert_bool(sep["left"]).is_false()


func test_untagged_road_has_no_kerbs() -> void:
	# Strictly OSM-driven: absent tags mean no sidewalk, not an assumed one.
	var s := RoadProfile.sidewalk_sides({})
	assert_bool(s["left"]).is_false()
	assert_bool(s["right"]).is_false()


# ─── Layers / bridges / tunnels ──────────────────────────────────────────────

func test_ground_level_road_has_no_offset() -> void:
	assert_float(RoadProfile.layer_offset(_way({"highway": "residential"}))) \
		.is_equal_approx(0.0, 0.001)


func test_bridge_rides_above_ground() -> void:
	var w := _way({"highway": "primary", "layer": "1"})
	assert_float(RoadProfile.layer_offset(w)) \
		.override_failure_message("layer=1 must lift the road above ground") \
		.is_greater(0.0)


func test_tunnel_drops_below_ground() -> void:
	var w := _way({"highway": "primary", "layer": "-1"})
	assert_float(RoadProfile.layer_offset(w)).is_less(0.0)


func test_bridge_tag_implies_a_level_without_explicit_layer() -> void:
	# OSM commonly tags bridge=yes with no layer=*; it still means "above".
	var w := _way({"highway": "primary", "bridge": "yes"})
	assert_int(RoadProfile.layer_of(w)).is_equal(1)
	assert_bool(RoadProfile.is_bridge(w)).is_true()


func test_tunnel_tag_implies_a_negative_level() -> void:
	var w := _way({"highway": "primary", "tunnel": "yes"})
	assert_int(RoadProfile.layer_of(w)).is_equal(-1)
	assert_bool(RoadProfile.is_tunnel(w)).is_true()


func test_explicit_layer_beats_inferred_bridge_level() -> void:
	var w := _way({"highway": "primary", "bridge": "yes", "layer": "2"})
	assert_int(RoadProfile.layer_of(w)).is_equal(2)


func test_bridge_no_is_not_a_bridge() -> void:
	assert_bool(RoadProfile.is_bridge(_way({"highway": "primary", "bridge": "no"}))) \
		.is_false()


func test_layer_is_clamped_to_sane_range() -> void:
	# Vandalised/absurd layer values must not fling a road into orbit.
	var w := _way({"highway": "primary", "layer": "99"})
	assert_int(RoadProfile.layer_of(w)).is_less_equal(5)


func test_garbage_layer_value_is_ignored() -> void:
	var w := _way({"highway": "primary", "layer": "up"})
	assert_int(RoadProfile.layer_of(w)).is_equal(0)


func test_layers_are_separated_enough_to_clear_a_car() -> void:
	var ground := _way({"highway": "primary"})
	var bridge := _way({"highway": "primary", "layer": "1"})
	var gap := RoadProfile.layer_offset(bridge) - RoadProfile.layer_offset(ground)
	assert_float(gap) \
		.override_failure_message("a bridge must clear a car's height") \
		.is_greater(2.0)
