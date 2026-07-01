class_name TrafficRoadNetwork
extends RefCounted

## Drivable road graph extracted once from parsed OSM data, used by the
## TrafficManager to spawn and route AI cars.
##
## This is deliberately a pure-logic helper (no scene tree, no physics): given an
## OSMParser.OSMData it flattens every drivable highway=* way into a list of
## polyline "roads" carrying the world-space centre points, a driving width, and
## a car "capacity" derived from that width. The manager samples these roads to
## place traffic — the wider the street, the more cars it wants — so all the
## "which streets, how many cars" policy lives here where it can be unit-tested
## without spinning up Godot physics.
##
## Elevation: points keep the OSM node's local_pos.y (already lifted onto the DEM
## by the parser), so a car placed on a road segment sits at roughly terrain
## height even before its physics settles.

## A single drivable road: the ordered world-space centreline points plus the
## metadata the traffic manager needs to populate and route it.
class Road:
	## Stable unique identity of this drivable segment within the network. Because
	## a single OSM way is split into one segment per junction-to-junction span
	## (so a street crossing another street mid-way actually connects to it), the
	## OSM way id is no longer unique — this is. The manager keys cars, counts, and
	## O(1) lookups on this. Assigned by build(); -1 for an ad-hoc Road not in a
	## network (e.g. a test building one directly).
	var segment_id: int = -1
	## OSM way id this road came from (handy for debugging / de-duplication). NOT
	## unique across roads any more — several segments share the parent way id.
	var way_id: int = 0
	## Highway class (e.g. "residential", "primary"). Drives width and capacity.
	var highway_type: String = ""
	## Ordered centreline points in world/local meters (Y = terrain elevation).
	var points: PackedVector3Array = PackedVector3Array()
	## Carriageway width in meters (mirrors OSMWayBuilder's road widths so cars
	## sit on the visible asphalt).
	var width: float = 0.0
	## Total length of the polyline in meters, cached for capacity + routing.
	var length: float = 0.0
	## True for one-way streets: cars only travel points[0] -> points[n-1].
	var one_way: bool = false
	## How many AI cars this road wants at full density. Bigger/wider/longer
	## roads want more; tiny footways want none.
	var capacity: int = 0
	## OSM node id of the first / last centreline point. These are the graph
	## junction keys: two roads that share an endpoint node connect there, which
	## is how a car flows from one road onto the next instead of teleporting.
	var start_node: int = 0
	var end_node: int = 0

## Highway classes we let AI cars drive on. Footways, cycleways, steps, etc. are
## excluded — pedestrians/bikes aren't modelled and a block-car on a 1 m path
## looks wrong. Mirrors (a subset of) OSMWayBuilder.ROAD_WIDTHS.
const DRIVABLE_TYPES := {
	"motorway": true,
	"motorway_link": true,
	"trunk": true,
	"trunk_link": true,
	"primary": true,
	"primary_link": true,
	"secondary": true,
	"secondary_link": true,
	"tertiary": true,
	"tertiary_link": true,
	"residential": true,
	"living_street": true,
	"unclassified": true,
	"service": true,
}

## Road width in meters by highway type. Kept in sync with OSMWayBuilder so the
## AI cars ride on the asphalt the way builder actually draws.
const ROAD_WIDTHS := {
	"motorway": 12.0,
	"motorway_link": 6.0,
	"trunk": 10.0,
	"trunk_link": 5.0,
	"primary": 8.0,
	"primary_link": 4.5,
	"secondary": 7.0,
	"secondary_link": 4.0,
	"tertiary": 6.0,
	"tertiary_link": 3.5,
	"residential": 5.0,
	"living_street": 4.0,
	"service": 3.0,
	"unclassified": 5.0,
}
const DEFAULT_WIDTH := 4.0

## One AI car per this many meters of a single-lane road, scaled up by how many
## lanes the width implies. Tuned so a ~200 m residential street carries a car or
## two while a wide primary road carries a small stream of them. The manager
## further clamps the live population, so this is a *desire*, not a guarantee.
const METERS_PER_CAR := 90.0
## A road narrower than this (footway/path leftovers that slipped through) never
## gets a car regardless of length.
const MIN_DRIVABLE_WIDTH := 2.5
## Reference single-lane width used to convert a road's width into a lane count
## for the capacity calc.
const LANE_WIDTH := 3.5

var _roads: Array[Road] = []
## segment_id -> Road, for O(1) lookup when a car asks to continue onto a specific
## connected road. Keyed by the unique per-segment id (a single OSM way splits
## into several segments at its junctions, so the way id is not unique).
var _by_way_id: Dictionary = {}
## Junction adjacency: OSM node id -> Array[Road] of every road that starts or
## ends at that node. This is the road graph — two roads sharing a node key are
## physically joined there, so a car reaching that node can roll onto the other
## road with no discontinuity. Built once in build().
var _by_node: Dictionary = {}

## Build the drivable road list from parsed OSM data. Safe to call with null (no
## data yet) — yields an empty network. Idempotent: rebuilds from scratch.
func build(osm_data: OSMParser.OSMData) -> void:
	_roads.clear()
	_by_way_id.clear()
	_by_node.clear()
	if osm_data == null:
		return
	# Junction nodes must be known *before* splitting: a node is a junction if two
	# or more drivable ways pass through it (at any position, not just an
	# endpoint). Without this pre-pass a street that crosses another street in the
	# *middle* of both ways would never connect — the old code only indexed each
	# way's first/last node, so most real intersections were invisible and cars
	# hit a "dead end" at the end of every way and got teleported away. That was
	# the biggest cause of the wiggling/jumping.
	var junctions := _find_junction_nodes(osm_data)
	for way: OSMParser.OSMWay in osm_data.ways.values():
		for road: Road in _roads_from_way(way, osm_data, junctions):
			# Identify a segment by its parent way + endpoint nodes rather than a
			# per-build counter. This is *stable across rebuilds*: when the graph
			# is rebuilt around a moving player (streaming a country), a road that
			# reappears keeps the same id, so a car already driving it stays valid
			# instead of being orphaned and respawned every rebuild. Interior
			# roads (near the player, where junction detection is stable) get a
			# perfectly stable id; only roads at the rebuilt region's edge, whose
			# split points can shift, may change id — and those are far from the
			# player where an occasional recycle is invisible.
			road.segment_id = _segment_id_for(road.way_id, road.start_node, road.end_node)
			_roads.append(road)
			_by_way_id[road.segment_id] = road
	_build_junction_index()


## Stable, build-independent segment id from the parent way id and endpoint
## nodes. Endpoints are order-normalized so a segment hashes the same regardless
## of traversal direction. Combines the three ids into a wide value and folds it
## to a positive int (never the -1 "no road" sentinel); collision probability
## across a realistic near-player region is negligible.
static func _segment_id_for(way_id: int, start_node: int, end_node: int) -> int:
	var lo: int = min(start_node, end_node)
	var hi: int = max(start_node, end_node)
	# 64-bit mix (constants are odd, from splitmix64-style folding) so distinct
	# (way, endpoints) triples spread out rather than clustering by small ids.
	var h: int = way_id * 1099511628211
	h = (h ^ lo) * 1099511628211
	h = (h ^ hi) * 1099511628211
	return (h & 0x7fffffffffffffff) | 1


## Count how many drivable ways touch each node; any node touched by 2+ ways is a
## junction where roads must connect, and every way's own two endpoints are also
## split points. Returns the set of node ids that are junctions (as a Dictionary
## used as a set for O(1) membership).
func _find_junction_nodes(osm_data: OSMParser.OSMData) -> Dictionary:
	var use_count: Dictionary = {}
	for way: OSMParser.OSMWay in osm_data.ways.values():
		if not _is_drivable_way(way):
			continue
		# A node appearing twice in the same way (e.g. a closed loop) still only
		# counts once for that way; de-dup per way so a self-touch isn't mistaken
		# for a two-way junction.
		var seen: Dictionary = {}
		for nid: int in way.node_ids:
			if not osm_data.nodes.has(nid) or seen.has(nid):
				continue
			seen[nid] = true
			use_count[nid] = int(use_count.get(nid, 0)) + 1
	var junctions: Dictionary = {}
	for nid: int in use_count:
		if int(use_count[nid]) >= 2:
			junctions[nid] = true
	return junctions


## Index every road by its two endpoint nodes so roads sharing a junction can be
## found in O(1). A road contributes itself to both its start and end node.
func _build_junction_index() -> void:
	for road: Road in _roads:
		_add_to_node(road.start_node, road)
		if road.end_node != road.start_node:
			_add_to_node(road.end_node, road)


func _add_to_node(node_id: int, road: Road) -> void:
	if not _by_node.has(node_id):
		_by_node[node_id] = ([] as Array[Road])
	(_by_node[node_id] as Array[Road]).append(road)


## Every drivable road in the network.
func get_roads() -> Array[Road]:
	return _roads


## Number of drivable roads found.
func road_count() -> int:
	return _roads.size()


## Sum of every road's desired car capacity — the total number of AI cars the
## whole map "wants" at full density. The manager uses this only for reference;
## it caps the live count far below this on any real city map.
func total_capacity() -> int:
	var total := 0
	for road: Road in _roads:
		total += road.capacity
	return total


## Whether a highway value is one AI cars may drive on.
static func is_drivable(highway_type: String) -> bool:
	return DRIVABLE_TYPES.has(highway_type)


## The road for a given segment id, or null if it isn't in the network. The
## parameter is the unique per-segment id (Road.segment_id), which is what the
## car carries as its current_way_id(); it is *not* the OSM way id.
func find_road(segment_id: int) -> Road:
	return _by_way_id.get(segment_id, null)


## Every road that touches the given junction node (including the caller's own
## road). Empty array for an unknown node.
func roads_at_node(node_id: int) -> Array[Road]:
	return _by_node.get(node_id, ([] as Array[Road]))


## Choose a road to continue onto after `road` when a car reaches the junction at
## its far end (exiting_at_end=true → the end_node, else the start_node). Returns
## a Continuation describing the next road and whether the car should traverse it
## forward or reversed, or null when the junction is a dead end (no other
## drivable road connects there).
##
## This is what makes cars flow from segment to segment: at a shared node we pick
## another road attached to that same node and orient it so the car enters from
## the junction (its near endpoint becomes distance 0). Straightest-through is
## preferred so a car tends to carry on rather than always turning.
func next_road(road: Road, exiting_at_end: bool, rng: RandomNumberGenerator) -> Continuation:
	if road == null:
		return null
	var junction: int = road.end_node if exiting_at_end else road.start_node
	var candidates := roads_at_node(junction)
	# Gather the viable continuations: any *other* road touching this junction,
	# oriented so the car enters at the junction. A one-way road can only be
	# entered from its start_node (you can't drive it backwards).
	var options: Array[Continuation] = []
	for other: Road in candidates:
		if other == road:
			continue
		# Entering forward means the junction is `other`'s start node.
		if other.start_node == junction:
			options.append(Continuation.new(other, false))
		# Entering reversed means the junction is `other`'s end node; only legal
		# on two-way roads (driving a one-way street against its direction is not).
		if other.end_node == junction and not other.one_way:
			options.append(Continuation.new(other, true))
	if options.is_empty():
		return null

	var incoming := _exit_direction(road, exiting_at_end)

	# Score every option by how well it keeps going in the incoming direction
	# (1 = dead straight, -1 = full U-turn) and sort straightest-first.
	options.sort_custom(func(a: Continuation, b: Continuation) -> bool:
		return _straightness(incoming, a) > _straightness(incoming, b))

	if options.size() == 1:
		return options[0]

	# Drop continuations that would double the car back on itself (a near-180°
	# turn): those are almost always the geometry of the *same* street sampled
	# from the wrong end, or a hairpin no driver would take through-traffic. We
	# only keep them if every option is that sharp (a genuine dead-end U-turn).
	var forward: Array[Continuation] = []
	for opt: Continuation in options:
		if _straightness(incoming, opt) > _U_TURN_COS:
			forward.append(opt)
	var pool := forward if forward.size() > 0 else options

	if pool.size() == 1:
		return pool[0]

	# Bias strongly toward the straightest so cars mostly carry on down the road
	# they're on, but let a minority turn at real intersections. A weighted pick
	# on the straightness score does this without hard-coding "go straight".
	return _weighted_pick(pool, incoming, rng)


## Plan a rolling route of up to `steps` continuations starting from `road`
## (traversed in the given direction), so a car commits to a short *intention*
## down the road instead of re-deciding at every corner. Returns the ordered list
## of continuations to take; may be shorter than `steps` if the car reaches a dead
## end. Empty when there is nowhere to go.
##
## This is the "long-term intention" the design asks for: rather than each car
## independently rolling the dice at each junction (which reads as aimless
## wiggling), the manager asks for a few segments ahead and drives them in order.
## Each hop uses the same straightness-weighted next_road, and we avoid
## immediately bouncing back onto the segment we just left (A→B→A) so a planned
## route makes forward progress. The manager re-plans when the route runs out or
## the car is recycled, so this stays cheap and self-correcting.
func plan_route(road: Road, reversed: bool, steps: int, rng: RandomNumberGenerator) -> Array[Continuation]:
	var route: Array[Continuation] = []
	if road == null or steps <= 0:
		return route
	var current := road
	var current_reversed := reversed
	var prev_segment_id := -1
	for _i: int in range(steps):
		# The car exits at the far end of its travel direction: forward traversal
		# exits at end_node, reversed exits at start_node.
		var exiting_at_end := not current_reversed
		var cont := next_road(current, exiting_at_end, rng)
		if cont == null:
			break
		# Avoid an immediate U-turn back onto the segment we just came from; if
		# that's the only option, re-picking won't help so we stop planning here
		# and let the manager handle the dead-end recycle.
		if cont.road.segment_id == prev_segment_id:
			var retry := next_road(current, exiting_at_end, rng)
			if retry == null or retry.road.segment_id == prev_segment_id:
				break
			cont = retry
		route.append(cont)
		prev_segment_id = current.segment_id
		current = cont.road
		current_reversed = cont.reversed
	return route


## Cosine threshold below which a continuation is treated as an illegal U-turn
## (~107°). Anything sharper is rejected unless it's the only way out.
const _U_TURN_COS := -0.3


## Pick a continuation with probability weighted by its straightness, so the
## through-road is most likely but turns still happen. Straightness (-1..1) is
## remapped to a positive weight, squared to favour the straightest.
static func _weighted_pick(pool: Array[Continuation], incoming: Vector3, rng: RandomNumberGenerator) -> Continuation:
	var weights: Array[float] = []
	var total := 0.0
	for opt: Continuation in pool:
		# Remap -1..1 → 0..1, bias with a power so straighter wins more often.
		var s := (_straightness(incoming, opt) + 1.0) * 0.5
		var w: float = pow(maxf(s, 0.01), 3.0)
		weights.append(w)
		total += w
	var r := rng.randf() * total
	for i: int in range(pool.size()):
		r -= weights[i]
		if r <= 0.0:
			return pool[i]
	return pool[0]


## A chosen next road plus the direction to traverse it. `reversed` means walk
## the road's points from the far end (end_node → start_node), so the car enters
## from the shared junction either way.
class Continuation:
	var road: Road
	var reversed: bool

	func _init(r: Road, rev: bool) -> void:
		road = r
		reversed = rev


## Unit heading (XZ) a car is travelling as it leaves `road` at the given end.
static func _exit_direction(road: Road, exiting_at_end: bool) -> Vector3:
	var pts := road.points
	var n := pts.size()
	if n < 2:
		return Vector3.ZERO
	var d: Vector3
	if exiting_at_end:
		d = pts[n - 1] - pts[n - 2]
	else:
		d = pts[0] - pts[1]
	d.y = 0.0
	return d.normalized() if d.length_squared() > 0.0001 else Vector3.ZERO


## How closely a continuation keeps going in the incoming direction: dot product
## of the incoming heading with the continuation's initial heading (1 = dead
## straight, -1 = U-turn). Used to prefer through-traffic at junctions.
static func _straightness(incoming: Vector3, cont: Continuation) -> float:
	var pts := cont.road.points
	var n := pts.size()
	if n < 2 or incoming == Vector3.ZERO:
		return 0.0
	var d: Vector3
	if cont.reversed:
		d = pts[n - 2] - pts[n - 1]
	else:
		d = pts[1] - pts[0]
	d.y = 0.0
	if d.length_squared() < 0.0001:
		return 0.0
	return incoming.dot(d.normalized())


## Capacity (desired car count) for a road of the given length and width. Pure so
## it can be unit-tested directly. Wider roads imply more lanes → proportionally
## more cars; anything below one car's worth of length rounds to zero.
static func capacity_for(length: float, width: float) -> int:
	if width < MIN_DRIVABLE_WIDTH or length <= 0.0:
		return 0
	var lanes: float = maxf(1.0, width / LANE_WIDTH)
	var cars: float = (length / METERS_PER_CAR) * lanes
	return int(floor(cars))


# --- Internals -------------------------------------------------------------

## Whether an OSM way is a drivable road (tags only — no geometry check). Shared
## by the junction pre-pass and the segment builder so both agree on which ways
## count.
static func _is_drivable_way(way: OSMParser.OSMWay) -> bool:
	if not way.tags.has("highway"):
		return false
	if not is_drivable(String(way.tags["highway"])):
		return false
	# An explicit area=yes highway is a plaza/parking aisle polygon, not a line to
	# drive down; skip it.
	return way.tags.get("area", "no") != "yes"


## Turn one OSM way into one or more drivable Road *segments*, split at every
## interior junction node so a way that crosses another way in the middle
## connects there. Returns an empty array if the way isn't drivable or is
## degenerate.
##
## Why split at junctions rather than keeping the whole way: the road graph
## connects two roads only where one road's endpoint node equals another's.
## Real OSM ways routinely run straight through crossings whose node is in the
## *middle* of the way; unless we cut the way there, that crossing is not a graph
## node and cars can never turn onto the cross street — they run to the way's far
## end and get recycled/teleported. Cutting each way into junction-to-junction
## spans makes every real intersection a first-class graph node.
func _roads_from_way(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData, junctions: Dictionary) -> Array[Road]:
	var out: Array[Road] = []
	if not _is_drivable_way(way):
		return out

	# Keep only node ids that actually resolve to a node, so ids line up 1:1 with
	# the points (way_to_points silently skips missing nodes).
	var present_ids: Array[int] = []
	for nid: int in way.node_ids:
		if osm_data.nodes.has(nid):
			present_ids.append(nid)
	if present_ids.size() < 2:
		return out

	var highway_type: String = String(way.tags["highway"])
	var width := _width_for_way(way, highway_type)
	var one_way := _is_one_way(way.tags)

	# Walk the way, cutting a new segment every time we pass an interior junction
	# node. Each cut node is shared between the segment ending there and the next
	# segment starting there, so consecutive segments of the same way stay
	# connected in the graph too.
	var seg_start := 0
	for i: int in range(1, present_ids.size()):
		var is_last := i == present_ids.size() - 1
		var is_junction: bool = junctions.has(present_ids[i])
		if is_junction or is_last:
			var seg := _make_segment(
				way.id, highway_type, width, one_way,
				present_ids, seg_start, i, osm_data)
			if seg != null:
				out.append(seg)
			seg_start = i
	return out


## Build a single Road segment spanning present_ids[from..to] (inclusive). Returns
## null for a degenerate span (< 2 points or zero length).
func _make_segment(
		way_id: int, highway_type: String, width: float, one_way: bool,
		present_ids: Array[int], from: int, to: int,
		osm_data: OSMParser.OSMData) -> Road:
	if to - from < 1:
		return null
	var span_ids: Array[int] = present_ids.slice(from, to + 1)
	var points := PolygonUtils.way_to_points(span_ids, osm_data.nodes)
	if points.size() < 2:
		return null
	var length := _polyline_length(points)
	if length <= 0.0:
		return null
	var road := Road.new()
	road.way_id = way_id
	road.highway_type = highway_type
	road.points = points
	road.width = width
	road.length = length
	road.one_way = one_way
	road.capacity = capacity_for(length, width)
	road.start_node = span_ids[0]
	road.end_node = span_ids[span_ids.size() - 1]
	return road


## Resolve a way's carriageway width from its highway class, honouring explicit
## lanes / width tags the same way the visible road builder does.
static func _width_for_way(way: OSMParser.OSMWay, highway_type: String) -> float:
	var width: float = ROAD_WIDTHS.get(highway_type, DEFAULT_WIDTH)
	if way.tags.has("lanes"):
		var lanes: int = String(way.tags["lanes"]).to_int()
		if lanes > 0:
			width = lanes * LANE_WIDTH
	if way.tags.has("width"):
		var explicit: float = String(way.tags["width"]).to_float()
		if explicit > 0.0:
			width = explicit
	return width


## Total length of an ordered polyline in the XZ meters it's expressed in.
static func _polyline_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for i: int in range(points.size() - 1):
		total += points[i].distance_to(points[i + 1])
	return total


## True when a way is one-directional. Handles the common oneway spellings AND the
## implicit one-way flow of roundabouts / circular junctions (which are almost
## never tagged oneway=yes because it's implied by junction=roundabout). Getting
## these right is what stops cars driving the wrong way around a roundabout.
static func _is_one_way(tags: Dictionary) -> bool:
	# junction=roundabout|circular is implicitly one-way in the node order.
	var junction: String = String(tags.get("junction", ""))
	if junction == "roundabout" or junction == "circular":
		return true
	var v: String = String(tags.get("oneway", "no"))
	return v == "yes" or v == "true" or v == "1"
