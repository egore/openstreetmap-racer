# Streets Roadmap — toward GTA-grade roads

Tracks the road/intersection rendering system: what shipped in v1, what is
deliberately deferred, and what we learned building it. Companion to
`MAKE_IT_FORZA.md`, which covers the surface/lighting side of the same goal.

## Where we started

Every OSM way was drawn as a full-length miter-joined ribbon that simply
**overlapped** other ways where they met — the Mapnik model. Z-fighting was
avoided by never writing depth and painting bigger road classes last.

From above that reads fine. At street level it obviously isn't a road network:

- There was no intersection surface at all, just two ribbons crossing.
- Lane lines ran straight through crossings.
- Kerbs stopped dead in mid-air wherever two streets met.
- `layer` / `bridge` / `tunnel` were ignored entirely for roads, so an overpass
  was painted flat onto the road it crossed.
- A ~220-line "lane attachment" workaround nudged narrow roads sideways onto a
  wider road's lane centre to disguise the missing junction. It also scanned
  every way in the tile per road, i.e. O(n²) per tile.

## v1 — shipped

Intersections are now real geometry.

### Junction solving — `scripts/road_junction_solver.gd`
Pure geometry, no scene tree, exactly unit-testable.

- **Arm-based detection.** A node is a junction when 3+ road *arms* meet there.
  Counting arms rather than ways is essential: a `+` crossing is only two ways,
  but each passes through and leaves in two directions. Counting ways would
  score it 2 and miss it — while a road merely continuing into another way also
  scores 2 but must *not* be treated as an intersection.
- **Trim distances.** Each arm is pulled back far enough to clear the corners it
  participates in, clamped so an acute fork can't eat a whole street.
- **Cap polygon** with rounded corner fillets, walked in bearing order.
- **Deterministic** by construction — this is load-bearing, see the halo below.

### Rendering — `scripts/osm_junction_builder.gd`
Intersection surface (terrain-draped like the ribbons), kerb corners wrapping
the junction, dropped-kerb ramps where pavement meets each arm, and painted stop
bars per approach. Junction markings are **explicit geometry** because the cap
has no along/across parameterisation for the shader's UV-driven lane lines.

### Tile-boundary correctness — `scripts/road_network_context.gd`
A junction near a tile border has arms owned by neighbouring tiles. Solving from
one tile's ways alone sees too few arms and computes a different trim than the
neighbour does — cutting the same street at two different points and leaving a
visible step on the seam.

Each tile is therefore solved against a **halo** of its eight neighbours, pulled
through the existing mutex-guarded LRU. Because the solver is deterministic,
tiles independently reach identical answers. Cap ownership is by containing
tile, so exactly one tile draws each intersection (duplicates would z-fight;
none would leave a hole).

Solving runs in the **worker-thread parse phase**, so it costs nothing from the
main thread's frame budget.

### Shared cross-section rules — `scripts/road_profile.gd`
Width, colour, kerb and layer rules in one place. The solver and the ribbon
builder must agree on width to the centimetre or caps won't meet ribbon mouths;
sharing this module makes that class of bug structurally impossible.

Also fixed here: OSM `sidewalk=separate` means *the footway is mapped as its own
way, so draw no inline kerb*. The old code drew a kerb **only** for `separate` —
exactly backwards.

### Layers
`layer` / `bridge` / `tunnel` now separate crossing roads vertically instead of
by paint order, inferring a level from `bridge=yes` / `tunnel=yes` when `layer`
is omitted. Tunnels are no longer drawn on the surface.

### Surface detection — `scripts/surface_detector.gd`
Now tests real mesh triangles rather than bounding boxes. The AABB approximation
was defensible for long ribbons but broke on intersections: a 45° road's AABB is
roughly twice the carriageway, so the car read "on tarmac" while driving over
grass beside it.

### Validation
| Metric | Result |
| --- | --- |
| Real intersections built (Netherlands extract) | 418 across 145 tiles |
| Cap triangulation failures | **0** (was 44 before the corner-pairing fix) |
| Junction solve, average per tile | 3.2 ms (worker thread) |
| Junction solve, worst tile | 6.2 ms (worker thread) |
| Test suite | 697 passing, 0 failures |

## v2 — deferred, in rough priority order

### 1. Roundabouts
The dataset has **33k** `junction=roundabout` ways, so this is the highest-value
remaining item. Roundabouts are closed *ways*, not junction nodes, and need a
different generator: ring carriageway, central island, arms trimmed to the ring
rather than to a cap polygon. They currently fall through to ordinary ribbon
rendering, so a roundabout reads as a loop of road rather than a roundabout.

### 2. Lane lines terminating before the junction
Lane markings currently run to the trimmed ribbon end. Real roads stop the
centre line short of the crossing. The shader already has an `end_fade` uniform
and `road_length`; this is mostly a matter of feeding it the trimmed length.

### 3. Crosswalks at junction approaches
Stop bars ship in v1; zebra crossings on junction arms do not. `RoadMarkingSpec`
already classifies crossing nodes for ribbons — the work is placing them on the
approach, oriented to that arm, as cap geometry.

### 4. Turn arrows
Needs `turn:lanes` parsing plus arrow geometry (or an SDF in the paint shader).
Cosmetic but a strong GTA cue.

### 5. Turn pockets / flares
Approach lanes widening into dedicated turn lanes. Requires per-arm width to
vary along its length, which the current constant-width ribbon can't express —
the largest structural change on this list.

### 6. Median islands
Raised or painted dividers on larger roads. Needs `dual_carriageway` handling to
avoid fighting with OSM's convention of mapping divided roads as two ways.

### 7. Collidable kerbs
Kerbs are visual-only in v1. Making them collidable means a StaticBody per
junction and segment; it needs care so the car doesn't catch on seams, and
should be measured behind a toggle before being switched on by default.

### 8. Per-tile mesh merging
Roads and junctions are still one mesh per feature. Batching per tile would cut
draw calls substantially. Deferred because it interacts with surface detection
and unload granularity, and no frame-rate problem has been demonstrated yet —
worth doing when there's a profile to point at.

## Notes for whoever picks this up

**Cap winding is load-bearing.** Arms sort by increasing `atan2(dir.z, dir.x)`.
A cap must pair each arm's RIGHT edge with the NEXT arm's LEFT edge. The
opposite pairing connects each arm to the far side of the junction and produces
a self-intersecting star that will not triangulate at all — the intersection
renders as a hole rather than as anything visibly wrong, so it's easy to
misdiagnose. `_corner_distance` must use the *same* pairing as `_build_cap`.

**Test `raw_cap`, not `cap`.** The convex-hull repair that rescues acute forks
will also quietly paper over a broken corner calculation. Assertions on cap
geometry should use `Junction.raw_cap` (the walk before repair) or they pass
with the maths wrong. Verified by reintroducing the corner-pairing bug and
confirming the test fails.

**Symmetric test fixtures hide corner bugs.** A `+` crossing has four congruent
corners, so it stays valid under transformations that break real junctions. The
corner-pairing bug passed every synthetic test and only surfaced against the
real extract. Asymmetric fixtures earn their keep here.
