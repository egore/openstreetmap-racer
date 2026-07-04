extends GdUnitTestSuite

## Unit tests for CarPaint — the PBR material pass for the player car.
##
## CarPaint is a plain RefCounted whose logic is pure: map a surface's material
## *name* to a freshly built PBR material, and (for apply_to) walk a mesh subtree
## setting surface override materials. So the tests build materials directly and
## drive apply_to against a synthetic MeshInstance3D with named surfaces — no
## car.blend, no scene tree, no renderer.
##
## Constants are read off the class so expectations track the source.

const DEFAULT := CarPaint.DEFAULT_PAINT_COLOR


func _painter() -> CarPaint:
	return CarPaint.new()


# ─── Name resolution ─────────────────────────────────────────────────────────

## Each known surface name resolves to a non-null material.
func test_known_names_resolve() -> void:
	var p := _painter()
	for name: String in ["Paintjob", "Glas", "Glass", "Chrome", "Rear Lights", "Tire"]:
		assert_object(p.material_for(name)) \
			.override_failure_message("'%s' resolves to a material" % name).is_not_null()


## An unrecognised surface name resolves to null so the caller leaves it alone.
func test_unknown_name_returns_null() -> void:
	var p := _painter()
	assert_object(p.material_for("SomethingElse")) \
		.override_failure_message("unknown surface names are left untouched").is_null()
	assert_object(p.material_for("")).is_null()


## Names match case-insensitively and ignore surrounding whitespace.
func test_name_matching_is_case_and_space_insensitive() -> void:
	var p := _painter()
	assert_object(p.material_for("  PAINTJOB ")) \
		.override_failure_message("paint name is case/space insensitive").is_not_null()
	assert_object(p.material_for("cHrOmE")).is_not_null()


## Both the German-export ("Glas") and English ("Glass") spellings map to glass.
func test_both_glass_spellings_resolve() -> void:
	var p := _painter()
	var a := p.material_for("Glas")
	var b := p.material_for("Glass")
	assert_object(a).is_not_null()
	assert_object(b).is_not_null()
	if a != null:
		assert_str(a.resource_name).is_equal("CarPaint_Glass")


# ─── Paint (hero material) ───────────────────────────────────────────────────

## The body paint is a metallic base coat WITH a clear coat — the two-layer
## highlight that makes it read as real car paint.
func test_paint_is_metallic_with_clearcoat() -> void:
	var p := _painter()
	var m := p.build_paint_material()
	assert_float(m.metallic) \
		.override_failure_message("paint is strongly metallic").is_greater(0.5)
	assert_bool(m.clearcoat_enabled) \
		.override_failure_message("paint has a clear coat layer").is_true()
	assert_float(m.clearcoat_roughness) \
		.override_failure_message("the clear coat is smooth (tight glint)").is_less(0.2)
	# The base coat is glossy but not a perfect mirror — the flake softens it.
	assert_float(m.roughness).is_between(0.05, 0.6)


## The paint colour is the requested colour; default and custom both honoured.
func test_paint_colour_applied() -> void:
	var p := _painter()
	var def := p.build_paint_material()
	assert_vector(Vector3(def.albedo_color.r, def.albedo_color.g, def.albedo_color.b)) \
		.override_failure_message("default paint uses DEFAULT_PAINT_COLOR") \
		.is_equal_approx(Vector3(DEFAULT.r, DEFAULT.g, DEFAULT.b), Vector3.ONE * 0.001)

	var blue := Color(0.05, 0.1, 0.7)
	var custom := p.build_paint_material(blue)
	assert_vector(Vector3(custom.albedo_color.r, custom.albedo_color.g, custom.albedo_color.b)) \
		.override_failure_message("custom paint colour is applied") \
		.is_equal_approx(Vector3(blue.r, blue.g, blue.b), Vector3.ONE * 0.001)


## material_for("Paintjob", colour) recolours the paint too (not just the builder).
func test_material_for_paint_honours_colour() -> void:
	var p := _painter()
	var green := Color(0.1, 0.6, 0.15)
	var m := p.material_for("Paintjob", green) as StandardMaterial3D
	assert_object(m).is_not_null()
	if m != null:
		assert_vector(Vector3(m.albedo_color.r, m.albedo_color.g, m.albedo_color.b)) \
			.is_equal_approx(Vector3(green.r, green.g, green.b), Vector3.ONE * 0.001)


# ─── Other surfaces ──────────────────────────────────────────────────────────

## Glass is smooth and semi-transparent.
func test_glass_is_smooth_and_transparent() -> void:
	var m := _painter().build_glass_material()
	assert_float(m.roughness).override_failure_message("glass is near-mirror smooth").is_less(0.1)
	assert_int(m.transparency) \
		.override_failure_message("glass uses alpha transparency") \
		.is_equal(BaseMaterial3D.TRANSPARENCY_ALPHA)
	assert_float(m.albedo_color.a).override_failure_message("glass is see-through").is_less(1.0)


## Chrome is a near-perfect mirror: full metallic, very low roughness.
func test_chrome_is_mirror() -> void:
	var m := _painter().build_chrome_material()
	assert_float(m.metallic).is_greater(0.9)
	assert_float(m.roughness).is_less(0.15)


## Rear lights self-illuminate so they bloom under post-processing at night.
func test_lights_emit() -> void:
	var m := _painter().build_lights_material()
	assert_bool(m.emission_enabled).override_failure_message("rear lights glow").is_true()
	assert_float(m.emission_energy_multiplier).is_greater(0.0)


## Tyres are matte, non-metallic rubber.
func test_tire_is_matte_rubber() -> void:
	var m := _painter().build_tire_material()
	assert_float(m.metallic).is_equal_approx(0.0, 0.001)
	assert_float(m.roughness).override_failure_message("rubber is rough/matte").is_greater(0.7)


# ─── apply_to over a mesh subtree ────────────────────────────────────────────

## Builds a MeshInstance3D whose surfaces carry the given material names, using
## an ArrayMesh with one (degenerate) surface per name so get_surface_count and
## get_active_material line up with what apply_to reads.
func _mesh_with_surfaces(names: Array) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var arr_mesh := ArrayMesh.new()
	for n: String in names:
		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		# A single triangle is enough to make a valid surface.
		arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([
			Vector3.ZERO, Vector3.RIGHT, Vector3.UP,
		])
		arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		var src_mat := StandardMaterial3D.new()
		src_mat.resource_name = n
		var idx := arr_mesh.get_surface_count() - 1
		arr_mesh.surface_set_material(idx, src_mat)
	mi.mesh = arr_mesh
	return mi


## apply_to reassigns exactly the recognised surfaces and leaves unknown ones
## with no override, and it returns the count of surfaces it touched.
func test_apply_to_replaces_only_known_surfaces() -> void:
	var mi := _mesh_with_surfaces(["Glas", "Paintjob", "Rear Lights", "Chrome", "Mystery"])
	add_child(mi)
	var p := _painter()

	var count := p.apply_to(mi)
	# Four of the five are known (Glas, Paintjob, Rear Lights, Chrome).
	assert_int(count).override_failure_message("apply_to touches the 4 known surfaces").is_equal(4)

	# Known surfaces get an override; the mystery one keeps none.
	assert_object(mi.get_surface_override_material(0)).override_failure_message("Glas overridden").is_not_null()
	assert_object(mi.get_surface_override_material(1)).override_failure_message("Paintjob overridden").is_not_null()
	assert_object(mi.get_surface_override_material(2)).override_failure_message("Rear Lights overridden").is_not_null()
	assert_object(mi.get_surface_override_material(3)).override_failure_message("Chrome overridden").is_not_null()
	assert_object(mi.get_surface_override_material(4)).override_failure_message("unknown surface left alone").is_null()

	mi.free()


## The Paintjob surface receives the requested paint colour through apply_to.
func test_apply_to_paints_body_colour() -> void:
	var mi := _mesh_with_surfaces(["Paintjob"])
	add_child(mi)
	var orange := Color(0.9, 0.4, 0.05)

	_painter().apply_to(mi, orange)
	var body := mi.get_surface_override_material(0) as StandardMaterial3D
	assert_object(body).is_not_null()
	if body != null:
		assert_vector(Vector3(body.albedo_color.r, body.albedo_color.g, body.albedo_color.b)) \
			.override_failure_message("apply_to paints the body the requested colour") \
			.is_equal_approx(Vector3(orange.r, orange.g, orange.b), Vector3.ONE * 0.001)
	mi.free()


## apply_to recurses into child MeshInstance3Ds (body + wheels under one root).
func test_apply_to_recurses_into_children() -> void:
	var root := Node3D.new()
	var body := _mesh_with_surfaces(["Paintjob"])
	var wheel := _mesh_with_surfaces(["Tire", "Chrome"])
	root.add_child(body)
	root.add_child(wheel)
	add_child(root)

	var count := _painter().apply_to(root)
	# 1 body surface + 2 wheel surfaces = 3.
	assert_int(count).override_failure_message("apply_to walks the whole subtree").is_equal(3)
	assert_object(wheel.get_surface_override_material(0)).override_failure_message("tyre painted").is_not_null()
	assert_object(wheel.get_surface_override_material(1)).override_failure_message("wheel chrome painted").is_not_null()

	root.free()


## A mesh-less node in the tree is skipped without error.
func test_apply_to_ignores_meshless_nodes() -> void:
	var root := Node3D.new()
	add_child(root)
	var count := _painter().apply_to(root)
	assert_int(count).override_failure_message("nothing to paint on an empty node").is_equal(0)
	root.free()
