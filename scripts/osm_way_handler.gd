class_name OSMWayHandler
extends RefCounted

## Abstract base for a single OSM way feature type (road, building, area, ...).
##
## Replaces the central if-elif dispatch that used to live in OSMTileManager.
## Each concrete handler owns two responsibilities for its feature type:
##   1. matches() — does this handler claim the way?
##   2. build()   — produce the Node3D to add under the tile (or null to skip).
##
## OSMTileManager keeps an ordered list of handlers and dispatches first-match-
## wins, so list order encodes the same precedence the if-elif chain did (e.g.
## power_line before area so closed-ring tests resolve the same way). Adding a
## feature type is now: write one handler file + add one line to that list.
##
## matches() should be a cheap, side-effect-free tag test. Any handler whose
## matcher must also be reusable outside the dispatch loop (e.g. the tile-
## coverage pre-pass needs the area/parking tests) exposes a static predicate
## that both matches() and the manager call, so the rule lives in one place.

## Stable identifier, handy for tests and debug output. Override in subclasses.
func handler_name() -> String:
	return "OSMWayHandler"


## Return true when this handler is responsible for rendering `way`.
## Must not mutate state.
func matches(_way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return false


## Build the renderable node for `way`. Returns null when there is nothing to
## add (degenerate geometry, suppressed feature, etc.). The manager parents a
## non-null result under the tile root.
func build(_way: OSMParser.OSMWay, _ctx: OSMTileContext) -> Node3D:
	return null


# ─── Shared predicate helpers ────────────────────────────────────────────────
# Static so handlers (and the manager's pre-passes) can reuse them without
# instantiating a handler. These migrated verbatim from OSMTileManager.

## A way is closed when its first and last node ids match (an enclosed ring).
static func is_closed_way(way: OSMParser.OSMWay) -> bool:
	return way.node_ids.size() >= 4 and way.node_ids[0] == way.node_ids[-1]
