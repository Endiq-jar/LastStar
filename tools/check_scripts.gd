extends SceneTree
## Loads every GDScript in the project so the 4.3 compiler runs on it.
##
## Deliberately does NOT call quit(): in Godot 4.3, script errors are printed
## during reload but SceneTree.quit() from _init() can swallow the completion
## output. The wrapper script greps for CHECK_RESULT and treats a missing one
## as a failure.

func _init() -> void:
	var files := _collect("res://scripts")
	files.append_array(_collect("res://tests"))
	files.append_array(_collect("res://tools"))
	var bad := 0
	for f in files:
		if f.ends_with("check_scripts.gd"):
			continue
		var res := load(f)
		if res == null:
			print("CHECK_FAIL: ", f)
			bad += 1
		else:
			print("CHECK_OK: ", f)
	print("CHECK_RESULT: %d failed of %d" % [bad, files.size()])
	if bad > 0:
		OS.set_exit_code(1)


func _collect(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			out.append_array(_collect(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out
