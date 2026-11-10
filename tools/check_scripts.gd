extends SceneTree
## Loads every GDScript in the project so the compiler runs on it.
## `godot --headless --script tools/check_scripts.gd` exits non-zero if any
## script fails to compile. Runtime-only type errors surface here too, which is
## exactly what the 4.3 compiler catches and a third-party linter does not.

func _init() -> void:
	var files := _collect("res://scripts")
	files.append_array(_collect("res://tests"))
	var bad := 0
	for f in files:
		var res := load(f)
		if res == null:
			print("CHECK_FAIL: ", f)
			bad += 1
		else:
			print("CHECK_OK: ", f)
	print("CHECK_RESULT: %d failed of %d" % [bad, files.size()])
	quit(1 if bad > 0 else 0)


func _collect(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		var full := dir_path.path_join(name)
		if dir.current_is_dir():
			out.append_array(_collect(full))
		elif name.ends_with(".gd"):
			out.append(full)
		name = dir.get_next()
	dir.list_dir_end()
	return out
