extends Control
## Offline adventure screens. No real-money purchases or network accounts.

signal closed
const UI := preload("res://scripts/ui_style.gd")
const TABS := ["Character", "Inventory", "Quests", "Wish", "Level Up", "Shop", "Profile", "Settings", "Story", "Wardrobe", "Dialogue"]
const HOME_TABS := ["Wardrobe", "Profile", "Settings", "Shop"]
const GAME_TABS := ["Inventory", "Character", "Quests", "Wish", "Level Up", "Story"]
var home_mode := false
var dialogue_site_id := ""
var dialogue_resident_index := 0
const SETTLEMENTS := preload("res://scripts/settlement_data.gd")

var _body: VBoxContainer
var _tab_buttons: Dictionary = {}
var _header: Label
var _balance: Label
var _tab := "Character"
var _status := ""
var _selected_item := ""
var _show_weapons := false
var _sort_alphabetical := false
var _binding_action := ""
var _close_button: Button
var _wander_slot := 0
var _research_first := 0
var _research_second := 1
var _research_shape := 0
var _research_reach := 0
var _research_intensity := 0
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
	var ane_icon := TextureRect.new()
	ane_icon.texture = preload("res://icons/items/ane.svg")
	ane_icon.custom_minimum_size = Vector2(25, 25)
	ane_icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	ane_icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	bar.add_child(ane_icon)
	_balance = Label.new()
	_balance.add_theme_font_size_override("font_size", 16)
	_balance.add_theme_color_override("font_color", UI.ACCENT)
	bar.add_child(_balance)
	var close := Button.new()
	close.text = ""
	close.tooltip_text = "Close"
	UI.icon(close, "Close")
	close.custom_minimum_size = Vector2(48, 42)
	UI.button(close)
	close.pressed.connect(close_menu)
	bar.add_child(close)
	_close_button = close
	# Persistent navigation rail mirrors the reference while keeping every
	# existing tab and the scrollable content area intact.
	var content := HBoxContainer.new()
	content.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 16)
	layout.add_child(content)
	var tabs: Array = HOME_TABS if home_mode else GAME_TABS
	var rail := VBoxContainer.new()
	rail.custom_minimum_size.x = 160
	rail.add_theme_constant_override("separation", 5)
	content.add_child(rail)
	for page in tabs:
		var tab := Button.new()
		tab.name = page.replace(" ", "") + "Tab"
		tab.text = page
		tab.custom_minimum_size = Vector2(0, 44)
		tab.alignment = HORIZONTAL_ALIGNMENT_LEFT
		tab.add_theme_font_size_override("font_size", 15)
		UI.icon(tab, page)
		UI.button(tab)
		tab.pressed.connect(_select.bind(page))
		rail.add_child(tab)
		_tab_buttons[page] = tab
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(scroll)
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
	_close_button.grab_focus()


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
	UI.icon(button, _action_icon(text))
	button.pressed.connect(callback)
	_body.add_child(button)


func _action_icon(text: String) -> String:
	var lower := text.to_lower()
	if lower.contains("potion"): return "Potion"
	if lower.contains("weapon") or lower.contains("blade") or lower.contains("sword"): return "Weapon"
	if lower.contains("outfit") or lower.contains("traveller") or lower.contains("hairpin"): return "Clothing"
	if lower.contains("backpack"): return "Backpack"
	if lower.contains("quest") or lower.contains("blueprint") or lower.contains("spell"): return "Quests"
	if _tab == "Settings": return "Settings"
	if _tab == "Shop": return "Shop"
	if _tab == "Wardrobe": return "Wardrobe"
	if _tab == "Character": return "Character"
	if _tab == "Inventory": return "Inventory"
	return "Wish" if _tab == "Wish" else "Story"


func _refresh() -> void:
	if _body == null or not visible:
		return
	for child in _body.get_children():
		_body.remove_child(child)
		child.queue_free()
	for page in _tab_buttons:
		UI.button(_tab_buttons[page], page == _tab)
	_header.text = "✦  %s" % _tab.to_upper()
	_balance.text = "✧ %d starlight    ◇ %d Ane     " % [Game.starlight, Game.coins]
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
	_line("QUEST EQUIPMENT & BLUEPRINTS", 20, UI.ACCENT)
	_line("Weapons are stored separately from backpack slots. They use the sword user's melee attacks; other characters keep their own weapons.")
	_action("Weapons · %d / %d owned · %s" % [Game.owned_weapons.size(), Game.WEAPONS.COUNT, "Hide" if _show_weapons else "Show"], _toggle_weapons)
	if _show_weapons:
		_action("Default weapon%s" % (" · Equipped" if Game.equipped_weapon == "" else ""), _equip_reward_weapon.bind(""), Game.equipped_weapon != "")
		for number in range(Game.WEAPONS.COUNT):
			var id: String = Game.WEAPONS.id_for_index(number)
			if Game.owned_weapons.has(id):
				_action("%s · +%d%% attack%s" % [Game.WEAPONS.name_for_id(id), roundi(Game.WEAPONS.bonus(id) * 100.0), " · Equipped" if Game.equipped_weapon == id else " · Equip"], _equip_reward_weapon.bind(id), Game.equipped_weapon != id)
	if Game.owned_blueprints.has(Game.BLUEPRINT_ID):
		var known: bool = Game.wander != null and Game.wander.known(Game.BLUEPRINT_ID)
		_action("Wind / Fire blueprint · %s" % ("Learned" if known else "Learn spell"), _learn_blueprint, Game.wander != null and not known)
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
		_line("Main · A Light Remembered: speak with Star Guard Ilyra in Ashvale.")
	elif bool(story.get("seal_done", false)):
		_line("Main · A Light Remembered: completed. Reward: Stone Bulwark.")
	else:
		_line("Main · A Light Remembered: recover a star sigil (%d / 1), then return to Ilyra." % mini(Game.sigils_collected, 1))
	if bool(story.get("hollow_accepted", false)):
		_line("Side · Hollow Signs: %s" % ("completed. Reward: Arc Lance." if bool(story.get("hollow_done", false)) else "defeat three slimes (%d / 3), then return to Ilyra." % mini(Game.slimes_defeated, 3)))
	if bool(story.get("memory_accepted", false)):
		var memory_status := "Completed · choice: %s" % str(story.get("memory_choice", "")) if bool(story.get("memory_done", false)) else ("Return the fragment to Ilyra" if bool(story.get("memory_found", false)) else "Defeat the Warden, then recover the fragment from the chest")
		_line("Main · A Memory in the Hollow: %s" % memory_status)
	_line("ASHVALE HOLLOW", 18, UI.ACCENT)
	_line("Cleared · reward claimed" if Game.ashvale_hollow_cleared else "Optional challenge: find the Hollow entrance near Ashvale. Dodge the Warden's red warning circles. Defeat it for 100 Ane and 30 starlight.")
	_line("MEMORY VAULT", 18, UI.ACCENT)
	_line("Cleared · Verdant Bloom recovered" if bool(Game.dungeon_clears.get("memory_vault", false)) else "Find the Memory Vault near Lunareth. Defeat its scouts and the two-phase sentinel to learn Verdant Bloom.")
	_line("SUNCREST ROOST", 18, UI.ACCENT)
	_line("Cleared · Scorched Promise recovered" if bool(Game.dungeon_clears.get("suncrest_roost", false)) else "Find the Roost near Suncrest. Defeat its guardians and dragon for a memory, 200 Ane and 60 starlight.")
	_line("MEMORIES OF THE FIRST SILENCE · %d / %d" % [Game.story_memory_count(), Game.STORY_MEMORY_GOAL], 18, UI.ACCENT)
	for memory in Game.all_story_memories():
		if Game.story_memory_owned(str(memory["id"])):
			_line("%s — %s" % [memory["name"], memory["lore"]])
		else:
			var hint := str(SETTLEMENTS.SITES[int(memory["site"])]["name"]) if memory.has("site") else str(memory["id"]).replace("_", " ").capitalize()
			var reward_id := str(Game.MEMORY_SPELLS.get(str(memory["id"]), ""))
			var reward_hint := " · spell discovery" if not reward_id.is_empty() else ""
			_line("Undiscovered memory · near %s%s" % [hint, reward_hint])
	_line("Find two memory Hollows near each listed settlement. Their arenas share a common Hollow design.")
	_line("OPTIONAL HOLLOWS · %d / %d" % [Game.optional_dungeon_count(), Game.OPTIONAL_DUNGEONS.COUNT], 18, UI.ACCENT)
	_line("Explore near settlements for optional challenges. These encounters reuse Hollow arenas and enemy families; their Ane and starlight rewards are claimed once.")
	for optional_site in range(SETTLEMENTS.SITES.size()):
		var optional_done := 0
		var optional_total := 0
		for optional_index in range(Game.OPTIONAL_DUNGEONS.COUNT):
			var optional_entry: Dictionary = Game.OPTIONAL_DUNGEONS.entry(optional_index)
			if int(optional_entry["site"]) == optional_site:
				optional_total += 1
				if bool(Game.dungeon_clears.get(optional_entry["id"], false)): optional_done += 1
		_line("%s · %d / %d cleared" % [SETTLEMENTS.SITES[optional_site]["name"], optional_done, optional_total])
	_line("THE LAST SEAL", 18, UI.ACCENT)
	if bool(Game.guard_story.get("keeper_defeated", false)):
		_line("The Keeper is defeated. The Seals hold because the people of Elaris chose to share their light. The world remembers again.")
	else:
		_line("Aetheris · The underground gate requires all 25 memories.")
	_line("SETTLEMENT QUESTS", 18, UI.ACCENT)
	var any_quest := false
	for site in SETTLEMENTS.SITES:
		for index in range(SETTLEMENTS.RESIDENT_COUNT):
			var resident := SETTLEMENTS.resident(site["id"], index)
			for kind in ["main", "side"]:
				var state: String = Game.settlement_quest_status(site["id"], kind, index)
				if state == "available":
					continue
				any_quest = true
				var detail := "Find nearby" if state == "active" else ("Return to resident" if state == "found" else "Complete")
				_line("%s · %s · %s · %s: %s" % [site["name"], resident["name"], kind.capitalize(), resident[kind], detail])
	if not any_quest:
		_line("Speak with residents in settlements to discover local quests.")
	_line("TRAVEL NOTES", 18, UI.ACCENT)
	_line("Approximate straight-line directions from your position. Explore on foot; there is no map or fast travel.")
	var player := get_tree().get_first_node_in_group("player") as Node3D
	var manager: Node = player.get_parent().get_node_or_null("Settlements") if player != null else null
	if manager != null:
		var sites: Array = manager.get("_sites")
		for site in sites:
			var delta: Vector2 = site["resolved"] - Vector2(player.global_position.x, player.global_position.z)
			var direction := "Here" if delta.length() < 30.0 else ("%s %s" % ["North" if delta.y < 0 else "South", "East" if delta.x > 0 else "West"])
			_line("%s · %s · %dm" % [site["name"], direction, int(delta.length())])
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
		var suffix := "MAX LEVEL" if level >= 10 else "%d Ane" % cost
		_action("%s   ·   Lv. %d   →   %s" % [Game.PARTY[i]["name"], level, suffix], _upgrade.bind(i), level < 10 and Game.coins >= cost)


func _upgrade(index: int) -> void:
	_status = "%s levelled up!" % Game.PARTY[index]["name"] if Game.upgrade_character(index) else "Not enough Ane or already at max level."
	_refresh()


func _shop() -> void:
	_line("THE WANDERER'S SHOP", 23, UI.ACCENT)
	_line("Offline supplies only. Ane are earned by playing.")
	_action("Healing potion   ·   25 Ane", _buy_potion, Game.coins >= 25 and Game.inventory_used() < Game.inventory_capacity())
	_line("Potions require an empty inventory slot.")
	_action("Moon hairpin · %s" % ("Owned" if Game.owned_cosmetics.has("moon_pin") else "100 Ane"), _buy_moon_pin, not Game.owned_cosmetics.has("moon_pin") and Game.coins >= 100)
	_action("Sunrise traveller outfit · %s" % ("Owned" if Game.owned_outfits.has(4) else "150 Ane"), _buy_sunrise_outfit, not Game.owned_outfits.has(4) and Game.coins >= 150)
	for i in range(1, Game.BACKPACK_NAMES.size()):
		var owned: bool = Game.owned_backpacks.has(i)
		_action("%s  ·  +%d slots  ·  %s" % [Game.BACKPACK_NAMES[i], Game.BACKPACK_BONUS[i], "Owned" if owned else "%d Ane" % Game.BACKPACK_PRICES[i]], _buy_backpack.bind(i), not owned and Game.coins >= Game.BACKPACK_PRICES[i])


func _wardrobe() -> void:
	_line("OUTFIT COLOUR", 23, UI.ACCENT)
	for i in Game.owned_outfits:
		_action("%s%s" % [Game.OUTFIT_NAMES[i], "  ·  Equipped" if i == Game.outfit_style else ""], _set_outfit.bind(i), i != Game.outfit_style)
	_line("HAIR ACCESSORIES", 23, UI.ACCENT)
	_action("No hairpin%s" % (" · Equipped" if Game.equipped_cosmetic == "" else ""), _equip_reward_cosmetic.bind(""), Game.equipped_cosmetic != "")
	for id in Game.owned_cosmetics:
		if Game.COSMETIC_NAMES.has(id):
			_action("%s%s" % [Game.COSMETIC_NAMES[id], " · Equipped" if Game.equipped_cosmetic == id else " · Equip"], _equip_reward_cosmetic.bind(id), Game.equipped_cosmetic != id)
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
	_status = "Potion added to your inventory." if Game.buy_potion() else "Not enough Ane."
	_refresh()


func _profile() -> void:
	_line("THE TRAVELLER", 26, UI.ACCENT)
	_line("Active character: %s  ·  Level %d" % [Game.character()["name"], Game.character_levels[Game.party_index]])
	_line("This expedition: %d sigils  ·  %d slimes  ·  %d waypoints" % [Game.sigils_collected, Game.slimes_defeated, Game.waypoints_activated])
	_line("Offline collection: %d wishes  ·  %d different treasures" % [Game.wish_count, Game.collectibles.size()])
	_line("Ane, starlight, levels, potions and treasures are saved on this device. Story objectives and waypoints are saved on this device.")


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
	_line("Controller: left stick move · right stick look · A jump · B dodge · X attack · Y skill · shoulders sprint/burst · D-pad up talk, down heavy, right switch, left spell 1 · triggers spells 2–3 · stick clicks spells 4–5 · Start pause · Back journal.")
	_line("Keyboard: 1–5 cast Wander slots. Select an action below, then press a key. Escape cancels. Touch controls remain available.")
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
	if dialogue_site_id != "":
		_settlement_dialogue()
		return
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
		if bool(story.get("seal_done", false)):
			_line("My Gift can mend wounds, but I could not save the patrol that vanished into the Hollow. I still carry their unanswered report.")
			if bool(story.get("ilyra_following", false)):
				_line("Ilyra accompanies you and heals you during nearby fights when your health is low.")
				_action("Ask Ilyra to return to Ashvale", _set_ilyra_following.bind(false))
			else:
				_action("Ask Ilyra to travel with you", _set_ilyra_following.bind(true))
			if not bool(story.get("memory_accepted", false)):
				_line("The patrol described a memory fragment beyond the Ashvale Hollow's guardian. Could you recover it?")
				_action("Begin A Memory in the Hollow", _accept_hollow_memory)
			elif bool(story.get("memory_done", false)):
				if story.get("memory_choice", "") == "share":
					_line("The patrol's families know the truth. Thank you for trusting me with it. Our bond strengthens my healing Gift.")
				else:
					_line("We kept the fragment safe for the scholars. I still hope the families can hear its story someday.")
			elif bool(story.get("memory_found", false)):
				_line("The fragment remembers the patrol sealing a breach, not abandoning their post. What should we do with it?")
				_action("Share the truth with the families · learn Sun Spear", _resolve_hollow_memory.bind("share"))
				_action("Preserve it for research · learn Tide Step", _resolve_hollow_memory.bind("study"))
			else:
				_line("Defeat the Warden in Ashvale Hollow, then interact with the chest to recover the fragment. You can leave and try again.")


func _settlement_dialogue() -> void:
	var site := SETTLEMENTS.by_id(dialogue_site_id)
	if site.is_empty():
		_line("This resident is unavailable.")
		return
	var resident := SETTLEMENTS.resident(dialogue_site_id, dialogue_resident_index)
	if resident.is_empty():
		_line("This resident is unavailable.")
		return
	_line("%s  ·  %s" % [resident["name"], site["name"]], 25, UI.ACCENT)
	_line("%s — %s" % [resident["role"], site["lore"]])
	for kind in ["main", "side"]:
		var status: String = Game.settlement_quest_status(dialogue_site_id, kind, dialogue_resident_index)
		var title := "Main" if kind == "main" else "Side"
		var item: String = str(resident[kind])
		match status:
			"available":
				_line("%s quest: Could you find my %s? Look for my labelled glowing item near this settlement. Reward: %s." % [title, item, Game.settlement_reward_text(kind, dialogue_resident_index, dialogue_site_id)])
				_action("Accept %s quest · %s" % [title.to_lower(), item], _accept_settlement.bind(kind))
			"active":
				_line("%s quest: Find my labelled %s near the settlement and bring it back." % [title, item])
			"found":
				_action("Return %s · reward %s" % [item, Game.settlement_reward_text(kind, dialogue_resident_index, dialogue_site_id)], _complete_settlement.bind(kind))
			"done":
				_line("%s quest: Thank you for returning the %s." % [title, item])


func _accept_settlement(kind: String) -> void:
	_status = "Quest accepted. Look for the glowing item near the settlement." if Game.accept_settlement_quest(dialogue_site_id, kind, dialogue_resident_index) else "Quest already accepted."
	_refresh()


func _complete_settlement(kind: String) -> void:
	_status = "Quest complete. Reward collected." if Game.complete_settlement_quest(dialogue_site_id, kind, dialogue_resident_index) else "Find the item first."
	_refresh()


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
	_line("Long ago, the First Silence nearly extinguished Elaris. Seven Seals guard the world, but Hollows have begun to open and memories of the past are scattered.")
	_line("Visit Star Guard Ilyra in Ashvale. A recovered sigil leads to a memory in the Hollow, and a choice about who should hear its story.")
	_line("Seek the memories in Ashvale Hollow, the Memory Vault and Suncrest Roost. Recover all 25 memories to open the Last Seal.")
	if bool(Game.guard_story.get("keeper_defeated", false)):
		_line("At the Last Seal, the Keeper's control was broken. With their shared memories, the people renewed the Seals together, and Elaris remembered its light.")
	if Game.wander != null:
		_line("WANDER RESEARCH", 18, UI.ACCENT)
		if not bool(Game.guard_story.get("seal_done", false)):
			_line("Complete Ilyra's A Light Remembered quest to unlock spell research.")
		else:
			_line("Combine two elements and adjust shape, range and power. Each new recipe costs 10 starlight. Both elements affect enemy reactions.")
			_action("First element: %s" % Wander.RESEARCH_ELEMENTS[_research_first], _cycle_research.bind("first"))
			_action("Second element: %s" % Wander.RESEARCH_ELEMENTS[_research_second], _cycle_research.bind("second"))
			_action("Shape: %s" % ("Pulse around you" if _research_shape else "Focused ahead"), _cycle_research.bind("shape"))
			_action("Reach: %s" % ("Long" if _research_reach else "Close"), _cycle_research.bind("reach"))
			_action("Power: %s" % ("Strong" if _research_intensity else "Efficient"), _cycle_research.bind("intensity"))
			var recipe := Wander.research_id(_research_first, _research_second, _research_shape, _research_reach, _research_intensity)
			var preview: Dictionary = Game.wander.spell(recipe)
			_line("%s · %.0f Light · %.0fm range · %.1f power" % [preview["name"], preview["cost"], preview["range"], preview["power"]])
			_action("Discover this spell · 10 starlight", _research_spell, Game.starlight >= 10 and not Game.wander.known(recipe))
		_line("WANDER MASTERY & EQUIPMENT", 18, UI.ACCENT)
		var equipped := Game.wander.equipped_at(_wander_slot)
		var equipped_name: String = str(Game.wander.spell(equipped).get("name", "Empty"))
		_action("Slot %d: %s · choose another slot" % [_wander_slot + 1, equipped_name], _cycle_wander_slot)
		_action("Clear this spell slot", _equip_wander.bind(""), equipped != "")
		for id in Game.wander.known_ids():
			if Game.wander.known(id):
				_action("%s · Level %d / 30 · equip in slot %d" % [Game.wander.spell(id)["name"], Game.wander.level_of(id), _wander_slot + 1], _equip_wander.bind(id))


func _cycle_research(field: String) -> void:
	match field:
		"first": _research_first = (_research_first + 1) % 3
		"second": _research_second = (_research_second + 1) % 3
		"shape": _research_shape = 1 - _research_shape
		"reach": _research_reach = 1 - _research_reach
		"intensity": _research_intensity = 1 - _research_intensity
	_refresh()


func _research_spell() -> void:
	var id: String = Game.research_spell(_research_first, _research_second, _research_shape, _research_reach, _research_intensity)
	_status = "Discovered %s. Assign it below." % Game.wander.spell(id)["name"] if id != "" else "Unable to discover this recipe."
	_refresh()


func _cycle_wander_slot() -> void:
	_wander_slot = (_wander_slot + 1) % 5
	_refresh()


func _equip_wander(id: String) -> void:
	if Game.wander != null and Game.wander.set_slot(_wander_slot, id):
		_status = "Spell slot updated."
	else:
		_status = "Unable to equip spell."
	_refresh()


func _equip_reward_weapon(id: String) -> void:
	_status = "Weapon equipped for sword users." if Game.equip_reward_weapon(id) else "Weapon unavailable."
	_refresh()


func _equip_reward_cosmetic(id: String) -> void:
	_status = "Hair accessory changed." if Game.equip_reward_cosmetic(id) else "Accessory unavailable."
	_refresh()


func _learn_blueprint() -> void:
	_status = "Spell learned. Assign it in Story or the spell wheel." if Game.learn_reward_blueprint(Game.BLUEPRINT_ID) else "Spell already learned or unavailable."
	_refresh()


func _buy_moon_pin() -> void:
	_status = "Moon hairpin purchased. Equip it in Wardrobe." if Game.buy_reward_cosmetic("moon_pin") else "Unable to purchase."
	_refresh()


func _buy_sunrise_outfit() -> void:
	_status = "Sunrise outfit purchased. Equip it in Wardrobe." if Game.buy_reward_outfit() else "Unable to purchase."
	_refresh()


func _toggle_weapons() -> void:
	_show_weapons = not _show_weapons
	_refresh()


func _accept_hollow_memory() -> void:
	_status = "A Memory in the Hollow added to your journal." if Game.accept_hollow_memory() else "Complete Ilyra's first quest first."
	_refresh()


func _resolve_hollow_memory(choice: String) -> void:
	_status = "Memory resolved. Your new spell is available in Story and the spell wheel." if Game.resolve_hollow_memory(choice) else "The memory is not ready to resolve."
	_refresh()


func _set_ilyra_following(following: bool) -> void:
	_status = "Ilyra joins your journey." if following else "Ilyra returns to Ashvale."
	if not Game.set_ilyra_following(following):
		_status = "Complete Ilyra's first quest first."
	_refresh()
