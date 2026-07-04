extends GdUnitTestSuite

## Unit tests for the OSM way-handler registry.
##
## The way-rendering dispatch moved from a central if-elif chain in
## OSMTileManager to an ordered list of OSMWayHandler objects (first match
## wins). These tests pin two things future refactors must not break:
##
##   1. Each representative way is claimed by the expected handler.
##   2. Precedence is preserved — the original if-elif ORDER encoded rules like
##      "a closed power ring is an Area, not a power line" and "parking is
##      matched before the generic area handler". Reordering the registry would
##      silently regress these, so we assert against an explicit ordered list
##      that mirrors OSMTileManager._way_handlers.

const OSMParser := preload("res://scripts/osm_parser.gd")

# Mirror of OSMTileManager._way_handlers — keep in sync. The test exists
# precisely to catch accidental reordering, so this list is the contract.
var _handlers: Array[OSMWayHandler] = [
	RoadHandler.new(),
	RailwayHandler.new(),
	PowerLineHandler.new(),
	GantryHandler.new(),
	WaterwayHandler.new(),
	BuildingHandler.new(),
	BarrierHandler.new(),
	PlatformHandler.new(),
	ParkingHandler.new(),
	AreaHandler.new(),
	SurfaceHandler.new(),
]


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Build a way with the given tags. Defaults to a closed 4-node ring so closed-
## way predicates (power/gantry/area) behave; pass `closed=false` for a line.
func _way(tags: Dictionary, closed: bool = true) -> OSMParser.OSMWay:
	var w := OSMParser.OSMWay.new()
	w.id = 1
	w.tags = tags
	if closed:
		w.node_ids = [1, 2, 3, 1] as Array[int]
	else:
		w.node_ids = [1, 2] as Array[int]
	return w


## Return the handler_name() of the first matching handler, or "" if none claim
## the way. Mirrors the manager's first-match-wins dispatch. A null context is
## fine because every matches() implementation is context-free.
func _classify(way: OSMParser.OSMWay) -> String:
	for handler: OSMWayHandler in _handlers:
		if handler.matches(way, null):
			return handler.handler_name()
	return ""


# ─── Tests ───────────────────────────────────────────────────────────────────

func test_basic_classification() -> void:
	assert_str(_classify(_way({"highway": "residential"}, false))) \
		.override_failure_message("highway way -> road").is_equal("road")
	assert_str(_classify(_way({"railway": "tram"}, false))) \
		.override_failure_message("railway=tram -> railway").is_equal("railway")
	assert_str(_classify(_way({"power": "line"}, false))) \
		.override_failure_message("open power=line -> power_line").is_equal("power_line")
	assert_str(_classify(_way({"man_made": "gantry"}, false))) \
		.override_failure_message("open man_made=gantry -> gantry").is_equal("gantry")
	assert_str(_classify(_way({"waterway": "river"}, false))) \
		.override_failure_message("waterway=river -> waterway").is_equal("waterway")
	assert_str(_classify(_way({"building": "yes"}))) \
		.override_failure_message("building=yes -> building").is_equal("building")
	assert_str(_classify(_way({"barrier": "fence"}, false))) \
		.override_failure_message("barrier=fence -> barrier").is_equal("barrier")
	assert_str(_classify(_way({"landuse": "forest"}))) \
		.override_failure_message("landuse=forest -> area").is_equal("area")


func test_closed_power_ring_is_area_not_power_line() -> void:
	# A closed power ring (substation outline) must NOT match power_line; it
	# falls through to area. This is the canonical precedence rule the ordered
	# registry preserves from the old if-elif chain.
	var ring := _way({"power": "generator"})
	assert_str(_classify(ring)) \
		.override_failure_message("closed power ring -> area (not power_line)").is_equal("area")
	# And an OPEN power line still resolves to power_line.
	assert_str(_classify(_way({"power": "line"}, false))) \
		.override_failure_message("open power line still -> power_line").is_equal("power_line")


func test_parking_beats_generic_area() -> void:
	# amenity=parking is also a closed amenity ring that area would otherwise
	# claim; parking must win because it is registered first.
	var parking := _way({"amenity": "parking"})
	assert_str(_classify(parking)) \
		.override_failure_message("amenity=parking -> parking (before area)").is_equal("parking")


func test_underground_waterway_unmatched() -> void:
	# Tunneled waterways are intentionally skipped by the waterway predicate and
	# carry no other renderable tag, so nothing should claim them.
	var culvert := _way({"waterway": "stream", "tunnel": "culvert"}, false)
	assert_str(_classify(culvert)) \
		.override_failure_message("tunneled waterway claimed by no handler").is_equal("")


func test_untagged_way_unmatched() -> void:
	assert_str(_classify(_way({}, false))) \
		.override_failure_message("untagged way claimed by no handler").is_equal("")


# ─── Relation-member way tests ──────────────────────────────────────────────
# Ways that carry only styling tags (colour, roof:shape, etc.) without their
# own feature key are NOT claimed by any handler. They get their semantics
# from a parent relation (e.g. type=building), and the relation builder
# renders them with the merged tag set. The tile manager skips them in the
# per-way loop; this test confirms no handler falsely claims them.

func test_bare_styling_tags_unmatched() -> void:
	# Way 74476348-style tags: colour + roof styling but no building/building:part
	var w := _way({"colour": "#5c5448", "roof:colour": "#abaaa9", "roof:shape": "gabled"})
	assert_str(_classify(w)) \
		.override_failure_message("bare colour + roof styling -> unmatched").is_equal("")


func test_bare_colour_unmatched() -> void:
	var w := _way({"colour": "#5c5448"})
	assert_str(_classify(w)) \
		.override_failure_message("bare colour -> unmatched").is_equal("")


func test_roof_shape_hipped_without_building_unmatched() -> void:
	var w := _way({"colour": "#5c5448", "roof:colour": "#abaaa9", "roof:shape": "hipped"})
	assert_str(_classify(w)) \
		.override_failure_message("bare hipped roof styling -> unmatched").is_equal("")


# ─── Relation-member suppression helpers ─────────────────────────────────────

func test_way_has_own_feature_detects_highway() -> void:
	var w := _way({"highway": "residential", "colour": "#ff0000"}, false)
	assert_bool(OSMTileManager._way_has_own_feature(w)) \
		.override_failure_message("highway way has own feature").is_true()


func test_way_has_own_feature_detects_building() -> void:
	var w := _way({"building": "yes"})
	assert_bool(OSMTileManager._way_has_own_feature(w)) \
		.override_failure_message("building way has own feature").is_true()


func test_way_has_own_feature_false_for_styling_only() -> void:
	var w := _way({"colour": "#5c5448", "roof:colour": "#abaaa9", "roof:shape": "gabled"})
	assert_bool(OSMTileManager._way_has_own_feature(w)) \
		.override_failure_message("styling-only way has no own feature").is_false()


func test_relation_renders_ways_building_type() -> void:
	var rel := OSMParser.OSMRelation.new()
	rel.id = 1
	rel.tags = {"type": "building", "building": "yes"}
	assert_bool(OSMTileManager._relation_renders_ways(rel)) \
		.override_failure_message("type=building relation renders ways").is_true()


func test_relation_renders_ways_multipolygon_building() -> void:
	var rel := OSMParser.OSMRelation.new()
	rel.id = 1
	rel.tags = {"type": "multipolygon", "building": "yes"}
	assert_bool(OSMTileManager._relation_renders_ways(rel)) \
		.override_failure_message("multipolygon building relation renders ways").is_true()


func test_relation_renders_ways_multipolygon_landuse() -> void:
	var rel := OSMParser.OSMRelation.new()
	rel.id = 1
	rel.tags = {"type": "multipolygon", "landuse": "forest"}
	assert_bool(OSMTileManager._relation_renders_ways(rel)) \
		.override_failure_message("multipolygon landuse relation renders ways").is_true()


func test_relation_does_not_render_route() -> void:
	var rel := OSMParser.OSMRelation.new()
	rel.id = 1
	rel.tags = {"type": "route", "route": "bus"}
	assert_bool(OSMTileManager._relation_renders_ways(rel)) \
		.override_failure_message("route relation does not render ways").is_false()


func test_relation_does_not_render_boundary() -> void:
	var rel := OSMParser.OSMRelation.new()
	rel.id = 1
	rel.tags = {"type": "boundary", "boundary": "administrative"}
	assert_bool(OSMTileManager._relation_renders_ways(rel)) \
		.override_failure_message("boundary relation does not render ways").is_false()


# ─── Surface area tests ─────────────────────────────────────────────────────

func test_surface_area_is_surface() -> void:
	# A closed way with area=yes + surface=paving_stones but no feature key.
	var w := _way({"area": "yes", "surface": "paving_stones"})
	assert_str(_classify(w)) \
		.override_failure_message("area=yes + surface=paving_stones -> surface").is_equal("surface")


func test_surface_asphalt_is_surface() -> void:
	var w := _way({"surface": "asphalt"})
	assert_str(_classify(w)) \
		.override_failure_message("surface=asphalt closed ring -> surface").is_equal("surface")


func test_surface_on_open_way_unmatched() -> void:
	# An open way with just surface=* is not a surface area.
	var w := _way({"surface": "concrete"}, false)
	assert_str(_classify(w)) \
		.override_failure_message("surface on open way -> unmatched").is_equal("")


func test_surface_with_highway_is_road() -> void:
	# highway=* ways also carry surface=* but should still match as roads.
	var w := _way({"highway": "residential", "surface": "asphalt"}, false)
	assert_str(_classify(w)) \
		.override_failure_message("highway + surface -> road").is_equal("road")


func test_surface_with_landuse_is_area() -> void:
	# If a surface way also has landuse, the area handler should win.
	var w := _way({"landuse": "grass", "surface": "grass"})
	assert_str(_classify(w)) \
		.override_failure_message("landuse + surface -> area").is_equal("area")


func test_surface_with_amenity_is_area() -> void:
	# If a surface way also has amenity, the area handler (or parking) should win.
	var w := _way({"amenity": "school", "surface": "asphalt"})
	assert_str(_classify(w)) \
		.override_failure_message("amenity + surface -> area").is_equal("area")


# ─── Platform tests ─────────────────────────────────────────────────────────

func test_public_transport_platform_is_platform() -> void:
	# The reported unmatched way: a bare public_transport=platform ring with
	# only bench/shelter attributes. It must now resolve to the platform handler.
	var w := _way({"bench": "no", "public_transport": "platform", "shelter": "no"})
	assert_str(_classify(w)) \
		.override_failure_message("public_transport=platform ring -> platform").is_equal("platform")


func test_railway_platform_is_platform() -> void:
	# railway=platform slips past RailwayHandler (track-value whitelist) and must
	# be claimed by the platform handler as a closed ring.
	var w := _way({"railway": "platform"})
	assert_str(_classify(w)) \
		.override_failure_message("railway=platform ring -> platform").is_equal("platform")


func test_highway_platform_is_platform() -> void:
	# highway=platform is a closed ring; RoadHandler builds linear ribbons so it
	# should not claim a platform area — the platform handler does.
	var w := _way({"highway": "platform"})
	assert_str(_classify(w)) \
		.override_failure_message("highway=platform ring -> platform").is_equal("platform")


func test_open_platform_unmatched() -> void:
	# A linear (open) platform way has no fillable surface; no handler claims it.
	var w := _way({"public_transport": "platform"}, false)
	assert_str(_classify(w)) \
		.override_failure_message("open platform way -> unmatched").is_equal("")


# ─── man_made=reinforced_slope + historic area tests ────────────────────────

func test_reinforced_slope_ring_is_area() -> void:
	# A closed man_made=reinforced_slope ground ring (3dShapes source) renders as
	# a colored area rather than logging an unmatched skip.
	var w := _way({
		"man_made": "reinforced_slope",
		"operator": "Waterschap Hollandse Delta",
		"source": "3dShapes",
	})
	assert_str(_classify(w)) \
		.override_failure_message("reinforced_slope ring -> area").is_equal("area")


func test_open_reinforced_slope_unmatched() -> void:
	# An open (linear) reinforced_slope carries no fillable surface; no handler
	# claims it (the manager suppresses its skip noise).
	var w := _way({"man_made": "reinforced_slope"}, false)
	assert_str(_classify(w)) \
		.override_failure_message("open reinforced_slope -> unmatched").is_equal("")


func test_historic_fort_is_area() -> void:
	# A closed historic=fort ring (earthwork rampart footprint) renders as area.
	var w := _way({
		"historic": "fort",
		"name": "De Schans",
		"ruins": "yes",
		"wheelchair": "no",
	})
	assert_str(_classify(w)) \
		.override_failure_message("historic=fort ring -> area").is_equal("area")


func test_historic_fort_color_is_earthwork() -> void:
	# The fort renders with its dedicated grassy-rampart color, not the default.
	var color := PolygonUtils.get_area_color({"historic": "fort"})
	assert_bool(color == PolygonUtils.DEFAULT_AREA_COLOR) \
		.override_failure_message("historic=fort has a dedicated color").is_false()


func test_reinforced_slope_color_is_riprap() -> void:
	var color := PolygonUtils.get_area_color({"man_made": "reinforced_slope"})
	assert_bool(color == PolygonUtils.DEFAULT_AREA_COLOR) \
		.override_failure_message("reinforced_slope has a dedicated color").is_false()


# ─── Tourism / playground / man_made area tests ─────────────────────────────
# The reported unmatched ways: closed tourism grounds (camp_site, caravan_site,
# chalet), a playground=climbingframe footprint, and man_made=pier/bunker_silo
# rings. All are closed land-cover rings the area handler now claims.

func test_camp_site_ring_is_area() -> void:
	var w := _way({
		"name": "Toppershoedje", "tourism": "camp_site",
		"brand": "RCN vakantieparken",
	})
	assert_str(_classify(w)) \
		.override_failure_message("tourism=camp_site ring -> area").is_equal("area")


func test_caravan_site_ring_is_area() -> void:
	var w := _way({"tourism": "caravan_site", "name": "Drive-in Camperpark"})
	assert_str(_classify(w)) \
		.override_failure_message("tourism=caravan_site ring -> area").is_equal("area")


func test_chalet_ring_is_area() -> void:
	var w := _way({"name": "Jonkerstee", "tourism": "chalet"})
	assert_str(_classify(w)) \
		.override_failure_message("tourism=chalet ring -> area").is_equal("area")


func test_playground_climbingframe_ring_is_area() -> void:
	var w := _way({"playground": "climbingframe"})
	assert_str(_classify(w)) \
		.override_failure_message("playground=climbingframe ring -> area").is_equal("area")


func test_bunker_silo_ring_is_area() -> void:
	var w := _way({"man_made": "bunker_silo"})
	assert_str(_classify(w)) \
		.override_failure_message("man_made=bunker_silo ring -> area").is_equal("area")


func test_closed_pier_ring_is_area() -> void:
	var w := _way({"area": "yes", "man_made": "pier"})
	assert_str(_classify(w)) \
		.override_failure_message("closed man_made=pier ring -> area").is_equal("area")


func test_open_pier_unmatched() -> void:
	# A linear pier carries no fillable surface; no handler claims it (the
	# manager suppresses its skip noise).
	var w := _way({"man_made": "pier"}, false)
	assert_str(_classify(w)) \
		.override_failure_message("open man_made=pier -> unmatched").is_equal("")


func test_open_tourism_way_unmatched() -> void:
	# An open (linear) tourism way has no fillable surface.
	var w := _way({"tourism": "camp_site"}, false)
	assert_str(_classify(w)) \
		.override_failure_message("open tourism way -> unmatched").is_equal("")


func test_camp_site_color_is_grassy() -> void:
	var color := PolygonUtils.get_area_color({"tourism": "camp_site"})
	assert_bool(color == PolygonUtils.DEFAULT_AREA_COLOR) \
		.override_failure_message("tourism=camp_site has a dedicated color").is_false()


func test_pier_color_is_deck() -> void:
	var color := PolygonUtils.get_area_color({"man_made": "pier"})
	assert_bool(color == PolygonUtils.DEFAULT_AREA_COLOR) \
		.override_failure_message("man_made=pier has a dedicated color").is_false()


# ─── Ignorable-way suppression tests ────────────────────────────────────────
# _is_ignorable_way suppresses expected "Skipping way" log noise for features
# that have no fillable surface. It is context-free, so we can call it on a
# throwaway manager instance.

func test_open_playground_equipment_is_ignorable() -> void:
	# playground=climbingframe authored as an open / degenerate outline (not a
	# closed ring) has no fillable surface, so it must be treated as ignorable
	# rather than logged as an unmatched skip.
	var mgr := auto_free(OSMTileManager.new()) as OSMTileManager
	var w := _way({"playground": "climbingframe"}, false)
	assert_bool(mgr._is_ignorable_way(w)) \
		.override_failure_message("open playground equipment -> ignorable").is_true()


func test_closed_playground_equipment_not_ignorable() -> void:
	# A closed climbingframe ring IS renderable ground (AreaHandler claims it),
	# so it must NOT be suppressed as ignorable.
	var mgr := auto_free(OSMTileManager.new()) as OSMTileManager
	var w := _way({"playground": "climbingframe"})
	assert_bool(mgr._is_ignorable_way(w)) \
		.override_failure_message("closed playground ring -> not ignorable").is_false()


func test_dyke_is_ignorable() -> void:
	var mgr := auto_free(OSMTileManager.new()) as OSMTileManager
	var w := _way({"man_made": "dyke"}, false)
	assert_bool(mgr._is_ignorable_way(w)) \
		.override_failure_message("man_made=dyke -> ignorable").is_true()


func test_open_pier_is_ignorable() -> void:
	var mgr := auto_free(OSMTileManager.new()) as OSMTileManager
	var w := _way({"man_made": "pier"}, false)
	assert_bool(mgr._is_ignorable_way(w)) \
		.override_failure_message("open man_made=pier -> ignorable").is_true()
