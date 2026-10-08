extends GdUnitTestSuite

const ROAD := preload("res://scripts/shaders/asphalt.gdshader")
const JUNCTION := preload("res://scripts/shaders/asphalt_junction.gdshader")

func _default_value(shader: Shader, parameter: String) -> float:
	# The headless dummy renderer does not expose shader uniform defaults.
	var expression := RegEx.new()
	expression.compile("uniform float " + parameter + "[^;]*= ([0-9.]+);")
	var result := expression.search(shader.code)
	assert_object(result).is_not_null()
	return result.get_string(1).to_float() if result != null else NAN

func test_road_and_junction_use_identical_detail_defaults() -> void:
	for parameter in ["grain_scale", "patch_scale", "albedo_variation", "roughness_base", "roughness_variation", "bump_strength"]:
		assert_float(_default_value(ROAD, parameter)).is_equal(_default_value(JUNCTION, parameter))

func test_asphalt_aggregate_is_centimetre_scale_with_subtle_bump() -> void:
	assert_float(_default_value(ROAD, "grain_scale")).is_between(0.01, 0.03)
	assert_float(_default_value(ROAD, "bump_strength")).is_less_equal(0.15)

func test_both_shaders_filter_subpixel_octaves() -> void:
	for shader in [ROAD, JUNCTION]:
		assert_str(shader.code).contains("dFdx(grain_uv)")
		assert_str(shader.code).contains("dFdy(grain_uv)")
		assert_str(shader.code).contains("smoothstep(0.25, 1.0, footprint)")
		assert_str(shader.code).contains("footprint *= 2.0")
