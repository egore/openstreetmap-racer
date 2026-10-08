extends GdUnitTestSuite

## ProfileStore: saved best scores and lifetime stats.

const ProfileStoreScript := preload("res://scripts/profile_store.gd")
const PATH := "user://_test_profile.cfg"


func before_test() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func after() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PATH))


func test_a_fresh_profile_is_empty() -> void:
	var p := ProfileStoreScript.new(PATH)
	assert_int(p.best_score("kudos_attack")).is_equal(0)
	assert_int(p.runs("kudos_attack")).is_equal(0)
	assert_float(p.total_distance_m()).is_equal(0.0)


func test_only_a_higher_score_is_a_new_best() -> void:
	var p := ProfileStoreScript.new(PATH)
	assert_bool(p.submit_score("kudos_attack", 500)).is_true()
	assert_bool(p.submit_score("kudos_attack", 300)).is_false()
	assert_bool(p.submit_score("kudos_attack", 500)).is_false()
	assert_bool(p.submit_score("kudos_attack", 501)).is_true()
	assert_int(p.best_score("kudos_attack")).is_equal(501)
	assert_int(p.runs("kudos_attack")).is_equal(4)


func test_a_scoreless_first_run_is_not_a_best() -> void:
	var p := ProfileStoreScript.new(PATH)
	assert_bool(p.submit_score("kudos_attack", 0)).is_false()


func test_records_survive_a_save_and_reload() -> void:
	var p := ProfileStoreScript.new(PATH)
	p.submit_score("kudos_attack", 1234)
	p.add_distance(1500.0)
	p.add_distance(250.0)
	assert_int(p.save()).is_equal(OK)

	var reloaded := ProfileStoreScript.new(PATH)
	assert_int(reloaded.best_score("kudos_attack")).is_equal(1234)
	assert_int(reloaded.runs("kudos_attack")).is_equal(1)
	assert_float(reloaded.total_distance_m()).is_equal_approx(1750.0, 0.001)
