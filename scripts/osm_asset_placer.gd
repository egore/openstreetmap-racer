class_name OSMAssetPlacer
extends RefCounted

## Places placeholder 3D assets for OSM nodes based on their tags.
## Each asset type is a simple colored box/shape with a label.

# Asset definitions: tag_key -> { tag_value -> { color, size, y_offset, label, scene (optional) } }
# If tag_value is "*", matches any value for that key.
# If "scene" is set, that PackedScene is instanced instead of a placeholder box.

var _scene_cache: Dictionary = {}  # path -> PackedScene
const ASSET_DEFS := {
	"highway": {
		"traffic_signals": { "color": Color(0.1, 0.7, 0.1), "size": Vector3(0.3, 3.0, 0.3), "y_offset": 1.5, "label": "Traffic Light" },
		"street_lamp": { "color": Color(0.8, 0.8, 0.2), "size": Vector3(0.15, 4.0, 0.15), "y_offset": 2.0, "label": "Street Lamp" },
		"bus_stop": { "color": Color(0.2, 0.4, 0.8), "size": Vector3(0.8, 2.5, 0.3), "y_offset": 1.25, "label": "Bus Stop" },
		"crossing": { "color": Color(1.0, 1.0, 1.0), "size": Vector3(2.0, 0.05, 2.0), "y_offset": 0.025, "label": "Crossing" },
		"stop": { "color": Color(0.9, 0.1, 0.1), "size": Vector3(0.5, 2.0, 0.05), "y_offset": 1.0, "label": "Stop Sign" },
		"give_way": { "color": Color(0.9, 0.9, 0.1), "size": Vector3(0.5, 2.0, 0.05), "y_offset": 1.0, "label": "Give Way" },
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
	},
	"barrier": {
		"bollard": { "color": Color(0.5, 0.5, 0.5), "size": Vector3(0.2, 0.8, 0.2), "y_offset": 0.4, "label": "Bollard" },
		"gate": { "color": Color(0.4, 0.3, 0.2), "size": Vector3(3.0, 1.5, 0.1), "y_offset": 0.75, "label": "Gate" },
		"fence": { "color": Color(0.5, 0.4, 0.3), "size": Vector3(0.1, 1.5, 0.1), "y_offset": 0.75, "label": "Fence Post" },
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
		"*": { "color": Color(0.9, 0.9, 0.9), "size": Vector3(0.6, 2.0, 0.05), "y_offset": 1.5, "label": "Traffic Sign" },
	},
}

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

	return root

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
			if sub.has(tag_value):
				return sub[tag_value]
			elif sub.has("*"):
				return sub["*"]
	return {}
