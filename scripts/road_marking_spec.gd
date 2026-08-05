class_name RoadMarkingSpec
extends RefCounted

## Transverse road markings that sit at a POINT along a road rather than running
## its whole length: zebra crossings, stop lines and give-way lines. Unlike the
## longitudinal lane markings (RoadLaneSpec), these come from OSM *nodes* placed
## on the way — where a footway crosses the carriageway, or where an approach
## must stop / give way — not from tags on the way itself.
##
## Each marking is reduced to just what the asphalt shader needs to paint a band
## across the carriageway: how far ALONG the road it sits (metres, matching the
## ribbon's UV.x) and which KIND of band to draw. Placement/orientation is
## implicit — the band always spans the carriageway at that distance, so it stays
## glued to the road on curves exactly like the lane lines.
##
## See:
##   https://wiki.openstreetmap.org/wiki/Key:crossing
##   https://wiki.openstreetmap.org/wiki/Tag:highway%3Dstop
##   https://wiki.openstreetmap.org/wiki/Tag:highway%3Dgive_way

## Marking kinds. The integer values are passed verbatim to the shader (as a
## float) so it can pick the band style; keep them in sync with asphalt.gdshader.
enum Kind {
	ZEBRA = 1,      ## Striped pedestrian crossing spanning the carriageway.
	STOP = 2,       ## Solid transverse bar (stop line).
	GIVE_WAY = 3,   ## Dashed transverse line (give-way / yield line).
}

## Hard cap on markings emitted per road, matching the shader's uniform array
## size. Roads with more crossing/stop nodes than this keep only the first N
## (nearest the start); in practice a single OSM way rarely carries more.
const MAX_MARKINGS := 8

## One marking: distance along the road in metres (UV.x space) and its Kind.
class Marking:
	var along: float = 0.0
	var kind: int = Kind.ZEBRA

	func _init(p_along: float = 0.0, p_kind: int = Kind.ZEBRA) -> void:
		along = p_along
		kind = p_kind

## The markings found on this road, ordered by `along` ascending. May be empty.
var markings: Array[Marking] = []


## True when this way carries no transverse markings.
func is_empty() -> bool:
	return markings.is_empty()


## A copy of this spec with every marking's along-distance shifted back by
## `offset` metres, dropping any marking that falls before the new origin.
##
## Junction trimming cuts the front off a road's ribbon, so the ribbon's UV
## origin moves `offset` metres down the way while these markings are still
## measured from the way's original start. Rebasing realigns them; a marking
## that now sits at a negative distance lay inside the intersection itself and
## is dropped, because the cap covers that ground and paints its own markings.
func rebased(offset: float) -> RoadMarkingSpec:
	if offset <= 0.0:
		return self
	var out := RoadMarkingSpec.new()
	for m: Marking in markings:
		var shifted := m.along - offset
		if shifted < 0.0:
			continue
		out.markings.append(Marking.new(shifted, m.kind))
	return out


## Along-road distances (metres) as a flat float array, capped to MAX_MARKINGS.
## Ordering matches kinds().
func along_positions() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in range(mini(markings.size(), MAX_MARKINGS)):
		out.append(markings[i].along)
	return out


## Marking Kind for each entry (as floats for the shader), same order as
## along_positions().
func kinds() -> PackedFloat32Array:
	var out := PackedFloat32Array()
	for i in range(mini(markings.size(), MAX_MARKINGS)):
		out.append(float(markings[i].kind))
	return out


## Build a marking spec for a road way by scanning its nodes for crossing / stop
## / give-way tags and projecting each onto the road's own polyline to get its
## metres-along distance.
##
## `node_ids` are the way's ordered node references; `osm_nodes` is the id→OSMNode
## map. The along distances are measured on the RAW polyline (the same path the
## ribbon follows), so they line up with the ribbon's UV.x regardless of any
## later terrain subdivision (which only inserts collinear points and preserves
## path length).
##
## Pure and side-effect free so it can be unit-tested without a scene.
static func from_way(node_ids: Array[int], osm_nodes: Dictionary) -> RoadMarkingSpec:
	var spec := RoadMarkingSpec.new()

	# Cumulative along-road distance at each present node, mirroring
	# OSMWayBuilder._cumulative_along so the shader's UV.x lines up.
	var pts: Array = []          # Vector2 XZ of each present node
	var along_at: Array = []     # metres from start at each present node
	var acc := 0.0
	for i in range(node_ids.size()):
		var nid: int = node_ids[i]
		if not osm_nodes.has(nid):
			continue
		var p: Vector3 = osm_nodes[nid].local_pos
		var here := Vector2(p.x, p.z)
		if not pts.is_empty():
			acc += here.distance_to(pts[pts.size() - 1])
		pts.append(here)
		along_at.append(acc)

		var kind := _classify(osm_nodes[nid].tags)
		if kind != 0:
			spec.markings.append(Marking.new(acc, kind))

	# Ordered by distance from the start; nodes are already in order, but sort
	# defensively so the cap in along_positions() keeps the earliest markings.
	spec.markings.sort_custom(func(a: Marking, b: Marking) -> bool:
		return a.along < b.along)
	return spec


## Classify a node's tags into a marking Kind, or 0 when the node carries no
## transverse road marking. Precedence: an explicit stop/give_way sign wins over
## a plain crossing (a node can be both a crossing and a stop, but the stop bar
## is the stronger cue for a driver).
static func _classify(tags: Dictionary) -> int:
	var highway := String(tags.get("highway", ""))
	if highway == "stop":
		return Kind.STOP
	if highway == "give_way":
		return Kind.GIVE_WAY
	if highway == "crossing":
		return _crossing_kind(tags)
	return 0


## A highway=crossing node is only painted when it is a MARKED crossing. OSM
## marks this with crossing=zebra/marked/uncontrolled or crossing:markings=* /
## marking=*. Unmarked/informal crossings (crossing=unmarked, no) get no paint.
static func _crossing_kind(tags: Dictionary) -> int:
	var crossing_markings := String(tags.get("crossing:markings", tags.get("marking", "")))
	if crossing_markings != "":
		return 0 if (crossing_markings == "no") else Kind.ZEBRA

	var crossing := String(tags.get("crossing", ""))
	match crossing:
		"zebra", "marked", "uncontrolled", "traffic_signals":
			return Kind.ZEBRA
		"unmarked", "no", "informal":
			return 0
		_:
			# Unknown/empty crossing value: paint a zebra by default so a plain
			# highway=crossing node still reads as a crossing on the road.
			return Kind.ZEBRA
