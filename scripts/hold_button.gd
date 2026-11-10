class_name HoldButton
extends RefCounted
## Press-immediate, hold-to-repeat button behaviour.
##
## Godot's `pressed` signal only fires on RELEASE, which makes an action button
## feel unresponsive: you press Slash, nothing happens until you lift your
## finger. On a phone that reads as lag. This binds a button so that:
##
##   * the action fires the instant the button goes down;
##   * holding keeps firing at a fixed interval (1 s by default);
##   * releasing stops the repeat immediately;
##   * the whole button rectangle is clickable, not just the pixels where a
##     child control happens to sit.
##
## It is a plain helper rather than a custom Control so it can be applied to any
## existing Button without changing the scene tree.

const DEFAULT_INTERVAL := 1.0

## Bind `button` to `action` (a Callable taking no arguments).
## Returns the repeating timer so callers can tweak it.
static func bind(button: BaseButton, action: Callable,
		interval: float = DEFAULT_INTERVAL) -> Timer:
	# The entire rect must accept input. A Button already does, but any child
	# that forgot MOUSE_FILTER_IGNORE would carve a dead zone out of it - and
	# the icon TextureRect and caption Label sit exactly where the thumb lands.
	button.mouse_filter = Control.MOUSE_FILTER_STOP
	_make_children_transparent(button)

	var timer := Timer.new()
	timer.name = "HoldRepeat"
	timer.one_shot = false
	timer.wait_time = maxf(0.05, interval)
	timer.autostart = false
	button.add_child(timer)

	# Fire immediately on press, then let the timer take over for the repeat.
	button.button_down.connect(_fire.bind(button, action, timer))

	# Stop repeating the moment the finger lifts, leaves, or the button is
	# cancelled by the UI. All three paths must be covered or the action keeps
	# firing after release, which is far worse than not repeating at all.
	button.button_up.connect(timer.stop)
	button.mouse_exited.connect(_stop_if_not_held.bind(button, timer))
	button.focus_exited.connect(timer.stop)
	button.tree_exiting.connect(timer.stop)

	timer.timeout.connect(_tick.bind(button, action, timer))

	return timer


static func _fire(button: BaseButton, action: Callable, timer: Timer) -> void:
	## Press: run the action once and start repeating.
	if button.disabled:
		return
	action.call()
	timer.start()


static func _tick(button: BaseButton, action: Callable, timer: Timer) -> void:
	## Repeat: run again every `interval` seconds while still held.
	if button.disabled or not button.is_visible_in_tree() or not button.button_pressed:
		timer.stop()
		return
	action.call()


static func _stop_if_not_held(button: BaseButton, timer: Timer) -> void:
	# mouse_exited fires on a drag-out, which should stop the repeat but must not
	# stop it during a normal press-and-hold inside the button.
	if not button.button_pressed:
		timer.stop()


static func _make_children_transparent(node: Node) -> void:
	for child in node.get_children():
		if child is Control:
			(child as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
		_make_children_transparent(child)
