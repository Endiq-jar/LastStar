extends SceneTree
## Loads every GDScript in the project so the 4.3 compiler runs on it.
##
## Uses absolute filesystem paths on purpose: in `--script` mode the resource
## filesystem is not the project one, so DirAccess.open("res://scripts")
## returns null and the check silently validates nothing.
##
## Does NOT call quit(): 4.3 can drop buffered output when quitting from _init.
## The wrapper greps for CHECK_RESULT and treats its absence as a failure.

func _init() -> void:
	var root := ProjectSettings.globalize_path("res://")
	print("CHECK_ROOT: ", root)
	var files := _collect(root.path_join("scripts"))
	files.append_array(_collect(root.path_join("tests")))
	var bad := 0
	for f in files:
		var res := load(f)
		if res == null:
			print("CHECK_FAIL: ", f)
			bad += 1
	print("CHECK_RESULT: %d failed of %d" % [bad, files.size()])
	if bad > 0:
		OS.set_exit_code(1)


func _collect(dir_path: String) -> Array:
	var out: Array = []
	var dir := DirAccess.open(dir_path)
	if dir == null:
		print("CHECK_WARN: cannot open ", dir_path)
		return out
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var full := dir_path.path_join(entry)
		if dir.current_is_dir():
			out.append_array(_collect(full))
		elif entry.ends_with(".gd"):
			out.append(full)
		entry = dir.get_next()
	dir.list_dir_end()
	return out
