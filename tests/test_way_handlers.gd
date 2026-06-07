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
	ParkingHandler.new(),
	AreaHandler.new(),
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
