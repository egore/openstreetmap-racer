extends GdUnitTestSuite

## Unit tests for RoadRegion — the coarse lat/lon → driving-side + give-way-style
## lookup that keeps road markings correct for the part of the world the loaded
## OSM extract actually covers.
##
## These pin:
##   • the Benelux box selecting shark's teeth (NL/BE haaientanden)
##   • the British Isles box selecting left-hand traffic
##   • the worldwide default (right-hand, dashed) everywhere else
##   • lateral_sign(), the single place handedness is turned into a number

const RoadRegion := preload("res://scripts/road_region.gd")
const OSMParser := preload("res://scripts/osm_parser.gd")


# ─── Coordinate lookup ───────────────────────────────────────────────────────

func test_netherlands_uses_shark_teeth_and_drives_right() -> void:
	# Amsterdam.
	var r := RoadRegion.for_coordinates(52.37, 4.90)
	assert_int(r.give_way_style) \
		.override_failure_message("NL must paint haaientanden, not a dashed line") \
		.is_equal(RoadRegion.GiveWayStyle.SHARK_TEETH)
	assert_bool(r.drives_on_left()).is_false()


func test_belgium_uses_shark_teeth() -> void:
	# Brussels — same marking convention as the Netherlands.
	var r := RoadRegion.for_coordinates(50.85, 4.35)
	assert_int(r.give_way_style).is_equal(RoadRegion.GiveWayStyle.SHARK_TEETH)


func test_britain_drives_on_the_left_with_dashed_give_way() -> void:
	# London.
	var r := RoadRegion.for_coordinates(51.51, -0.13)
	assert_bool(r.drives_on_left()).is_true()
	assert_int(r.give_way_style).is_equal(RoadRegion.GiveWayStyle.DASHED)


func test_ireland_drives_on_the_left() -> void:
	# Dublin.
	assert_bool(RoadRegion.for_coordinates(53.35, -6.26).drives_on_left()).is_true()


func test_germany_falls_back_to_the_worldwide_default() -> void:
	# Berlin: right-hand traffic, dashed give-way. Also guards the Benelux box
	# from creeping east over Germany.
	var r := RoadRegion.for_coordinates(52.52, 13.40)
	assert_bool(r.drives_on_left()).is_false()
	assert_int(r.give_way_style).is_equal(RoadRegion.GiveWayStyle.DASHED)


func test_united_states_uses_the_default() -> void:
	# San Francisco — far outside every box.
	var r := RoadRegion.for_coordinates(37.77, -122.42)
	assert_bool(r.drives_on_left()).is_false()
	assert_int(r.give_way_style).is_equal(RoadRegion.GiveWayStyle.DASHED)


func test_boxes_do_not_overlap_across_the_north_sea() -> void:
	# The two boxes are adjacent in longitude; a point clearly inside one must
	# not report the other's conventions. Rotterdam vs. Norwich.
	assert_int(RoadRegion.for_coordinates(51.92, 4.48).give_way_style) \
		.override_failure_message("Rotterdam is NL: shark teeth") \
		.is_equal(RoadRegion.GiveWayStyle.SHARK_TEETH)
	assert_bool(RoadRegion.for_coordinates(52.63, 1.30).drives_on_left()) \
		.override_failure_message("Norwich is GB: left-hand traffic") \
		.is_true()


# ─── Handedness ──────────────────────────────────────────────────────────────

func test_lateral_sign_is_positive_for_right_hand_traffic() -> void:
	assert_float(RoadRegion.new().lateral_sign()).is_equal_approx(1.0, 0.0001)


func test_lateral_sign_flips_for_left_hand_traffic() -> void:
	var left := RoadRegion.for_style(
		RoadRegion.DrivingSide.LEFT, RoadRegion.GiveWayStyle.DASHED)
	assert_float(left.lateral_sign()).is_equal_approx(-1.0, 0.0001)


# ─── OSMData binding ─────────────────────────────────────────────────────────

func test_region_from_osm_data_bounds() -> void:
	var data := OSMParser.OSMData.new()
	data.center_lat = 52.09   # Utrecht
	data.center_lon = 5.12
	assert_int(RoadRegion.for_osm_data(data).give_way_style) \
		.is_equal(RoadRegion.GiveWayStyle.SHARK_TEETH)


func test_null_or_unlocated_data_gets_the_default() -> void:
	# Synthetic fixtures carry no bounds and report 0,0. They must render the way
	# they always did rather than pick up a region by accident.
	assert_int(RoadRegion.for_osm_data(null).give_way_style) \
		.is_equal(RoadRegion.GiveWayStyle.DASHED)
	var blank := OSMParser.OSMData.new()
	assert_bool(RoadRegion.for_osm_data(blank).drives_on_left()).is_false()
