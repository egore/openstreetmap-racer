class_name OSMAssetPlacer
extends RefCounted

## Places placeholder 3D assets for OSM nodes based on their tags.
## Each asset type is a simple colored box/shape with a label.

# Asset definitions: tag_key -> { tag_value -> { color, size, y_offset, label, scene (optional) } }
# If tag_value is "*", matches any value for that key.
# If "scene" is set, that PackedScene is instanced instead of a placeholder box.

var _scene_cache: Dictionary = {}  # path -> PackedScene

## When false (the default) debug labels above assets are created but hidden.
## The pause-menu toggle flips this and shows/hides every label in the
## "debug_labels" scene-tree group so the setting takes effect immediately —
## even for tiles that were already streamed in.
var show_debug_labels: bool = false

## The world's street-lamp light controller. Injected by OSMTileManager. When
## present, street lamps are built with a real emissive bulb + OmniLight3D and
## registered here so they switch on after dark; when null (e.g. unit tests that
## exercise the placer in isolation) lamps fall back to the plain placeholder
## pole and emit no light. Optional so the placer has no hard dependency on the
## day/night system.
var lamp_lights: StreetLampLights = null

# A street lamp emits light from its head, so it can't be a flat placeholder box
# like the other point assets. `light` flags the def for the dedicated build path
# in place_assets_batched() (bulb mesh + OmniLight3D), bypassing MultiMesh
# batching the same way `scene` assets do.
const ASSET_DEFS := {
	"highway": {
		"traffic_signals": { "color": Color(0.1, 0.7, 0.1), "size": Vector3(0.3, 3.0, 0.3), "y_offset": 1.5, "label": "Traffic Light", "scene": "res://scenes/models/traffic_light.blend" },
		# Street lamps always emit light (`light: true`). The optional `support`
		# subtag refines the *body*: a bent-mast lamp swaps the placeholder pole
		# for a custom model whose built-in "light" mesh becomes the glowing head.
		# `support` variants inherit the base fields and override only what they
		# name, so they keep `light: true` and the head offsets without repeating
		# them. Add a new mast style by dropping a model in and adding one entry.
		"street_lamp": {
			"color": Color(0.25, 0.22, 0.12), "size": Vector3(0.15, 4.0, 0.15), "y_offset": 2.0, "label": "Street Lamp", "light": true,
			"support": {
				"bent_mast": { "scene": "res://scenes/models/street_lamp-bent_mast.blend" },
			},
		},
		"bus_stop": { "color": Color(0.2, 0.4, 0.8), "size": Vector3(0.8, 2.5, 0.3), "y_offset": 1.25, "label": "Bus Stop", "scene": "res://scenes/models/bus_stop.blend" },
		"crossing": { "color": Color(1.0, 1.0, 1.0), "size": Vector3(2.0, 0.05, 2.0), "y_offset": 0.025, "label": "Crossing" },
		"stop": { "color": Color(0.9, 0.1, 0.1), "size": Vector3(0.5, 2.0, 0.05), "y_offset": 1.0, "label": "Stop Sign" },
		"give_way": { "color": Color(0.9, 0.9, 0.1), "size": Vector3(0.5, 2.0, 0.05), "y_offset": 1.0, "label": "Give Way", "scene": "res://scenes/models/give_way.blend" },
	},
	"natural": {
		"tree": { "color": Color(0.15, 0.5, 0.1), "size": Vector3(2.0, 5.0, 2.0), "y_offset": 2.5, "label": "Tree", "scene": "res://scenes/models/tree.blend" },
		"tree_row": { "color": Color(0.15, 0.5, 0.1), "size": Vector3(2.0, 5.0, 2.0), "y_offset": 2.5, "label": "Tree", "scene": "res://scenes/models/tree.blend" },
		"peak": { "color": Color(0.6, 0.5, 0.4), "size": Vector3(1.0, 3.0, 1.0), "y_offset": 1.5, "label": "Peak" },
	},
	"amenity": {
		"bench": { "color": Color(0.5, 0.35, 0.2), "size": Vector3(1.5, 0.5, 0.5), "y_offset": 0.25, "label": "Bench" },
		"waste_basket": { "color": Color(0.3, 0.3, 0.3), "size": Vector3(0.4, 0.8, 0.4), "y_offset": 0.4, "label": "Waste Basket" },
		"post_box": { "color": Color(0.9, 0.8, 0.1), "size": Vector3(0.4, 1.2, 0.3), "y_offset": 0.6, "label": "Post Box" },
		"telephone": { "color": Color(0.8, 0.2, 0.2), "size": Vector3(0.8, 2.2, 0.8), "y_offset": 1.1, "label": "Phone Booth" },
		"fuel": { "color": Color(0.8, 0.3, 0.1), "size": Vector3(2.0, 3.0, 1.0), "y_offset": 1.5, "label": "Fuel Station" },
		"parking": { "color": Color(0.3, 0.3, 0.7), "size": Vector3(1.0, 2.0, 0.1), "y_offset": 1.0, "label": "Parking Sign" },
		"charging_station": { "color": Color(0.2, 0.8, 0.3), "size": Vector3(0.5, 1.4, 0.4), "y_offset": 0.7, "label": "Charging Station" },
	},
	"barrier": {
		"bollard": { "color": Color(0.5, 0.5, 0.5), "size": Vector3(0.2, 0.8, 0.2), "y_offset": 0.4, "label": "Bollard", "scene": "res://scenes/models/bollard.blend" },
		"gate": { "color": Color(0.4, 0.3, 0.2), "size": Vector3(3.0, 1.5, 0.1), "y_offset": 0.75, "label": "Gate" },
		"fence": { "color": Color(0.5, 0.4, 0.3), "size": Vector3(0.1, 1.5, 0.1), "y_offset": 0.75, "label": "Fence Post" },
		"hedge": { "color": Color(0.2, 0.45, 0.15), "size": Vector3(0.6, 1.2, 0.6), "y_offset": 0.6, "label": "Hedge" },
		"wall": { "color": Color(0.55, 0.55, 0.55), "size": Vector3(0.3, 1.5, 0.3), "y_offset": 0.75, "label": "Wall" },
		# barrier=wall + wall=noise_barrier: tall sound-deadening wall (~3 m).
		"noise_barrier": { "color": Color(0.5, 0.52, 0.58), "size": Vector3(0.3, 3.0, 0.3), "y_offset": 1.5, "label": "Noise Barrier" },
	},
	"man_made": {
		"tower": { "color": Color(0.6, 0.6, 0.6), "size": Vector3(2.0, 15.0, 2.0), "y_offset": 7.5, "label": "Tower" },
		"mast": { "color": Color(0.5, 0.5, 0.5), "size": Vector3(0.5, 20.0, 0.5), "y_offset": 10.0, "label": "Mast" },
		"chimney": { "color": Color(0.55, 0.45, 0.4), "size": Vector3(1.5, 25.0, 1.5), "y_offset": 12.5, "label": "Chimney" },
	},
	"power": {
		"tower": { "color": Color(0.5, 0.5, 0.55), "size": Vector3(1.5, 20.0, 1.5), "y_offset": 10.0, "label": "Power Tower" },
		"pole": { "color": Color(0.45, 0.4, 0.35), "size": Vector3(0.2, 8.0, 0.2), "y_offset": 4.0, "label": "Power Pole" },
	},
	"tourism": {
		"information": { "color": Color(0.2, 0.5, 0.8), "size": Vector3(0.5, 2.0, 0.1), "y_offset": 1.0, "label": "Info Board" },
		"viewpoint": { "color": Color(0.3, 0.6, 0.9), "size": Vector3(1.0, 1.0, 1.0), "y_offset": 0.5, "label": "Viewpoint" },
	},
	"shop": {
		"*": { "color": Color(0.8, 0.6, 0.2), "size": Vector3(1.0, 2.5, 1.0), "y_offset": 1.25, "label": "Shop" },
	},
	"traffic_sign": {
		"city_limit": { "color": Color(0.9, 0.9, 0.9), "size": Vector3(0.6, 2.0, 0.05), "y_offset": 1.5, "label": "Traffic Sign", "scene": "res://scenes/models/city_limit.blend" },
		"*": { "color": Color(0.9, 0.9, 0.9), "size": Vector3(0.6, 2.0, 0.05), "y_offset": 1.5, "label": "Traffic Sign" },
	},
}

## Place a whole tile's worth of point assets at once.
##
## Placeholder-box assets that share the same definition (same mesh size +
## colour) are merged into a single MultiMeshInstance3D, collapsing what used
## to be one MeshInstance3D + material per node into one draw call per asset
## type. Scene-based assets (trees, bollards, ...) and their labels keep the
## per-instance path since they are full imported sub-scenes.
##
## Returns a single container Node3D holding all placed assets for the tile,
## or null if nothing was placed.
func place_assets_batched(nodes: Array) -> Node3D:
	if nodes.is_empty():
		return null

	var root := Node3D.new()
	root.name = "Assets"

	# Group placeholder-box nodes by a key derived from their definition so
	# identical assets land in the same MultiMesh.
	var box_groups: Dictionary = {}  # group_key -> { def, transforms: Array[Transform3D] }

	# Street lamps build a real light each, so they're collected into one group
	# per tile and registered with the lamp controller in a single call below.
	var lamp_group := StreetLampLights.LampGroup.new()

	for node: OSMParser.OSMNode in nodes:
		var def := _find_asset_def(node.tags)
		if def.is_empty():
			continue

		if def.get("light", false):
			# Street lamps: emissive pole + bulb + point light, not a flat box.
			var lamp := _build_street_lamp(def, node, lamp_group)
			if lamp != null:
				root.add_child(lamp)
				_add_debug_label_at(root, def, node.tags, node.local_pos)
			continue

		if def.has("scene"):
			# Scene assets are not trivially batchable; keep the existing path.
			var placed := place_asset(node)
			if placed != null:
				root.add_child(placed)
			continue

		var key := _box_group_key(def)
		if not box_groups.has(key):
			box_groups[key] = { "def": def, "transforms": [] as Array[Transform3D] }
		var y_offset: float = def["y_offset"]

		# Some amenities (e.g. charging stations) carry a `capacity` tag that
		# describes how many units exist at the spot. Draw one block per unit,
		# laid out in a centered row so the cluster reads as a single station.
		var count := _node_block_count(node.tags)
		var size: Vector3 = def["size"]
		var spacing: float = size.x + 0.2
		var row_start: float = -spacing * float(count - 1) * 0.5
		for i in range(count):
			var col_offset := Vector3(row_start + spacing * float(i), 0.0, 0.0)
			var xform := Transform3D(Basis.IDENTITY, node.local_pos + col_offset + Vector3(0.0, y_offset, 0.0))
			box_groups[key]["transforms"].append(xform)

		# A MultiMesh can't carry per-instance labels, so batched box assets
		# (give_way, stop, crossing, ...) would otherwise lose their debug
		# labels entirely. Add one Label3D per node, lifted relative to the
		# node's elevated ground position.
		_add_debug_label_at(root, def, node.tags, node.local_pos)

	for key: String in box_groups:
		var group: Dictionary = box_groups[key]
		var mmi := _build_box_multimesh(group["def"], group["transforms"])
		if mmi != null:
			root.add_child(mmi)

	if root.get_child_count() == 0:
		root.free()
		return null

	# Hand this tile's street lamps to the controller keyed by the Assets root,
	# so it can both light them at the current time of day now and drop them when
	# the tile unloads. Registering after the empty-tile guard means a tile with
	# no lamps never registers an empty group.
	if lamp_lights != null and not lamp_group.lights.is_empty():
		lamp_lights.register_tile(root, lamp_group)

	return root


func _box_group_key(def: Dictionary) -> String:
	var size: Vector3 = def["size"]
	var color: Color = def["color"]
	return "%s|%s" % [size, color]


# Number of blocks to draw for a node. Defaults to 1, but honors the OSM
# `capacity` tag (used by amenity=charging_station among others) so a station
# with N charging points renders as N blocks.
func _node_block_count(tags: Dictionary) -> int:
	if not tags.has("capacity"):
		return 1
	var raw: String = str(tags["capacity"]).strip_edges()
	if not raw.is_valid_int():
		return 1
	return clampi(raw.to_int(), 1, 16)


func _build_box_multimesh(def: Dictionary, transforms: Array) -> MultiMeshInstance3D:
	if transforms.is_empty():
		return null

	var box := BoxMesh.new()
	box.size = def["size"]

	var mat := StandardMaterial3D.new()
	mat.albedo_color = def["color"]
	box.material = mat

	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = box
	multimesh.instance_count = transforms.size()
	for i: int in range(transforms.size()):
		multimesh.set_instance_transform(i, transforms[i])

	var mmi := MultiMeshInstance3D.new()
	mmi.name = "%s_x%d" % [def["label"].replace(" ", ""), transforms.size()]
	mmi.multimesh = multimesh
	return mmi


# ─── Street lamps ────────────────────────────────────────────────────────────

## Warm colour of the bulb glow and the pool of light it casts. A slightly
## orange sodium-vapour tint reads as "street lamp" far more than plain white.
## Used as the fallback when a lamp's tags name no recognisable colour or type.
const _LAMP_LIGHT_COLOR := Color(1.0, 0.85, 0.55)

## Named values for OSM `light:colour=*`. The wiki lists white / warm_white /
## orange / yellow as the common values; anything else falls through to a hex
## parse (e.g. light:colour=#ffcc88) and then to _LAMP_LIGHT_COLOR.
const _LAMP_COLOUR_BY_NAME := {
	"white": Color(1.0, 0.97, 0.9),
	"warm_white": Color(1.0, 0.9, 0.72),
	"yellow": Color(1.0, 0.85, 0.45),
	"orange": Color(1.0, 0.6, 0.25),
}

## Fallback tint by `lamp_type` / `light:method` when no explicit light:colour is
## given. Follows the wiki's "Typische Lichtfarbe" column so a sodium street
## glows orange and an LED street stays white without any colour tag.
const _LAMP_COLOUR_BY_TYPE := {
	"led": Color(1.0, 0.97, 0.9),
	"fluorescent": Color(1.0, 0.97, 0.9),
	"metal_halide": Color(0.92, 0.95, 1.0),
	"mercury": Color(0.9, 0.95, 1.0),
	"high_pressure_sodium": Color(1.0, 0.6, 0.25),
	"sodium": Color(1.0, 0.55, 0.15),
	"incandescent": Color(1.0, 0.88, 0.68),
	"gaslight": Color(1.0, 0.82, 0.55),
}
## OmniLight3D energy each lamp reaches when fully on. Tuned to drop a visible
## pool on the road at night without washing the scene out; lamps are dense, so
## modest per-lamp energy still adds up to a lit street.
const _LAMP_LIGHT_ENERGY := 3.0
## How far (metres) each lamp's light reaches. Roughly the pole height plus a few
## metres of spill onto the road around its base.
const _LAMP_LIGHT_RANGE := 12.0
## Emission multiplier of the bulb head when fully on (the visible glow of the
## bulb itself, separate from the light it casts).
const _LAMP_GLOW_ENERGY := 6.0

## Name of the emissive lamp-head mesh inside a street-lamp model (e.g. the
## bent-mast .blend). Its material is driven as the glowing bulb and the cast
## light is placed at its centre, so the model author controls *where* the head
## is just by naming the mesh — the script never hard-codes a head position for
## scene lamps.
const _LAMP_HEAD_MESH_NAME := "light"

## Builds one street lamp and wires its glowing head + cast light into `group`
## (not switched on here) so the StreetLampLights controller drives it with the
## rest of the world's lamps. A fresh lamp starts dark; the controller brings it
## to the current time-of-day brightness when the tile is registered.
##
## Two body styles share this path:
##   - a custom model (def has `scene`, e.g. support=bent_mast), whose built-in
##     "light" mesh becomes the head; or
##   - the default placeholder pole with a small box bulb on top.
## Either way the light/glow plumbing is identical, so the controller treats all
## lamps the same.
func _build_street_lamp(def: Dictionary, node: OSMParser.OSMNode, group: StreetLampLights.LampGroup) -> Node3D:
	var root := Node3D.new()
	root.name = "%s_%d" % [def["label"].replace(" ", ""), node.id]
	root.position = node.local_pos

	group.light_energy = _LAMP_LIGHT_ENERGY
	group.glow_energy = _LAMP_GLOW_ENERGY
	group.color = _resolve_lamp_color(node.tags)

	if def.has("scene"):
		_build_scene_lamp_body(def, root, group)
	else:
		_build_placeholder_lamp_body(def, root, group)

	return root


## Resolves a lamp's tint from its OSM tags. `light:colour=*` wins (a named value
## like "orange" or a hex literal like "#ffcc88"); failing that the lamp's
## `lamp_type`/`light:method` maps to a typical colour (sodium → orange, LED →
## white); failing that we fall back to the default warm tint. Matching is
## case-insensitive and tolerant of stray whitespace, as OSM data is hand-tagged.
func _resolve_lamp_color(tags: Dictionary) -> Color:
	if tags.has("light:colour"):
		var raw: String = str(tags["light:colour"]).strip_edges().to_lower()
		if _LAMP_COLOUR_BY_NAME.has(raw):
			return _LAMP_COLOUR_BY_NAME[raw]
		# Hex literal (#rgb / #rrggbb), the other common light:colour form.
		if raw.begins_with("#") and raw.is_valid_html_color():
			return Color.html(raw)

	for type_key: String in ["lamp_type", "light:method"]:
		if tags.has(type_key):
			var type_value: String = str(tags[type_key]).strip_edges().to_lower()
			if _LAMP_COLOUR_BY_TYPE.has(type_value):
				return _LAMP_COLOUR_BY_TYPE[type_value]

	return _LAMP_LIGHT_COLOR


## Bent-mast (and any future model-backed) lamp body: instance the model and use
## its built-in "light" mesh as the glowing head, dropping a point light at the
## head's centre. Falls back to the placeholder body if the model is missing or
## has no head mesh, so a bad/absent asset degrades to a working lamp instead of
## a dark, light-less one.
func _build_scene_lamp_body(def: Dictionary, root: Node3D, group: StreetLampLights.LampGroup) -> void:
	var scene := _load_scene(def["scene"])
	if scene == null:
		_build_placeholder_lamp_body(def, root, group)
		return
	var model := scene.instantiate()
	root.add_child(model)

	var head := _find_node_by_name(model, _LAMP_HEAD_MESH_NAME) as MeshInstance3D
	if head == null:
		push_warning("OSMAssetPlacer: street-lamp model %s has no '%s' mesh; using placeholder light" % [def["scene"], _LAMP_HEAD_MESH_NAME])
		_build_placeholder_lamp_body(def, root, group)
		return

	# Drive the model's own head material as the bulb glow. Make it unique per
	# instance first so toggling one lamp's glow never bleeds into the shared
	# imported material (every bent-mast lamp would otherwise glow together).
	var head_mat := head.get_active_material(0)
	if head_mat is StandardMaterial3D:
		var unique := (head_mat as StandardMaterial3D).duplicate() as StandardMaterial3D
		unique.emission = group.color
		unique.emission_enabled = false
		unique.emission_energy_multiplier = 0.0
		head.set_surface_override_material(0, unique)
		group.materials.append(unique)

	# Cast the pooled light from the head's centre (in root space). The bent mast
	# reaches out horizontally, so the head sits off the pole's base — using the
	# mesh AABB centre keeps the light under the actual lamp, not the post.
	var head_center := _node_aabb_center_in(head, root)
	_add_lamp_light(root, group, head_center)


## Default placeholder body: a dark pole with a small emissive box bulb on top
## and a light beneath it. Used when no model is specified (plain street_lamp) or
## as the graceful fallback when a model can't be loaded.
func _build_placeholder_lamp_body(def: Dictionary, root: Node3D, group: StreetLampLights.LampGroup) -> void:
	var size: Vector3 = def["size"]
	var y_offset: float = def["y_offset"]

	# Pole: a thin dark post. Reuses the def size/colour (an unlit metal grey)
	# so the lamp body is visible by day without pretending to glow.
	var pole := MeshInstance3D.new()
	pole.name = "Pole"
	var pole_mesh := BoxMesh.new()
	pole_mesh.size = size
	pole.mesh = pole_mesh
	var pole_mat := StandardMaterial3D.new()
	pole_mat.albedo_color = def["color"]
	pole.material_override = pole_mat
	pole.position.y = y_offset
	root.add_child(pole)

	# Bulb head: a small box at the top of the pole carrying its own emissive
	# material, made unique per lamp and handed to the controller.
	var head_y := y_offset + size.y * 0.5
	var bulb := MeshInstance3D.new()
	bulb.name = "Bulb"
	var bulb_mesh := BoxMesh.new()
	bulb_mesh.size = Vector3(0.3, 0.18, 0.3)
	bulb.mesh = bulb_mesh
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = group.color
	bulb_mat.emission = group.color
	bulb_mat.emission_enabled = false
	bulb_mat.emission_energy_multiplier = 0.0
	bulb.material_override = bulb_mat
	bulb.position.y = head_y
	root.add_child(bulb)
	group.materials.append(bulb_mat)

	_add_lamp_light(root, group, Vector3(0.0, head_y - 0.2, 0.0))


## Adds the OmniLight3D that pools light on the road below a lamp head and
## registers it with the group. Starts off (energy 0, hidden); the controller
## fades it in after dusk. Shadows are off — dozens of shadow-casting point
## lights would tank performance and add little at night.
func _add_lamp_light(root: Node3D, group: StreetLampLights.LampGroup, local_pos: Vector3) -> void:
	var light := OmniLight3D.new()
	light.name = "Light"
	light.light_color = group.color
	light.light_energy = 0.0
	light.omni_range = _LAMP_LIGHT_RANGE
	light.shadow_enabled = false
	light.visible = false
	light.position = local_pos
	root.add_child(light)
	group.lights.append(light)


## Depth-first search for the first descendant (or `node` itself) whose name
## matches `name`, case-insensitively. Imported meshes may carry suffixes or
## differ in case from the Blender object name, so an exact match would be
## brittle; this tolerates "light", "Light", "light2" → matched on the stem.
func _find_node_by_name(node: Node, target: String) -> Node:
	if node.name.to_lower().begins_with(target.to_lower()):
		return node
	for child in node.get_children():
		var found := _find_node_by_name(child, target)
		if found != null:
			return found
	return null


## AABB centre of a MeshInstance3D expressed in the space of an ancestor
## `relative_to`. Used to place a lamp's light under its head when the head is
## offset from the pole base (bent mast).
##
## Deliberately composes the chain of *local* transforms from `mesh` up to
## `relative_to` instead of using global_transform: this runs while the lamp
## subtree is still detached (built before being added to the tile), where
## global_transform is invalid and would both error and return identity.
func _node_aabb_center_in(mesh: MeshInstance3D, relative_to: Node3D) -> Vector3:
	var center := mesh.get_aabb().get_center()
	var xform := Transform3D.IDENTITY
	var n: Node = mesh
	while n != null and n != relative_to:
		if n is Node3D:
			xform = (n as Node3D).transform * xform
		n = n.get_parent()
	return xform * center


func place_asset(node: OSMParser.OSMNode) -> Node3D:
	var def := _find_asset_def(node.tags)
	if def.is_empty():
		return null

	var root := Node3D.new()
	root.name = "%s_%d" % [def["label"].replace(" ", ""), node.id]
	root.position = node.local_pos

	# If a scene is defined, instance it instead of a placeholder box
	if def.has("scene"):
		var scene_path: String = def["scene"]
		var scene := _load_scene(scene_path)
		if scene != null:
			var instance := scene.instantiate()
			root.add_child(instance)
			_add_debug_label(root, def, node.tags)
			return root

	# Fallback: create a placeholder box
	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"

	var box := BoxMesh.new()
	var size: Vector3 = def["size"]
	box.size = size
	mesh_instance.mesh = box

	var mat := StandardMaterial3D.new()
	mat.albedo_color = def["color"]
	mesh_instance.material_override = mat
	mesh_instance.position.y = def["y_offset"]

	root.add_child(mesh_instance)
	_add_debug_label(root, def, node.tags)

	return root

func place_way_asset(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> Node3D:
	var def := _find_asset_def(way.tags)
	if def.is_empty():
		return null

	var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
	if points.size() < 2:
		return null

	var root := Node3D.new()
	root.name = "%s_%d" % [def["label"].replace(" ", ""), way.id]

	var color: Color = def["color"]
	var height: float = def["size"].y
	var width: float = def["size"].x

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Mesh"

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	# Thin linear features (fences/walls) should stay visible from both sides.
	# Geometry is now single-winding (one set of faces), so disable backface
	# culling on the material instead of emitting duplicate flipped triangles.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	st.set_material(mat)

	var half_w := width / 2.0

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]
		var forward := (p1 - p0).normalized()
		var right := Vector3(-forward.z, 0.0, forward.x).normalized() * half_w

		# Bottom vertices sit on the terrain (p.y carries the DEM elevation; 0 in
		# a flat world); tops are height meters above each end's ground.
		var bl0 := Vector3(p0.x - right.x, p0.y, p0.z - right.z)
		var br0 := Vector3(p0.x + right.x, p0.y, p0.z + right.z)
		var bl1 := Vector3(p1.x - right.x, p1.y, p1.z - right.z)
		var br1 := Vector3(p1.x + right.x, p1.y, p1.z + right.z)

		# Top vertices
		var tl0 := Vector3(bl0.x, p0.y + height, bl0.z)
		var tr0 := Vector3(br0.x, p0.y + height, br0.z)
		var tl1 := Vector3(bl1.x, p1.y + height, bl1.z)
		var tr1 := Vector3(br1.x, p1.y + height, br1.z)

		# A linear OSM way (fence/wall) has no inherent CW/CCW orientation, so
		# each face is emitted via add_quad_facing with an explicit desired
		# normal. This keeps the winding handling consistent with the rest of
		# the codebase and avoids the previous double-sided geometry.
		var left_normal := -right.normalized()
		var right_normal := right.normalized()

		# Top face — faces up
		PolygonUtils.add_quad_facing(st, tl0, tr0, tr1, tl1, Vector3.UP)
		# Left face — faces left (-right)
		PolygonUtils.add_quad_facing(st, bl0, tl0, tl1, bl1, left_normal)
		# Right face — faces right
		PolygonUtils.add_quad_facing(st, br0, tr0, tr1, br1, right_normal)

		# Start cap (first segment only) — faces back along the way
		if i == 0:
			PolygonUtils.add_quad_facing(st, bl0, br0, tr0, tl0, -forward)

		# End cap (last segment only) — faces forward along the way
		if i == points.size() - 2:
			PolygonUtils.add_quad_facing(st, bl1, br1, tr1, tl1, forward)

	mesh_instance.mesh = st.commit()
	root.add_child(mesh_instance)

	# Place label at the midpoint of the way
	@warning_ignore("integer_division")
	var mid_index := points.size() / 2
	var mid_point := points[mid_index]
	_add_debug_label_at(root, def, way.tags, mid_point)

	return root

func _add_debug_label(parent: Node3D, def: Dictionary, tags: Dictionary) -> void:
	_add_debug_label_at(parent, def, tags, Vector3.ZERO)

func _add_debug_label_at(parent: Node3D, def: Dictionary, tags: Dictionary, pos: Vector3) -> void:
	var label := Label3D.new()
	label.name = "DebugLabel"
	var text: String = def["label"]
	if tags.has("name"):
		text += " - " + tags["name"]
	label.text = text
	label.font_size = 32
	label.pixel_size = 0.01
	label.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	# Respect scene depth so labels are occluded by buildings/terrain in front
	# of them instead of shining through. Disabling this draws on top of all geometry.
	label.no_depth_test = false
	label.modulate = Color(1.0, 1.0, 1.0, 0.9)
	label.outline_modulate = Color(0.0, 0.0, 0.0, 0.8)
	label.outline_size = 8
	# pos.y carries the terrain elevation at this point (0 in a flat world), so
	# the label must be lifted relative to the ground, not world zero, or it
	# sinks into the terrain wherever elevation is applied.
	var label_y: float = pos.y + def["y_offset"] * 2.0 + 1.0
	label.position = Vector3(pos.x, label_y, pos.z)
	label.visible = show_debug_labels
	parent.add_child(label)
	label.add_to_group("debug_labels")

func _load_scene(path: String) -> PackedScene:
	if _scene_cache.has(path):
		return _scene_cache[path]
	if ResourceLoader.exists(path):
		var scene: PackedScene = load(path)
		_scene_cache[path] = scene
		return scene
	push_warning("OSMAssetPlacer: Scene not found: %s, using placeholder" % path)
	return null

func _find_asset_def(tags: Dictionary) -> Dictionary:
	for tag_key: String in ASSET_DEFS:
		if tags.has(tag_key):
			var tag_value: String = tags[tag_key]
			var sub: Dictionary = ASSET_DEFS[tag_key]
			# A barrier=wall can be refined by a wall=* subtag (e.g.
			# wall=noise_barrier). Prefer the more specific subtag definition
			# when one exists so noise barriers get their taller geometry.
			if tag_key == "barrier" and tag_value == "wall" and tags.has("wall"):
				var wall_value: String = tags["wall"]
				if sub.has(wall_value):
					return sub[wall_value]
			var base: Dictionary = {}
			if sub.has(tag_value):
				base = sub[tag_value]
			elif sub.has("*"):
				base = sub["*"]
			if not base.is_empty():
				return _apply_support_variant(base, tags)
	return {}


## If a def carries a `support` variant map and the node has a matching
## `support=*` tag, merge that variant over the base def and return the result.
## Variants override only the keys they name (e.g. add a `scene`) and inherit
## everything else (`light`, `label`, head offsets), so a bent-mast lamp stays a
## light-emitting street lamp. The `support` key itself is stripped from the
## returned def so downstream code never sees the variant table. Returns the base
## unchanged when there is no variant table or no matching support value.
func _apply_support_variant(base: Dictionary, tags: Dictionary) -> Dictionary:
	if not base.has("support") or not tags.has("support"):
		return base
	var variants: Dictionary = base["support"]
	var support_value: String = tags["support"]
	if not variants.has(support_value):
		# Unknown support style: fall back to the base lamp, minus the table.
		var fallback := base.duplicate()
		fallback.erase("support")
		return fallback
	var merged := base.duplicate()
	merged.erase("support")
	for key: String in variants[support_value]:
		merged[key] = variants[support_value][key]
	return merged
