extends Control
## Offline adventure screens. No real-money purchases or network accounts.

signal closed
const UI := preload("res://scripts/ui_style.gd")
const TABS := ["Character", "Inventory", "Quests", "Wish", "Level Up", "Shop", "Profile", "Settings", "Story", "Wardrobe", "Dialogue"]
const HOME_TABS := ["Wardrobe", "Profile", "Settings", "Shop"]
const GAME_TABS := ["Inventory", "Character", "Quests", "Wish", "Level Up", "Story"]
var home_mode := false

var _body: VBoxContainer
var _header: Label
var _balance: Label
var _tab := "Character"
var _status := ""
var _selected_item := ""
var _sort_alphabetical := false
var _binding_action := ""
const ITEM_ICONS := {
	"Potion": preload("res://icons/items/potion.svg"),
	"Moonstone": preload("res://icons/items/moonstone.svg"),
	"Starflower": preload("res://icons/items/starflower.svg"),
	"Sunshard": preload("res://icons/items/sunshard.svg"),
	"Stormglass": preload("res://icons/items/stormglass.svg"),
}


func _ready() -> void:
	name = "AdventureMenu"
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	_build()
	Game.collection_changed.connect(_refresh)


func _build() -> void:
	var dim := ColorRect.new()
	dim.color = Color(0.025, 0.02, 0.09, 0.86)
	dim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(dim)
	var panel := PanelContainer.new()
	panel.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	panel.offset_left = 24
	panel.offset_top = 20
	panel.offset_right = -24
	panel.offset_bottom = -20
	panel.add_theme_stylebox_override("panel", UI.panel(18.0, 0.97))
	add_child(panel)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 10)
	panel.add_child(layout)
	var bar := HBoxContainer.new()
	layout.add_child(bar)
	_header = Label.new()
	_header.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_header.add_theme_font_size_override("font_size", 25)
	_header.add_theme_color_override("font_color", UI.TEXT)
	bar.add_child(_header)
	_balance = Label.new()
	_balance.add_theme_font_size_override("font_size", 16)
	_balance.add_theme_color_override("font_color", UI.ACCENT)
	bar.add_child(_balance)
	var close := Button.new()
	close.text = "✕"
	close.custom_minimum_size = Vector2(48, 42)
	UI.button(close)
	close.pressed.connect(close_menu)
	bar.add_child(close)
	var tabs: Array = HOME_TABS if home_mode else GAME_TABS
	var rows := 1 if home_mode else 2
	for row_index in range(rows):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		layout.add_child(row)
		var start := row_index * 4
		for i in range(start, mini(start + 4, tabs.size())):
			var tab := Button.new()
			tab.text = tabs[i]
			tab.custom_minimum_size = Vector2(0, 40)
			tab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			tab.add_theme_font_size_override("font_size", 15)
			UI.button(tab)
			tab.pressed.connect(_select.bind(tabs[i]))
			row.add_child(tab)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	layout.add_child(scroll)
	_body = VBoxContainer.new()
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.add_theme_constant_override("separation", 10)
	scroll.add_child(_body)


func open_menu(tab: String = "Character") -> void:
	if not TABS.has(tab):
		tab = "Character"
	_tab = tab
	_status = ""
	visible = true
	if not home_mode:
		Game.set_paused(true)
	_refresh()


func close_menu() -> void:
	_binding_action = ""
	visible = false
	if not home_mode:
		Game.set_paused(false)
	else:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	closed.emit()


func _select(tab: String) -> void:
	_tab = tab
	_status = ""
	_refresh()


func _line(text: String, font_size: int = 17, color: Color = UI.TEXT) -> void:
	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	_body.add_child(label)


func _action(text: String, callback: Callable, enabled: bool = true) -> void:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 44)
	button.alignment = HORIZONTAL_ALIGNMENT_LEFT
	button.disabled = not enabled
	UI.button(button)
	button.pressed.connect(callback)
	_body.add_child(button)


func _refresh() -> void:
	if _body == null or not visible:
		return
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	_header.text = "✦  %s" % _tab.to_upper()
	_balance.text = "✧ %d starlight    ◇ %d coins     " % [Game.starlight, Game.coins]
	match _tab:
		"Character": _character()
		"Inventory": _inventory()
		"Quests": _quests()
		"Wish": _wish()
		"Level Up": _level_up()
		"Shop": _shop()
		"Profile": _profile()
		"Settings": _settings()
		"Story": _story()
		"Wardrobe": _wardrobe()
		"Dialogue": _dialogue()
	if _status != "":
		_line(_status, 16, UI.ACCENT)


func _character() -> void:
	var current := Game.character()
	_line("%s  ·  %s" % [current["name"], current["title"]], 27, UI.ACCENT)
	_line("%s   |   Level %d / 10   |   %s" % [current["element"], Game.character_levels[Game.party_index], current["weapon"]])
	_line("HP %.0f / %.0f     ATK %.1f     Energy %.0f / %.0f" % [Game.current_hp(), Game.max_hp(), Game.attack_power(), Game.energy, Game.MAX_ENERGY])
	_line("Skill: %s     Burst: %s" % [current["skill_name"], current["burst_name"]])
	_line("TRAVELLING PARTY", 14, UI.ACCENT)
	for i in range(Game.PARTY.size()):
		var data: Dictionary = Game.PARTY[i]
		_action("%s   ·   %s   ·   Level %d%s" % [data["name"], data["element"], Game.character_levels[i], "   (active)" if i == Game.party_index else ""], _switch.bind(i))


func _switch(index: int) -> void:
	Game.switch_character(index)
	_refresh()


func _inventory() -> void:
	var used: int = Game.inventory_used()
	var capacity: int = Game.inventory_capacity()
	_line("INVENTORY   %d / %d SLOTS" % [used, capacity], 22, UI.ACCENT)
	_line("Select an icon to use or drop an item. Each item occupies one slot.")
	if used > capacity:
		_line("Your existing collection exceeds capacity. No items were lost.", 16, UI.ACCENT)
	_action("Sort: %s  ·  tap to change" % ("Name" if _sort_alphabetical else "Type"), _toggle_sort)
	var entries: Array[String] = []
	for i in range(Game.potions):
		entries.append("Potion")
	for item in Game.WISH_ITEMS:
		for i in range(maxi(0, int(Game.collectibles.get(item, 0)))):
			entries.append(str(item))
	if _sort_alphabetical:
		entries.sort()
	if not entries.has(_selected_item):
		_selected_item = ""
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	_body.add_child(grid)
	for i in range(maxi(capacity, used)):
		var slot := Button.new()
		slot.custom_minimum_size = Vector2(80, 64)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		UI.button(slot)
		if i < entries.size():
			var item: String = entries[i]
			slot.icon = ITEM_ICONS[item]
			slot.expand_icon = true
			slot.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
			slot.tooltip_text = item
			slot.pressed.connect(_select_item.bind(item))
		else:
			slot.disabled = true
			slot.add_theme_stylebox_override("disabled", UI.panel(8.0, 0.55))
			slot.tooltip_text = "Empty slot"
		grid.add_child(slot)
	if _selected_item != "":
		_line("Selected: %s" % _selected_item, 17, UI.ACCENT)
		if _selected_item == "Potion":
			_action("Use healing potion", _use_potion, Game.current_hp() < Game.max_hp())
		_action("Drop one %s into the world" % _selected_item, _drop_selected, get_tree().get_first_node_in_group("player") != null)


func _toggle_sort() -> void:
	_sort_alphabetical = not _sort_alphabetical
	_refresh()


func _select_item(item: String) -> void:
	_selected_item = item
	_refresh()


func _drop_selected() -> void:
	var player := get_tree().get_first_node_in_group("player") as Node3D
	if player == null or _selected_item == "":
		return
	var position := player.global_position + player.global_basis.z * 3.0
	var world := player.get_parent()
	var terrain := world.get_node_or_null("Terrain")
	if terrain != null:
		position.y = float(terrain.call("get_height_at", position.x, position.z)) + 0.5
	var id: String = Game.drop_item(_selected_item, position)
	if id != "" and world.has_method("spawn_dropped_item"):
		world.call("spawn_dropped_item", id)
		_status = "Dropped nearby. Walk over it to pick it up."
	else:
		_status = "Unable to drop item."
	_refresh()


func _use_potion() -> void:
	_status = "Potion used." if Game.use_potion() else "No potion needed or available."
	_refresh()


func _quests() -> void:
	_line("STAR GUARD JOURNAL", 23, UI.ACCENT)
	var story := Game.guard_story
	if not bool(story.get("seal_accepted", false)):
		_line("Main · A Light Remembered: speak with Star Guard Ilyra near the starting shore.")
	elif bool(story.get("seal_done", false)):
		_line("Main · A Light Remembered: completed. Reward: Stone Bulwark.")
	else:
		_line("Main · A Light Remembered: recover a star sigil (%d / 1), then return to Ilyra." % mini(Game.sigils_collected, 1))
	if bool(story.get("hollow_accepted", false)):
		_line("Side · Hollow Signs: %s" % ("completed. Reward: Arc Lance." if bool(story.get("hollow_done", false)) else "defeat three slimes (%d / 3), then return to Ilyra." % mini(Game.slimes_defeated, 3)))
	_line("THE VALLEY REMEMBERS", 23, UI.ACCENT)
	_line("Recover star sigils: %d / %d" % [Game.sigils_collected, Game.TOTAL_SIGILS])
	_line("Clear wandering slimes: %d / 6" % mini(Game.slimes_defeated, 6))
	_line("Activate a waypoint: %s" % ("Complete" if Game.waypoints_activated > 0 else "In progress"))
	_line("Current objective", 14, UI.ACCENT)
	_line(Game.quest_text)
	_line("Sigils, slimes, and new waypoints award offline currency as you play.")


func _wish() -> void:
	_line("STARFALL WISH", 26, UI.ACCENT)
	_line("Spend 30 earned starlight for one random collectible. Every item has an equal chance; duplicates are kept. No real money or online purchases.")
	_line("Possible treasures: %s" % ", ".join(PackedStringArray(Game.WISH_ITEMS)))
	_action("✦  Make one wish   ·   30 starlight", _make_wish, Game.starlight >= 30 and Game.inventory_used() < Game.inventory_capacity())


func _make_wish() -> void:
	var result := Game.make_wish()
	_status = "You received %s!" % result if result != "" else "Not enough starlight."
	_refresh()


func _level_up() -> void:
	_line("CHARACTER PROGRESSION", 23, UI.ACCENT)
	_line("Levels increase attack power by 12% each. Maximum level: 10.")
	for i in range(Game.PARTY.size()):
		var level: int = Game.character_levels[i]
		var cost := level * 50
		var suffix := "MAX LEVEL" if level >= 10 else "%d coins" % cost
		_action("%s   ·   Lv. %d   →   %s" % [Game.PARTY[i]["name"], level, suffix], _upgrade.bind(i), level < 10 and Game.coins >= cost)


func _upgrade(index: int) -> void:
	_status = "%s levelled up!" % Game.PARTY[index]["name"] if Game.upgrade_character(index) else "Not enough coins or already at max level."
	_refresh()


func _shop() -> void:
	_line("THE WANDERER'S SHOP", 23, UI.ACCENT)
	_line("Offline supplies only. Coins are earned by playing.")
	_action("Healing potion   ·   25 coins", _buy_potion, Game.coins >= 25 and Game.inventory_used() < Game.inventory_capacity())
	_line("Potions require an empty inventory slot.")
	for i in range(1, Game.BACKPACK_NAMES.size()):
		var owned: bool = Game.owned_backpacks.has(i)
		_action("%s  ·  +%d slots  ·  %s" % [Game.BACKPACK_NAMES[i], Game.BACKPACK_BONUS[i], "Owned" if owned else "%d coins" % Game.BACKPACK_PRICES[i]], _buy_backpack.bind(i), not owned and Game.coins >= Game.BACKPACK_PRICES[i])


func _wardrobe() -> void:
	_line("OUTFIT COLOUR", 23, UI.ACCENT)
	for i in range(3):
		_action("%s%s" % [["Original", "Moonlit blue", "Rose dusk"][i], "  ·  Equipped" if i == Game.outfit_style else ""], _set_outfit.bind(i), i != Game.outfit_style)
	_line("BACKPACKS", 23, UI.ACCENT)
	_line("Equipping a backpack increases inventory capacity. Buy backpacks in the home shop.")
	for i in Game.owned_backpacks:
		var equipped: bool = i == Game.equipped_backpack
		var fits: bool = Game.inventory_used() <= 10 + Game.BACKPACK_BONUS[i]
		var suffix := "Equipped" if equipped else ("Equip" if fits else "Too many items")
		_action("%s  ·  %d slots  ·  %s" % [Game.BACKPACK_NAMES[i], 10 + Game.BACKPACK_BONUS[i], suffix], _equip_backpack.bind(i), not equipped and fits)


func _set_outfit(index: int) -> void:
	Game.set_outfit_style(index)
	_status = "Outfit colour changed."
	_refresh()


func _equip_backpack(index: int) -> void:
	_status = "Backpack equipped." if Game.equip_backpack(index) else "Inventory does not fit."
	_refresh()


func _buy_backpack(index: int) -> void:
	_status = "Backpack purchased. Equip it in Wardrobe." if Game.buy_backpack(index) else "Unable to buy backpack."
	_refresh()


func _buy_potion() -> void:
	_status = "Potion added to your inventory." if Game.buy_potion() else "Not enough coins."
	_refresh()


func _profile() -> void:
	_line("THE TRAVELLER", 26, UI.ACCENT)
	_line("Active character: %s  ·  Level %d" % [Game.character()["name"], Game.character_levels[Game.party_index]])
	_line("This expedition: %d sigils  ·  %d slimes  ·  %d waypoints" % [Game.sigils_collected, Game.slimes_defeated, Game.waypoints_activated])
	_line("Offline collection: %d wishes  ·  %d different treasures" % [Game.wish_count, Game.collectibles.size()])
	_line("Coins, starlight, levels, potions and treasures are saved on this device. Story objectives and waypoints are saved on this device.")


func _settings() -> void:
	_line("GRAPHICS", 23, UI.ACCENT)
	_line("Current quality: %s" % Game.quality_name())
	_action("Change graphics quality", _change_quality)
	_line("AUDIO", 23, UI.ACCENT)
	for bus in ["Master", "Ambience", "SFX"]:
		var index := AudioServer.get_bus_index(bus)
		if index >= 0:
			var value := 0.0 if AudioServer.is_bus_mute(index) else db_to_linear(AudioServer.get_bus_volume_db(index))
			_slider(bus, value, 0.0, 1.0, _set_bus.bind(bus))
	_line("CONTROLS", 23, UI.ACCENT)
	_slider("Camera sensitivity", Game.camera_sensitivity, 0.25, 2.0, Game.set_sensitivity)
	_line("Select a keyboard action, then press a key. Escape cancels. Touch controls remain available.")
	if _binding_action != "":
		_line("Press a key for %s (Escape cancels)" % _binding_action.replace("_", " "), 17, UI.ACCENT)
	for action in Game.REBIND_ACTIONS:
		_action("%s   ·   %s" % [action.replace("_", " ").capitalize(), OS.get_keycode_string(Game.key_for_action(action))], _begin_binding.bind(action))
	_action("Restore default keys", _reset_bindings)


func _slider(title: String, value: float, minimum: float, maximum: float, callback: Callable) -> void:
	var row := HBoxContainer.new()
	_body.add_child(row)
	var label := Label.new()
	label.text = title
	label.custom_minimum_size = Vector2(190, 0)
	row.add_child(label)
	var slider := HSlider.new()
	slider.min_value = minimum
	slider.max_value = maximum
	slider.step = 0.05
	slider.value = value
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	slider.custom_minimum_size.y = 36
	slider.value_changed.connect(callback)
	row.add_child(slider)


func _set_bus(value: float, bus: String) -> void:
	Game.set_bus_level(bus, value)


func _begin_binding(action: String) -> void:
	_binding_action = action
	_refresh()


func _reset_bindings() -> void:
	_binding_action = ""
	Game.reset_keys()
	_status = "Default keys restored."
	_refresh()


func _input(event: InputEvent) -> void:
	if not visible or _binding_action == "" or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	var key: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
	if key == KEY_ESCAPE:
		_status = "Key binding cancelled."
	elif Game.rebind_action(_binding_action, key):
		_status = "Key binding saved."
	else:
		_status = "Key unavailable or already assigned."
	_binding_action = ""
	get_viewport().set_input_as_handled()
	_refresh()


func _change_quality() -> void:
	Game.cycle_quality()
	var node := get_parent()
	while node != null:
		if node.has_method("apply_quality"):
			node.call("apply_quality")
			break
		node = node.get_parent()
	_refresh()


func _dialogue() -> void:
	_line("STAR GUARD ILYRA", 25, UI.ACCENT)
	var story := Game.guard_story
	if not bool(story.get("seal_accepted", false)):
		_line("The lights around Ashvale are fading. A star sigil may tell us why the Seven Seals have weakened. What brings you here, traveller?")
		_action("I want to protect the valley.", _accept_guard.bind("seal", "duty"))
		_action("I want to understand what happened.", _accept_guard.bind("seal", "curiosity"))
	else:
		var answer := str(story.get("answer", ""))
		_line("I remember your promise to protect this place." if answer == "duty" else "You wanted answers. The First Silence left more questions than records.")
		if bool(story.get("seal_done", false)):
			_line("The sigil is safe. Your Wander now holds the Stone Bulwark spell.")
		elif Game.guard_can_complete("seal"):
			_line("You found a sigil! Let me copy the defensive pattern into your Wander.")
			_action("Complete A Light Remembered · learn Stone Bulwark", _complete_guard.bind("seal"))
		else:
			_line("Please recover a star sigil and bring its light back here.")
		if not bool(story.get("hollow_accepted", false)):
			_line("The Hollow creatures have also begun gathering outside the shore.")
			_action("Offer to help · begin Hollow Signs", _accept_guard.bind("hollow", ""))
		elif bool(story.get("hollow_done", false)):
			_line("The shore is safer, thanks to you. Remember what you learned of Arc Lance.")
		elif Game.guard_can_complete("hollow"):
			_line("You drove them back. I found an arcane pattern for your Wander.")
			_action("Complete Hollow Signs · learn Arc Lance", _complete_guard.bind("hollow"))
		else:
			_line("Please defeat three slimes. Progress: %d / 3." % mini(Game.slimes_defeated, 3))


func _accept_guard(quest: String, answer: String) -> void:
	_status = "Quest added to your journal." if Game.guard_accept(quest, answer) else "Quest already accepted."
	_refresh()


func _complete_guard(quest: String) -> void:
	_status = "Quest complete. Assign the new spell in the spellbook." if Game.guard_complete(quest) else "Objective not yet complete."
	_refresh()


func _story() -> void:
	_line("THE VALLEY REMEMBERS", 25, UI.ACCENT)
	_line("The valley's scattered stars have fallen quiet. Sora and her companions travel between the waypoints to bring their light home.")
	_line("✦  Recover twelve sigils and discover the landmarks of the valley.")
	_line("Visit Star Guard Ilyra at the starting shore to begin the first playable story quests.")
	if Game.wander != null:
		_line("WANDER MASTERY", 18, UI.ACCENT)
		for id in Game.wander.CATALOGUE:
			if Game.wander.known(id):
				_line("%s · Level %d / 30" % [Game.wander.spell(id)["name"], Game.wander.level_of(id)])
