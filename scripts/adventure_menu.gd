extends Control
## Offline adventure screens. No real-money purchases or network accounts.

signal closed
const UI := preload("res://scripts/ui_style.gd")
const TABS := ["Character", "Inventory", "Map", "Quests", "Wish", "Level Up", "Shop", "Profile", "Settings", "Story", "Wardrobe"]
const HOME_TABS := ["Wardrobe", "Profile", "Settings", "Shop"]
const GAME_TABS := ["Inventory", "Map", "Character", "Quests", "Wish", "Level Up", "Story"]
var home_mode := false

var _body: VBoxContainer
var _header: Label
var _balance: Label
var _tab := "Character"
var _status := ""


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
		"Map": _map()
		"Quests": _quests()
		"Wish": _wish()
		"Level Up": _level_up()
		"Shop": _shop()
		"Profile": _profile()
		"Settings": _settings()
		"Story": _story()
		"Wardrobe": _wardrobe()
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
	_line("Each potion or treasure uses one slot. Equip a backpack from the home wardrobe for more room.")
	if used > capacity:
		_line("Your existing collection exceeds capacity. No items were lost; equip a larger backpack or use potions.", 16, UI.ACCENT)
	var entries: Array[String] = []
	for i in range(Game.potions):
		entries.append("Potion")
	for item in Game.WISH_ITEMS:
		for i in range(maxi(0, int(Game.collectibles.get(item, 0)))):
			entries.append(str(item))
	var grid := GridContainer.new()
	grid.columns = 5
	grid.add_theme_constant_override("h_separation", 6)
	grid.add_theme_constant_override("v_separation", 6)
	_body.add_child(grid)
	for i in range(maxi(capacity, used)):
		var slot := PanelContainer.new()
		slot.custom_minimum_size = Vector2(120, 55)
		slot.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slot.add_theme_stylebox_override("panel", UI.panel(8.0, 0.72))
		var label := Label.new()
		label.text = entries[i] if i < entries.size() else "Empty"
		label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		label.add_theme_font_size_override("font_size", 14)
		label.add_theme_color_override("font_color", UI.TEXT if i < entries.size() else Color(0.6, 0.6, 0.7))
		slot.add_child(label)
		grid.add_child(slot)
	_action("Use healing potion (%d owned)" % Game.potions, _use_potion, Game.potions > 0 and Game.current_hp() < Game.max_hp())


func _use_potion() -> void:
	_status = "Potion used." if Game.use_potion() else "No potion needed or available."
	_refresh()


func _map() -> void:
	_line("WAYPOINTS", 14, UI.ACCENT)
	_line("Activate a statue in the world to unlock fast travel. Distance is measured from your current location.")
	var player := get_tree().get_first_node_in_group("player") as Node3D
	for waypoint in get_tree().get_nodes_in_group("waypoint"):
		if not (waypoint is Node3D):
			continue
		var place: Node3D = waypoint
		var place_name := str(place.get("statue_name"))
		var unlocked := Game.waypoints_seen.has(place_name)
		var distance := int(player.global_position.distance_to(place.global_position)) if player != null else 0
		_action("✦  %s   ·   %dm   ·   %s" % [place_name, distance, "Teleport" if unlocked else "Locked"], _teleport.bind(place), unlocked and player != null)


func _teleport(waypoint: Node3D) -> void:
	var player := get_tree().get_first_node_in_group("player") as CharacterBody3D
	if player == null or not is_instance_valid(waypoint):
		return
	var place_name := str(waypoint.get("statue_name"))
	if not Game.waypoints_seen.has(place_name):
		return
	var target := waypoint.global_position + Vector3(3.0, 0.0, 3.0)
	var world := player.get_parent()
	var terrain := world.get_node_or_null("Terrain")
	if terrain != null:
		target.y = float(terrain.call("get_height_at", target.x, target.z))
		terrain.call("_rebuild_collision", Vector2(target.x, target.z))
		terrain.call("_refresh", Vector2(target.x, target.z), false)
	player.call("_snap_to_ground", target)
	close_menu()
	Game.toast.emit("Travelled to %s" % place_name)


func _quests() -> void:
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
	_line("BACKPACKS", 23, UI.ACCENT)
	_line("Equipping a backpack increases inventory capacity. Buy backpacks in the home shop.")
	for i in Game.owned_backpacks:
		var equipped: bool = i == Game.equipped_backpack
		var fits: bool = Game.inventory_used() <= 10 + Game.BACKPACK_BONUS[i]
		var suffix := "Equipped" if equipped else ("Equip" if fits else "Too many items")
		_action("%s  ·  %d slots  ·  %s" % [Game.BACKPACK_NAMES[i], 10 + Game.BACKPACK_BONUS[i], suffix], _equip_backpack.bind(i), not equipped and fits)


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
	_line("Coins, starlight, levels, potions and treasures are saved on this device. Expedition objectives reset when you start a new journey.")


func _settings() -> void:
	_line("GRAPHICS", 23, UI.ACCENT)
	_line("Current quality: %s. Balanced and Performance use dynamic 3D resolution." % Game.quality_name())
	_action("Change graphics quality", _change_quality)
	_line("CONTROLS", 23, UI.ACCENT)
	_line("WASD move  ·  Shift sprint  ·  Space jump/glide  ·  LMB attack  ·  E skill  ·  Q burst  ·  T switch  ·  J journal  ·  Esc pause")
	_line("Touch: left joystick, right-side camera drag, and on-screen action buttons.")


func _change_quality() -> void:
	Game.cycle_quality()
	var node := get_parent()
	while node != null:
		if node.has_method("apply_quality"):
			node.call("apply_quality")
			break
		node = node.get_parent()
	_refresh()


func _story() -> void:
	_line("THE VALLEY REMEMBERS", 25, UI.ACCENT)
	_line("The valley's scattered stars have fallen quiet. Sora and her companions travel between the waypoints to bring their light home.")
	_line("✦  Recover twelve sigils and discover the landmarks of the valley.")
	_line("This is a journal entry; branching NPC dialogue is not yet available.")
