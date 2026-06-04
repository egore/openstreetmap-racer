extends SceneTree

## Headless unit tests for the OSM way-handler registry.
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
##
## Run with:
##   godot --headless --path . --script res://tests/test_way_handlers.gd

const OSMParser := preload("res://scripts/osm_parser.gd")

var _failures: int = 0
var _checks: int = 0

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


func _init() -> void:
	_run_all()
	if _failures == 0:
		print("PASS: all %d checks passed" % _checks)
		quit(0)
	else:
		print("FAIL: %d of %d checks failed" % [_failures, _checks])
		quit(1)


func _run_all() -> void:
	_test_basic_classification()
	_test_closed_power_ring_is_area_not_power_line()
	_test_parking_beats_generic_area()
	_test_underground_waterway_unmatched()
	_test_untagged_way_unmatched()


# ─── Assertion helpers ───────────────────────────────────────────────────────

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("CHECK FAILED: %s" % message)
		print("  FAIL: %s" % message)


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

func _test_basic_classification() -> void:
	_check(_classify(_way({"highway": "residential"}, false)) == "road",
		"highway way -> road")
	_check(_classify(_way({"railway": "tram"}, false)) == "railway",
		"railway=tram -> railway")
	_check(_classify(_way({"power": "line"}, false)) == "power_line",
		"open power=line -> power_line")
	_check(_classify(_way({"man_made": "gantry"}, false)) == "gantry",
		"open man_made=gantry -> gantry")
	_check(_classify(_way({"waterway": "river"}, false)) == "waterway",
		"waterway=river -> waterway")
	_check(_classify(_way({"building": "yes"})) == "building",
		"building=yes -> building")
	_check(_classify(_way({"barrier": "fence"}, false)) == "barrier",
		"barrier=fence -> barrier")
	_check(_classify(_way({"landuse": "forest"})) == "area",
		"landuse=forest -> area")


func _test_closed_power_ring_is_area_not_power_line() -> void:
	# A closed power ring (substation outline) must NOT match power_line; it
	# falls through to area. This is the canonical precedence rule the ordered
	# registry preserves from the old if-elif chain.
	var ring := _way({"power": "generator"})
	_check(_classify(ring) == "area",
		"closed power ring -> area (not power_line)")
	# And an OPEN power line still resolves to power_line.
	_check(_classify(_way({"power": "line"}, false)) == "power_line",
		"open power line still -> power_line")


func _test_parking_beats_generic_area() -> void:
	# amenity=parking is also a closed amenity ring that area would otherwise
	# claim; parking must win because it is registered first.
	var parking := _way({"amenity": "parking"})
	_check(_classify(parking) == "parking",
		"amenity=parking -> parking (before area)")


func _test_underground_waterway_unmatched() -> void:
	# Tunneled waterways are intentionally skipped by the waterway predicate and
	# carry no other renderable tag, so nothing should claim them.
	var culvert := _way({"waterway": "stream", "tunnel": "culvert"}, false)
	_check(_classify(culvert) == "",
		"tunneled waterway claimed by no handler")


func _test_untagged_way_unmatched() -> void:
	_check(_classify(_way({}, false)) == "",
		"untagged way claimed by no handler")
