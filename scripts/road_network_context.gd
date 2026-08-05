class_name RoadNetworkContext
extends RefCounted

const RoadProfileScript := preload("res://scripts/road_profile.gd")
const RoadNetworkContextScript := preload("res://scripts/road_network_context.gd")
const RoadJunctionSolverScript := preload("res://scripts/road_junction_solver.gd")

## The solved intersection layout for one tile, plus the neighbour "halo" it
## needs to get tile borders right.
##
## ── The tile-boundary problem ────────────────────────────────────────────────
## Roads are built tile by tile. A junction node sitting near a tile edge has
## arms belonging to ways that other tiles render. If tile T solved that junction
## using only its own ways, it would see fewer arms than tile T' does, compute a
## different trim distance, and the two tiles would cut the same street at two
## different points — a visible step in the road exactly on the tile seam.
##
## The fix is a HALO: when solving tile T we also feed in the ways of the eight
## surrounding tiles. Every junction within (or just outside) T is then solved
## against its complete set of arms, so T and T' independently compute the SAME
## answer and their geometry lines up. RoadJunctionSolver is deterministic
## precisely so this works (see its determinism test).
##
## We only need the halo for SOLVING. Each tile still renders only its own ways;
## the halo just tells it where to cut them.
##
## ── Cost ─────────────────────────────────────────────────────────────────────
## The neighbour tiles are fetched through the tile source's mutex-guarded LRU
## cache, which the streamer has usually populated already (the camera reaches a
## tile's neighbours before the tile itself). A cold neighbour costs one parse,
## which is why this is built during the tile's off-main-thread parse phase
## rather than while instancing.

## node_id -> RoadJunctionSolverScript.Junction for every junction relevant to this
## tile (its own, plus those in the halo that its ways reach).
var junctions: Dictionary = {}

## Junction node ids that this tile is RESPONSIBLE for drawing the cap of.
##
## A junction near a border is solved by several tiles (they all need its trim
## distances), but exactly one must actually emit the intersection surface or we
## would get z-fighting duplicates. Ownership is by position: the tile whose
## bounds contain the junction node draws it.
var owned_caps: Dictionary = {}


## True when a node is a solved junction in this context.
func has_junction(node_id: int) -> bool:
	return junctions.has(node_id)


## The solved junction at a node, or null.
func junction_at(node_id: int) -> RoadJunctionSolverScript.Junction:
	return junctions.get(node_id, null)


## How far a way's ribbon must be pulled back at one of its ends.
##
## `at_way_start` selects which end: true for the way's first node (the ribbon
## starts there and must begin further along), false for its last node.
## Returns 0.0 when that end is not a junction, so the ribbon runs to its node.
func trim_at(way_id: int, node_id: int, at_way_start: bool) -> float:
	var junction: RoadJunctionSolverScript.Junction = junctions.get(node_id, null)
	if junction == null:
		return 0.0
	return junction.trim_for(way_id, at_way_start)


## The junctions whose caps this tile must draw.
func owned_junctions() -> Array[RoadJunctionSolverScript.Junction]:
	var out: Array[RoadJunctionSolverScript.Junction] = []
	for nid: int in owned_caps:
		var j: RoadJunctionSolverScript.Junction = junctions.get(nid, null)
		if j != null:
			out.append(j)
	return out


## Solve every junction reachable from a tile's ways, using the halo ways for
## completeness at the borders.
##
## `own_ways`   – the ways this tile renders (drives cap ownership).
## `halo_ways`  – own_ways PLUS the neighbouring tiles' ways, used only to make
##                each junction's arm set complete.
## `nodes`      – id -> OSMNode covering everything the above reference.
## `tile_rect`  – [min_x, max_x, min_z, max_z] of this tile, deciding which caps
##                this tile owns. Pass an empty array to own every junction
##                (the flat/whole-map path, where there is only one "tile").
static func build(
		own_ways: Array, halo_ways: Array, nodes: Dictionary,
		tile_rect: Array) -> RoadNetworkContextScript:
	var ctx := RoadNetworkContextScript.new()

	# Only real streets form intersections. A footpath crossing a road is a
	# crossing (painted), not a junction (carved), so soft ways are excluded
	# here even though they are still rendered as ribbons.
	var is_road_fn := func(w: OSMParser.OSMWay) -> bool:
		return RoadProfileScript.is_drivable(w)
	var width_fn := func(w: OSMParser.OSMWay) -> float:
		return RoadProfileScript.width_for(w)

	ctx.junctions = RoadJunctionSolverScript.solve_all(
		halo_ways, nodes, is_road_fn, width_fn)
	if ctx.junctions.is_empty():
		return ctx

	# Decide which caps this tile draws. Without a rect (single-tile worlds and
	# unit tests) the tile owns everything it solved.
	if tile_rect.size() < 4:
		for nid: int in ctx.junctions:
			ctx.owned_caps[nid] = true
		return ctx

	var min_x: float = tile_rect[0]
	var max_x: float = tile_rect[1]
	var min_z: float = tile_rect[2]
	var max_z: float = tile_rect[3]
	for nid: int in ctx.junctions:
		var j: RoadJunctionSolverScript.Junction = ctx.junctions[nid]
		var p := j.center
		# Half-open bounds so a junction exactly on a shared edge is claimed by
		# exactly one of the two tiles, never both and never neither.
		if p.x >= min_x and p.x < max_x and p.z >= min_z and p.z < max_z:
			ctx.owned_caps[nid] = true
	return ctx
