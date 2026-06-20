extends GdUnitTestSuite

## Unit tests for the street-lamp feature set in OSMAssetPlacer:
##   - light:colour      → per-lamp tint (named value or hex literal)
##   - lamp_type/method  → tint fallback when no explicit light:colour
##   - light:count       → N bulbs + lights arranged in a widening ring
##
## The placer is a plain RefCounted, so each test builds one street_lamp node,
## runs it through place_assets_batched(), and inspects the resulting node tree
## and the LampGroup handed to a StreetLampLights controller. No SceneTree fade
## is exercised: we assert the resolved group.color and the bulb/light geometry,
## which are fixed at build time and independent of the day/night tween.

const OSMParser := preload("res://scripts/osm_parser.gd")

# Mirror the placer's authored constants so expectations track the source. If a
# constant changes, these update in lockstep rather than hard-coding magic RGBs.
const DEFAULT_COLOR := OSMAssetPlacer._LAMP_LIGHT_COLOR
const COLOUR_BY_NAME := OSMAssetPlacer._LAMP_COLOUR_BY_NAME
const COLOUR_BY_TYPE := OSMAssetPlacer._LAMP_COLOUR_BY_TYPE
const COUNT_MAX := OSMAssetPlacer._LAMP_COUNT_MAX
const BULB_SPACING := OSMAssetPlacer._LAMP_BULB_SPACING
const BULB_SIZE := OSMAssetPlacer._LAMP_BULB_SIZE


# ─── Fixtures ────────────────────────────────────────────────────────────────

## A street-lamp OSM node carrying the given tags (highway=street_lamp is added
## automatically so callers only specify the lighting tags under test).
func _lamp_node(tags: Dictionary) -> OSMParser.OSMNode:
	var node := OSMParser.OSMNode.new()
	node.id = 1
	node.lat = 49.0
	node.lon = 8.0
	node.local_pos = Vector3.ZERO
	var t := {"highway": "street_lamp"}
	t.merge(tags)
	node.tags = t
	return node


## Runs one lamp node through the placer with a StreetLampLights controller
## attached, and returns { root, group, controller } for inspection. The caller
## owns root and controller and must free them (free_built()).
func _build_lamp(tags: Dictionary) -> Dictionary:
	var placer := OSMAssetPlacer.new()
	var controller := StreetLampLights.new()
	# The controller is added to the scene tree only so any future tween has a
	# home; register_tile itself applies the level synchronously at level 0.
	add_child(controller)
	placer.lamp_lights = controller

	var root := placer.place_assets_batched([_lamp_node(tags)])
	assert_object(root) \
		.override_failure_message("placer builds a node for a street_lamp").is_not_null()

	# The group the placer registered for this tile (keyed by the Assets root).
	var group: StreetLampLights.LampGroup = null
	if root != null:
		group = controller._groups.get(root)

	return {"root": root, "group": group, "controller": controller}


func free_built(built: Dictionary) -> void:
	var root: Node = built.get("root")
	if root != null and is_instance_valid(root):
		root.free()
	var controller: Node = built.get("controller")
	if controller != null and is_instance_valid(controller):
		controller.free()


## Collects every placeholder bulb MeshInstance3D under a lamp root. Bulbs are
## named "Bulb0", "Bulb1", … by _add_placeholder_bulb.
func _bulbs(root: Node) -> Array:
	var out: Array = []
	for lamp: Node in root.get_children():
		for child: Node in lamp.get_children():
			if child is MeshInstance3D and child.name.begins_with("Bulb"):
				out.append(child)
	return out


## Collects every OmniLight3D under a lamp root.
func _lights(root: Node) -> Array:
	var out: Array = []
	for lamp: Node in root.get_children():
		for child: Node in lamp.get_children():
			if child is OmniLight3D:
				out.append(child)
	return out


# ─── light:colour ────────────────────────────────────────────────────────────

## A plain lamp (no colour/type tags) keeps the default warm tint.
func test_default_colour_when_untagged() -> void:
	var built := _build_lamp({})
	var group: StreetLampLights.LampGroup = built["group"]
	assert_object(group) \
		.override_failure_message("a street lamp registers a LampGroup").is_not_null()
	if group != null:
		assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
			.override_failure_message("untagged lamp uses the default warm tint") \
			.is_equal_approx(Vector3(DEFAULT_COLOR.r, DEFAULT_COLOR.g, DEFAULT_COLOR.b), Vector3.ONE * 0.001)
	free_built(built)


## Each named light:colour value resolves to its table entry.
func test_named_colour_values() -> void:
	for name: String in COLOUR_BY_NAME:
		var expected: Color = COLOUR_BY_NAME[name]
		var built := _build_lamp({"light:colour": name})
		var group: StreetLampLights.LampGroup = built["group"]
		if group != null:
			assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
				.override_failure_message("light:colour=%s resolves to its named tint" % name) \
				.is_equal_approx(Vector3(expected.r, expected.g, expected.b), Vector3.ONE * 0.001)
		free_built(built)


## A named light:colour value is matched case-insensitively and trimmed.
func test_named_colour_is_case_and_space_insensitive() -> void:
	var expected: Color = COLOUR_BY_NAME["orange"]
	var built := _build_lamp({"light:colour": "  Orange "})
	var group: StreetLampLights.LampGroup = built["group"]
	if group != null:
		assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
			.override_failure_message("light:colour matching ignores case/whitespace") \
			.is_equal_approx(Vector3(expected.r, expected.g, expected.b), Vector3.ONE * 0.001)
	free_built(built)


## A hex literal light:colour is parsed directly.
func test_hex_colour_literal() -> void:
	var built := _build_lamp({"light:colour": "#ffcc88"})
	var group: StreetLampLights.LampGroup = built["group"]
	var expected := Color.html("#ffcc88")
	if group != null:
		assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
			.override_failure_message("hex light:colour is parsed to that colour") \
			.is_equal_approx(Vector3(expected.r, expected.g, expected.b), Vector3.ONE * 0.001)
	free_built(built)


## An unrecognised light:colour value falls through to the default tint.
func test_unknown_colour_falls_back_to_default() -> void:
	var built := _build_lamp({"light:colour": "ultraviolet"})
	var group: StreetLampLights.LampGroup = built["group"]
	if group != null:
		assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
			.override_failure_message("unknown light:colour falls back to the default") \
			.is_equal_approx(Vector3(DEFAULT_COLOR.r, DEFAULT_COLOR.g, DEFAULT_COLOR.b), Vector3.ONE * 0.001)
	free_built(built)


# ─── lamp_type / light:method fallback ───────────────────────────────────────

## With no explicit light:colour, lamp_type picks the typical tint (sodium →
## orange-ish, LED → white-ish per the wiki's colour column).
func test_lamp_type_drives_colour_fallback() -> void:
	var built := _build_lamp({"lamp_type": "high_pressure_sodium"})
	var group: StreetLampLights.LampGroup = built["group"]
	var expected: Color = COLOUR_BY_TYPE["high_pressure_sodium"]
	if group != null:
		assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
			.override_failure_message("lamp_type=high_pressure_sodium tints orange") \
			.is_equal_approx(Vector3(expected.r, expected.g, expected.b), Vector3.ONE * 0.001)
	free_built(built)


## light:method is honoured as an alias for lamp_type.
func test_light_method_alias_drives_colour() -> void:
	var built := _build_lamp({"light:method": "LED"})
	var group: StreetLampLights.LampGroup = built["group"]
	var expected: Color = COLOUR_BY_TYPE["led"]
	if group != null:
		assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
			.override_failure_message("light:method=LED resolves like lamp_type=led") \
			.is_equal_approx(Vector3(expected.r, expected.g, expected.b), Vector3.ONE * 0.001)
	free_built(built)


## An explicit light:colour wins over lamp_type when both are present.
func test_explicit_colour_beats_lamp_type() -> void:
	var built := _build_lamp({"light:colour": "white", "lamp_type": "high_pressure_sodium"})
	var group: StreetLampLights.LampGroup = built["group"]
	var expected: Color = COLOUR_BY_NAME["white"]
	if group != null:
		assert_vector(Vector3(group.color.r, group.color.g, group.color.b)) \
			.override_failure_message("light:colour takes precedence over lamp_type") \
			.is_equal_approx(Vector3(expected.r, expected.g, expected.b), Vector3.ONE * 0.001)
	free_built(built)


# ─── light:count ─────────────────────────────────────────────────────────────

## A plain lamp has exactly one bulb and one light.
func test_single_bulb_when_untagged() -> void:
	var built := _build_lamp({})
	var root: Node = built["root"]
	assert_int(_bulbs(root).size()) \
		.override_failure_message("an untagged lamp has one bulb").is_equal(1)
	assert_int(_lights(root).size()) \
		.override_failure_message("an untagged lamp casts one light").is_equal(1)
	free_built(built)


## light:count=N produces N bulbs AND N lights (each head casts its own light).
func test_count_spawns_matching_bulbs_and_lights() -> void:
	for n: int in [2, 3, 4, 6]:
		var built := _build_lamp({"light:count": str(n)})
		var root: Node = built["root"]
		assert_int(_bulbs(root).size()) \
			.override_failure_message("light:count=%d builds %d bulbs" % [n, n]).is_equal(n)
		assert_int(_lights(root).size()) \
			.override_failure_message("light:count=%d builds %d lights" % [n, n]).is_equal(n)
		free_built(built)


## A single bulb sits on the pole axis (XZ at origin), not offset onto a ring.
func test_single_bulb_is_centred() -> void:
	var built := _build_lamp({})
	var root: Node = built["root"]
	var bulbs := _bulbs(root)
	if bulbs.size() == 1:
		var p: Vector3 = bulbs[0].position
		assert_float(Vector2(p.x, p.z).length()) \
			.override_failure_message("a lone bulb sits on the pole axis").is_less(0.001)
	free_built(built)


## light:count=4 lands the bulbs at the four cardinal angles (0/90/180/270°),
## all at the same ring radius and the same height.
func test_four_bulbs_form_a_cardinal_ring() -> void:
	var built := _build_lamp({"light:count": "4"})
	var root: Node = built["root"]
	var bulbs := _bulbs(root)
	assert_int(bulbs.size()).is_equal(4)
	if bulbs.size() == 4:
		var radii: Array[float] = []
		var heights: Array[float] = []
		var angles: Array[float] = []
		for b: MeshInstance3D in bulbs:
			var p: Vector3 = b.position
			radii.append(Vector2(p.x, p.z).length())
			heights.append(p.y)
			# Normalise angle to [0, 360).
			angles.append(fposmod(rad_to_deg(atan2(p.z, p.x)), 360.0))

		# All four share one radius (the ring) and one height (the head top).
		var r0 := radii[0]
		for r: float in radii:
			assert_float(r).override_failure_message("all ring bulbs share one radius").is_equal_approx(r0, 0.001)
		var h0 := heights[0]
		for h: float in heights:
			assert_float(h).override_failure_message("all ring bulbs share one height").is_equal_approx(h0, 0.001)
		# The radius is positive (bulbs really are spread off the axis).
		assert_float(r0).override_failure_message("a 4-head ring has a positive radius").is_greater(0.0)

		# Each of the four cardinal directions is occupied exactly once.
		angles.sort()
		var expected := [0.0, 90.0, 180.0, 270.0]
		for i: int in range(4):
			assert_float(angles[i]) \
				.override_failure_message("4 bulbs sit at 0/90/180/270°, got %s" % str(angles)) \
				.is_equal_approx(expected[i], 0.5)
	free_built(built)


## The ring widens with the count: more heads ⇒ a strictly larger radius, so
## bulbs keep their spacing instead of crowding the post.
func test_ring_radius_grows_with_count() -> void:
	var prev_radius := -1.0
	for n: int in [2, 4, 6, 8]:
		var built := _build_lamp({"light:count": str(n)})
		var root: Node = built["root"]
		var bulbs := _bulbs(root)
		var radius := 0.0
		if bulbs.size() > 0:
			var p: Vector3 = bulbs[0].position
			radius = Vector2(p.x, p.z).length()
		assert_float(radius) \
			.override_failure_message("ring radius grows with count (n=%d r=%.3f prev=%.3f)" % [n, radius, prev_radius]) \
			.is_greater(prev_radius)
		prev_radius = radius
		free_built(built)


## light:count is clamped to the upper bound, so a typo can't spawn a swarm.
func test_count_clamped_to_max() -> void:
	var built := _build_lamp({"light:count": "999"})
	var root: Node = built["root"]
	assert_int(_bulbs(root).size()) \
		.override_failure_message("light:count is clamped to _LAMP_COUNT_MAX").is_equal(COUNT_MAX)
	free_built(built)


## Invalid / non-positive light:count values degrade to a single bulb.
func test_invalid_count_degrades_to_one() -> void:
	for bad: String in ["0", "-3", "two", "", "3.5"]:
		var built := _build_lamp({"light:count": bad})
		var root: Node = built["root"]
		assert_int(_bulbs(root).size()) \
			.override_failure_message("light:count=%s degrades to one bulb" % bad).is_equal(1)
		free_built(built)
