extends CharacterBody3D
## Anime action-RPG player: snappy movement, sprint stamina, double jump,
## Genshin-style gliding with a wind-drawn wing pair, elemental skill/burst,
## party switching and a diving plunge attack.

const CharacterBuilder := preload("res://scripts/character_builder.gd")
const FX := preload("res://scripts/fx.gd")

const WALK_SPEED := 6.4
const SPRINT_SPEED := 10.8
const GLIDE_SPEED := 8.4
const JUMP_VELOCITY := 8.6
const DOUBLE_JUMP_VELOCITY := 7.4
const GLIDE_FALL := -2.0
const GRAVITY_SCALE := 1.35
const TURN_SPEED := 13.0
## Camera distance and aim height.
##
## The camera used to sit 4.2 m back at 2.05 m with a -0.18 rad pitch, which is
## nearly level with the meadow. In a field of upright grass that put every tuft
## between the lens and the character: she rendered correctly (the probe reported
## her head on screen) but the blades in front of her covered her completely.
## Genshin's own camera looks down at roughly 20 degrees from slightly further
## back, which clears the grass and shows the ground she is standing on.
const CAM_DISTANCE := 3.9
## Chest height on a 1.8 m character. The frame is centred here, which leaves the
## full body in view above the HUD band at the bottom of the screen.
const CAM_HEIGHT := 1.45
## Extra camera pitch, in radians, applied on top of the player's own look angle.
##
## Sign is easy to get backwards and I did. The camera inherits the spring arm's
## orientation and the arm hangs behind and above the pivot, so a POSITIVE x
## rotation pitches the camera UP and moves the subject DOWN the frame. An "aim
## lift" of 1.05 m therefore pushed the character off the bottom of the screen
## instead of up it. Negative tilts the lens down, centring the frame a little
## below the pivot, which is what puts a chest-height pivot comfortably inside the
## play area rather than behind the HUD's action bar.
const CAM_AIM_DROP := -0.16
const CAM_SHOULDER := 0.45
const MOUSE_SENS := 0.0026
const STICK_SENS := 2.4
const SPRINT_DRAIN := 20.0
const GLIDE_DRAIN := 3.0
const STAMINA_REGEN := 22.0

var rig: Dictionary = {}
var element_id: int = 0

var _yaw: float = 0.0
var _target_yaw: float = 0.0
## Look-down angle. -0.18 rad is roughly 10 degrees: enough to see the ground the
## character stands on and to clear the grass, without swinging the camera so high
## that she drops to the bottom of the frame. Pitching the pivot further rotates
## the whole spring arm upward, so the character slides down the screen along with
## it - the fix for "the grass hides her" was the cull radius, not the angle.
var _pitch: float = -0.18
var _target_pitch: float = -0.18
var _pivot: Node3D
var _spring: SpringArm3D
var _camera: Camera3D
var _double_jump_used := false
var _gliding := false
var _anim_phase := 0.0
var _idle_time := 0.0
var _stamina_regen_hold := 0.0
## The character's spellbook (scripts/wander.gd). Created once and shared with
## the HUD so the wheel and the caster always agree on slots and cooldowns.
var wander: Wander

## How far above the surface a snapped body starts. The physics engine treats a
## body that begins a frame intersecting geometry as "already handled" and can
## slide it straight through the mesh.
const SPAWN_CLEARANCE := 1.6

var _attack_cd := 0.0
var _skill_cd := 0.0
var _attack_combo := 0
var _combo_reset := 0.0
var _diving := false
var _spawn_origin := Vector3.ZERO
var _trail_timer := 0.0

signal skill_used(element: int, position: Vector3, power: float)
signal burst_used(element: int, position: Vector3, power: float)


func _ready() -> void:
	add_to_group("player")
	collision_layer = 2
	# Collide with the world layer only. Layer 4 is used by pickups/waypoints;
	# including it here made the body snag on trigger volumes.
	collision_mask = 1
	_spawn_origin = global_position
	# Snap onto the actual ground, deferred: the physics space is not queryable
	# until the body has entered the tree and a physics frame has run. The world
	# only knows the analytic terrain height, which can sit slightly below the
	# collision mesh - spawning under it means falling through the world forever.
	_snap_to_ground.call_deferred(global_position)
	# Camera first: it is the one node the scene cannot do without. The rig and
	# the rest of the wiring come after, so a problem dressing the character can
	# never leave the player (and the viewport) without a camera.
	_build_camera()
	_build_rig()
	_make_wander()
	Game.respawned.connect(_on_respawn)
	Game.spell_cast.connect(_on_spell_cast)
	Game.character_changed.connect(_on_character_changed)
	Game.game_won.connect(_on_game_won)
	if not Game.is_mobile():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	await get_tree().process_frame


func _make_wander() -> void:
	wander = Wander.new()
	Game.wander = wander


func _build_rig() -> void:
	var data: Dictionary = Game.character()
	rig = CharacterBuilder.build(self, data)
	element_id = int(data["element_id"])

	var col := CollisionShape3D.new()
	var shape := CapsuleShape3D.new()
	shape.radius = 0.32
	shape.height = 1.72
	col.shape = shape
	col.position.y = 0.88
	add_child(col)


func _build_camera() -> void:
	_pivot = Node3D.new()
	_pivot.name = "CameraPivot"
	# The pivot is the point the camera orbits and the point the frame is centred
	# on, so it sits at chest height rather than above the head.
	_pivot.position = Vector3(0, CAM_HEIGHT, 0)
	add_child(_pivot)

	_spring = SpringArm3D.new()
	_spring.spring_length = CAM_DISTANCE
	# A generous margin keeps the near plane out of the hillside; without it the
	# arm stops flush against the ground and the camera clips inside.
	_spring.margin = 0.55
	# Only the world layer. The player itself is on layer 2, so the arm can never
	# collide with the character and jam the camera inside its own head.
	_spring.collision_mask = 1
	_spring.add_excluded_object(get_rid())
	# Horizontal shoulder offset only. Any vertical offset here is applied along the
	# *rotated* arm, so it shifts the camera and the character moves down the frame
	# by the same amount - which is how the character ended up behind the HUD's
	# action bar with her head at 66% of screen height.
	_spring.position = Vector3(CAM_SHOULDER, 0.0, 0)
	_pivot.add_child(_spring)

	_camera = Camera3D.new()
	_camera.rotation_degrees = Vector3(rad_to_deg(CAM_AIM_DROP), 0.0, 0.0)
	# 54 degrees. At 62 with a 5 m arm the character occupied about 6% of the frame
	# height and read as a speck on the hillside; a tighter lens at a closer
	# distance is how third-person games make the character legible without
	# cropping the landscape.
	_camera.fov = 54.0
	_camera.near = 0.05
	_camera.far = 900.0
	_camera.current = true
	_spring.add_child(_camera)


func _update_camera_occlusion() -> void:
	## When a wall or the terrain pushes the spring arm right up against the
	## character, the camera ends up inside the model and the screen reads as a
	## flat dark shape. Cull the character in that case so the world stays
	## visible - the standard third-person fix.
	var vis := _visual_node()
	if vis == null or _spring == null:
		return
	# SpringArm3D.get_hit_length() returns 0.0 when the arm HITS NOTHING - it is not
	# "the current arm length", it is "the length at which something was hit". The
	# earlier check therefore hid the character in every open field, which is why she
	# rendered as a pair of boots: the only meshes that survived were the ones drawn
	# before the visibility change took effect on screen.
	#
	# Treat a zero hit length as "nothing in the way" (full length) and only cull
	# when the arm has genuinely been shortened to a fraction of its length.
	var hit := _spring.get_hit_length()
	var arm_len := hit if hit > 0.001 else CAM_DISTANCE
	vis.visible = arm_len > CAM_DISTANCE * 0.45


func _visual_node() -> Node3D:
	if rig.is_empty():
		return null
	var n := rig.get("visual") as Node3D
	return n if is_instance_valid(n) else null


func _rig_part(key: String) -> Node3D:
	if rig.is_empty():
		return null
	var n := rig.get(key) as Node3D
	return n if is_instance_valid(n) else null


func _apply_rig_colors() -> void:
	# Character switched: rebuild the visual completely so hair/outfit/weapon
	# match the new party member.
	var old := _visual_node()
	if old and is_instance_valid(old):
		old.queue_free()
	var data: Dictionary = Game.character()
	rig = CharacterBuilder.build(self, data)
	element_id = int(data["element_id"])


func _on_character_changed(_index: int) -> void:
	_apply_rig_colors()


func _snap_to_ground(at: Vector3) -> void:
	## Put the body safely ABOVE the ground at `at`.
	##
	## Two independent sources of truth, because falling through the world is
	## the single most disruptive bug this game can have:
	##   1. the analytic height field (exact, always available, never queries
	##      physics), used to hard-correct any position that ends up below it;
	##   2. a long raycast against the real collision mesh, used when it works.
	## A body must never be placed *on* the surface: the physics engine requires
	## clearance or it starts the frame already overlapping and slides through.
	if not is_inside_tree() or get_world_3d() == null:
		return
	velocity = Vector3.ZERO
	var best := at
	best.y = at.y + SPAWN_CLEARANCE

	var space: PhysicsDirectSpaceState3D = get_world_3d().direct_space_state
	if space != null:
		var query := PhysicsRayQueryParameters3D.create(
			Vector3(at.x, at.y + 220.0, at.z),
			Vector3(at.x, at.y - 220.0, at.z), 1)
		query.hit_from_inside = false
		query.hit_back_faces = true
		query.exclude = [get_rid()]
		query.collide_with_areas = false
		var hit: Dictionary = space.intersect_ray(query)
		if not hit.is_empty():
			best = hit["position"] + Vector3(0.0, SPAWN_CLEARANCE, 0.0)

	# Final authority: never end up under the terrain, whatever the ray said.
	var terrain := _terrain()
	if terrain != null:
		var ground_y: float = terrain.get_height_at(best.x, best.z)
		if best.y < ground_y + SPAWN_CLEARANCE:
			best.y = ground_y + SPAWN_CLEARANCE

	global_position = best


func _guard_world_bounds() -> void:
	## Hard safety floor. The terrain is a 900 m concave mesh and the player is a
	## capsule on it; if a single frame ever resolves badly (spawning inside the
	## mesh, a stutter clipping the body through a seam, a device dropping a
	## physics tick) the body would otherwise fall out of the world forever.
	##
	## This runs every physics frame and is deliberately cheap: one analytic
	## height lookup with no physics query. Being lifted a little happens
	## invisibly; falling for 60 seconds does not.
	var terrain := _terrain()
	if terrain == null:
		return
	const FLOOR_FORGIVENESS := 2.5
	var ground_y: float = terrain.get_height_at(global_position.x, global_position.z)
	if global_position.y < ground_y - FLOOR_FORGIVENESS:
		global_position.y = ground_y + SPAWN_CLEARANCE
		velocity.y = maxf(velocity.y, 0.0)
		_gliding = false
		_diving = false


func _terrain() -> Node:
	## The terrain generator lives as a sibling of the player under World.
	var parent := get_parent()
	if parent == null:
		return null
	var t := parent.get_node_or_null("Terrain")
	if t != null and t.has_method("get_height_at"):
		return t
	return null


func _on_respawn() -> void:
	var target: Vector3 = Game.checkpoint if Game.has_checkpoint else _spawn_origin
	# Land ON the ground at the checkpoint, not at the stored (possibly
	# underground) coordinate - otherwise respawning drops you through the world
	# again and the player loops forever at the bottom of the map.
	_snap_to_ground(target)
	_gliding = false


func _on_game_won() -> void:
	set_process_input(false)


func _input(event: InputEvent) -> void:
	## Touch camera orbit is handled here (before the GUI) so drags that start
	## on top of HUD buttons still rotate the camera.
	if Game.is_paused or Game.has_won:
		return
	if event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.position.x > get_viewport().get_visible_rect().size.x * 0.40:
			_target_yaw -= drag.relative.x * MOUSE_SENS * STICK_SENS
			_target_pitch -= drag.relative.y * MOUSE_SENS * STICK_SENS
			_target_pitch = clampf(_target_pitch, -1.15, 0.62)


func _unhandled_input(event: InputEvent) -> void:
	if Game.is_paused or Game.has_won:
		return

	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		_target_yaw -= event.relative.x * MOUSE_SENS
		_target_pitch -= event.relative.y * MOUSE_SENS
		_target_pitch = clampf(_target_pitch, -1.15, 0.62)

	if event.is_action_pressed("party_next"):
		Game.next_character()
	if event.is_action_pressed("attack"):
		_do_attack()
	if event.is_action_pressed("skill"):
		_do_skill()
	if event.is_action_pressed("burst"):
		_do_burst()


func _physics_process(delta: float) -> void:
	if Game.is_paused:
		return

	_yaw = lerp_angle(_yaw, _target_yaw, 1.0 - exp(-16.0 * delta))
	_pitch = lerpf(_pitch, _target_pitch, 1.0 - exp(-16.0 * delta))
	_pivot.rotation = Vector3(_pitch, _yaw, 0.0)
	_update_camera_occlusion()

	_attack_cd = maxf(0.0, _attack_cd - delta)
	_skill_cd = maxf(0.0, _skill_cd - delta)
	if wander != null:
		wander.tick(delta)
	_combo_reset = maxf(0.0, _combo_reset - delta)
	if _combo_reset <= 0.0:
		_attack_combo = 0

	var input_dir := Input.get_vector("move_left", "move_right", "move_forward", "move_back")
	if Game.touch_active and Game.touch_move.length() > 0.05:
		input_dir = Game.touch_move

	var on_floor := is_on_floor()
	if on_floor:
		_double_jump_used = false
		_diving = false
		if _gliding:
			_gliding = false

	# --- gravity + glide --------------------------------------------------
	if not on_floor:
		var g: float = float(ProjectSettings.get_setting("physics/3d/default_gravity")) * GRAVITY_SCALE
		velocity.y -= g * delta
		if _gliding:
			velocity.y = maxf(velocity.y, GLIDE_FALL)
		else:
			velocity.y = maxf(velocity.y, -34.0)

	# --- jump / glide -----------------------------------------------------
	if Input.is_action_just_pressed("jump"):
		if on_floor:
			velocity.y = JUMP_VELOCITY
			FX.dust_puff(get_parent(), global_position, Color(0.92, 0.96, 1.0, 0.6))
		elif not _double_jump_used and not _gliding:
			velocity.y = DOUBLE_JUMP_VELOCITY
			_double_jump_used = true
			FX.ring_burst(get_parent(), global_position + Vector3(0, 0.6, 0), Color(0.7, 0.95, 1.0), 1.2)
		elif not _gliding and velocity.y < 1.0:
			_gliding = true

	# Hold jump in the air to open the wings.
	if not on_floor and not _gliding and Input.is_action_pressed("jump") and velocity.y < -3.0 and not _double_jump_used:
		_gliding = true

	# Plunge: attack while falling from a glide.
	if _gliding and Input.is_action_just_pressed("attack"):
		_gliding = false
		_diving = true
		velocity.y = -30.0

	if _diving and on_floor:
		_diving = false
		_plunge_impact()

	# --- movement ---------------------------------------------------------
	var sprinting := false
	var speed := WALK_SPEED
	if _gliding:
		speed = GLIDE_SPEED
		if Game.stamina > 0.0:
			Game.drain_stamina(GLIDE_DRAIN * delta)
			_stamina_regen_hold = 1.1
		else:
			_gliding = false
	else:
		sprinting = Input.is_action_pressed("sprint") and input_dir.length() > 0.1 and on_floor
		if sprinting and Game.stamina > 0.5:
			speed = SPRINT_SPEED
			Game.drain_stamina(SPRINT_DRAIN * delta)
			_stamina_regen_hold = 0.8
		else:
			sprinting = false
			_stamina_regen_hold = maxf(0.0, _stamina_regen_hold - delta)
			if _stamina_regen_hold <= 0.0 and Game.stamina < Game.MAX_STAMINA:
				Game.add_stamina(STAMINA_REGEN * delta)

	var cam_basis := Basis.from_euler(Vector3(0, _yaw, 0))
	var move := (cam_basis * Vector3(input_dir.x, 0.0, input_dir.y))
	if move.length() > 1.0:
		move = move.normalized()

	var accel := 18.0 if on_floor else (5.0 if _gliding else 3.2)
	if move.length() > 0.02:
		velocity.x = move_toward(velocity.x, move.x * speed, accel * delta * speed)
		velocity.z = move_toward(velocity.z, move.z * speed, accel * delta * speed)
		var target_face := atan2(-move.x, -move.z)
		var vis := _visual_node()
		if vis != null:
			vis.rotation.y = lerp_angle(vis.rotation.y, target_face, TURN_SPEED * delta)
	else:
		var drag := 20.0 if on_floor else 1.4
		velocity.x = move_toward(velocity.x, 0.0, drag * delta * speed)
		velocity.z = move_toward(velocity.z, 0.0, drag * delta * speed)

	move_and_slide()

	_guard_world_bounds()

	# Falling out of the world? Return to the checkpoint.
	if global_position.y < -60.0:
		_on_respawn()

	_update_animation(delta, Vector2(velocity.x, velocity.z).length(), on_floor, sprinting)

	# Elemental trail while sprinting/gliding.
	_trail_timer -= delta
	if _trail_timer <= 0.0 and (sprinting or _gliding):
		_trail_timer = 0.22 if sprinting else 0.14
		FX.sparkle(get_parent(), global_position + Vector3(0, 0.9, 0), Game.character()["color"])


func _update_animation(delta: float, speed: float, on_floor: bool, sprinting: bool) -> void:
	var arm_l := _rig_part("arm_l")
	var arm_r := _rig_part("arm_r")
	var leg_l := _rig_part("leg_l")
	var leg_r := _rig_part("leg_r")
	var torso := _rig_part("torso")
	var wings := _rig_part("wings")

	if torso == null or arm_l == null or arm_r == null or leg_l == null or leg_r == null:
		return
	if wings != null:
		wings.visible = _gliding

	if _gliding:
		var flap := sin(Time.get_ticks_msec() * 0.006) * 0.18
		if wings != null:
			wings.rotation.x = -0.55 + flap
		arm_l.rotation.x = lerpf(arm_l.rotation.x, -1.9, 9.0 * delta)
		arm_r.rotation.x = lerpf(arm_r.rotation.x, -1.9, 9.0 * delta)
		arm_l.rotation.z = lerpf(arm_l.rotation.z, 0.55, 9.0 * delta)
		arm_r.rotation.z = lerpf(arm_r.rotation.z, -0.55, 9.0 * delta)
		leg_l.rotation.x = lerpf(leg_l.rotation.x, 0.35, 8.0 * delta)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, -0.15, 8.0 * delta)
		torso.rotation.x = lerpf(torso.rotation.x, 0.18, 8.0 * delta)
		return

	if not on_floor:
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.5, 8.0 * delta)
		arm_r.rotation.x = lerpf(arm_r.rotation.x, 0.5, 8.0 * delta)
		arm_l.rotation.z = lerpf(arm_l.rotation.z, 0.25, 8.0 * delta)
		arm_r.rotation.z = lerpf(arm_r.rotation.z, -0.25, 8.0 * delta)
		leg_l.rotation.x = lerpf(leg_l.rotation.x, -0.35, 8.0 * delta)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, 0.3, 8.0 * delta)
		torso.rotation.x = lerpf(torso.rotation.x, -0.08, 8.0 * delta)
		return

	if speed < 0.4:
		_idle_time += delta
		_anim_phase = lerpf(_anim_phase, 0.0, 10.0 * delta)
		var breathe := sin(_idle_time * 1.8) * 0.035
		var sway := sin(_idle_time * 1.1) * 0.05
		arm_l.rotation.x = lerpf(arm_l.rotation.x, 0.1 + breathe, 7.0 * delta)
		arm_r.rotation.x = lerpf(arm_r.rotation.x, -0.08 - breathe, 7.0 * delta)
		arm_l.rotation.z = lerpf(arm_l.rotation.z, 0.12 + sway, 5.0 * delta)
		arm_r.rotation.z = lerpf(arm_r.rotation.z, -0.12 - sway, 5.0 * delta)
		leg_l.rotation.x = lerpf(leg_l.rotation.x, 0.0, 9.0 * delta)
		leg_r.rotation.x = lerpf(leg_r.rotation.x, 0.0, 9.0 * delta)
		torso.position.y = lerpf(torso.position.y, breathe * 0.35, 5.0 * delta)
		torso.rotation.x = lerpf(torso.rotation.x, 0.0, 6.0 * delta)
		var head := _rig_part("head")
		if head != null:
			head.rotation.y = sin(_idle_time * 0.55) * 0.22
		return

	_idle_time = 0.0
	var head := _rig_part("head")
	if head != null:
		head.rotation.y = lerpf(head.rotation.y, 0.0, 8.0 * delta)
	var rate := 10.5 if sprinting else 7.4
	_anim_phase += delta * rate * clampf(speed / WALK_SPEED, 0.55, 1.6)
	var amp := 0.85 if sprinting else 0.6
	var swing := sin(_anim_phase) * amp
	arm_l.rotation.x = swing
	arm_r.rotation.x = -swing
	arm_l.rotation.z = lerpf(arm_l.rotation.z, 0.06, 9.0 * delta)
	arm_r.rotation.z = lerpf(arm_r.rotation.z, -0.06, 9.0 * delta)
	leg_l.rotation.x = -swing * 1.05
	leg_r.rotation.x = swing * 1.05
	torso.rotation.x = lerpf(torso.rotation.x, 0.14 if sprinting else 0.05, 8.0 * delta)
	torso.position.y = lerpf(torso.position.y, absf(sin(_anim_phase)) * 0.03, 12.0 * delta)


func _do_attack() -> void:
	if _attack_cd > 0.0 or Game.is_paused:
		return
	_attack_cd = 0.42
	_attack_combo = (_attack_combo + 1) % 3
	_combo_reset = 1.1

	var data: Dictionary = Game.character()
	var power: float = float(data["attack"]) * (1.25 if _attack_combo == 2 else 1.0)
	var forward := get_forward()
	var hit_center: Vector3 = global_position + forward * 1.45 + Vector3(0, 0.95, 0)

	FX.slash(get_parent(), hit_center, forward, Game.character()["color"], _attack_combo)

	var arm := _rig_part("arm_r")
	arm.rotation.x = -2.3
	var tw := create_tween()
	tw.tween_property(arm, "rotation:x", 0.4, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(enemy):
			continue
		var to_enemy: Vector3 = (enemy as Node3D).global_position - global_position
		if to_enemy.length() < 2.6 and to_enemy.normalized().dot(forward) > 0.25:
			if enemy.has_method("take_hit"):
				enemy.take_hit(power, element_id, forward)

	# Melee hits build elemental energy.
	Game.add_energy(4.0)


func _do_skill() -> void:
	if _skill_cd > 0.0 or Game.is_paused:
		return
	var data: Dictionary = Game.character()
	_skill_cd = float(data["skill_cd"])
	_attack_cd = maxf(_attack_cd, 0.3)
	var forward := get_forward()
	var pos: Vector3 = global_position + forward * 2.0 + Vector3(0, 0.8, 0)

	FX.element_burst(get_parent(), pos, Game.character()["color"], int(data["element_id"]))
	Game.add_energy(12.0)
	skill_used.emit(element_id, pos, float(data["attack"]) * 2.2)

	# Damage everything in the skill radius.
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(enemy):
			continue
		var d: float = (enemy as Node3D).global_position.distance_to(pos)
		if d < 5.2 and enemy.has_method("take_hit"):
			enemy.take_hit(float(data["attack"]) * 2.4, element_id, forward)

	var r := _rig_part("arm_l")
	r.rotation.x = -2.6
	var tw := create_tween()
	tw.tween_property(r, "rotation:x", 0.2, 0.35).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _do_burst() -> void:
	var data: Dictionary = Game.character()
	var cost: float = float(data["burst_cost"])
	if not Game.spend_energy(cost) or Game.is_paused:
		return
	var pos := global_position + Vector3(0, 1.0, 0)
	FX.ultimate(get_parent(), pos, Game.character()["color"], int(data["element_id"]))
	burst_used.emit(element_id, pos, float(data["attack"]) * 3.6)
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(enemy):
			continue
		var d: float = (enemy as Node3D).global_position.distance_to(global_position)
		if d < 11.0 and enemy.has_method("take_hit"):
			enemy.take_hit(float(data["attack"]) * 3.2, element_id, Vector3.ZERO)
	Game.toast.emit("%s!" % data["burst_name"])


func _on_spell_cast(id: String, data: Dictionary) -> void:
	## Perform a Wander spell. The wheel has already checked Light and cooldown
	## and started the timer, so this only has to make the effect happen.
	if data.is_empty() or Game.is_paused:
		return
	var forward := get_forward()
	var origin: Vector3 = global_position + Vector3(0.0, 1.1, 0.0)
	var power: float = float(data.get("power", 1.0)) * float(Game.character()["attack"])
	# Mastery makes spells hit harder, the way levelling a skill does.
	var mastery := 1.0
	if wander != null:
		mastery = 1.0 + float(wander.level_of(id) - 1) * 0.06
	power *= mastery
	var element := int(data.get("element", 0))
	var color: Color = data.get("color", Game.character()["color"])
	var radius := float(data.get("radius", 0.0))
	var reach := float(data.get("range", 0.0))

	FX.element_burst(get_parent(), origin + forward * 1.4, color, element)
	FX.ring_burst(get_parent(), origin, color, 1.4)

	# Spatial spells relocate the caster instead of dealing damage.
	if id == "tide_step":
		var dest := global_position + forward * minf(reach, 14.0)
		var terrain := _terrain()
		if terrain != null:
			dest.y = terrain.get_height_at(dest.x, dest.z) + SPAWN_CLEARANCE
		global_position = dest
		velocity = Vector3.ZERO
		FX.sparkle(get_parent(), dest + Vector3(0, 1.0, 0), color)
		return

	var hit_point: Vector3 = origin + forward * maxf(reach, 2.5)
	var hit_any := false
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(enemy):
			continue
		var target := enemy as Node3D
		if target == null:
			continue
		var to_enemy: Vector3 = target.global_position - origin
		var dist := to_enemy.length()
		# Cone in front of the caster, widened for area spells.
		var aim := to_enemy.normalized().dot(forward)
		var in_cone := aim > 0.45
		var in_area := radius > 0.0 and dist < radius
		var along := dist < maxf(reach, radius)
		if (in_cone and along) or in_area:
			if enemy.has_method("take_hit"):
				enemy.take_hit(power, element, forward)
				hit_any = true
				hit_point = target.global_position

	FX.hit_flash(get_parent(), hit_point, color)
	if hit_any:
		Game.add_energy(3.0)

	# Swing the left arm so casting reads on the character model.
	var arm := _rig_part("arm_l")
	if arm != null:
		arm.rotation.x = -2.2
		var tw := create_tween()
		tw.tween_property(arm, "rotation:x", 0.2, 0.3).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _plunge_impact() -> void:
	var pos := global_position
	FX.shockwave(get_parent(), pos, Game.character()["color"])
	Game.add_energy(10.0)
	for enemy in get_tree().get_nodes_in_group("enemy"):
		if not is_instance_valid(enemy):
			continue
		if (enemy as Node3D).global_position.distance_to(pos) < 6.5 and enemy.has_method("take_hit"):
			enemy.take_hit(Game.attack_power() * 1.6, element_id, Vector3.ZERO)


func take_damage(amount: float, from: Vector3) -> void:
	Game.damage(amount)
	FX.hit_flash(get_parent(), global_position + Vector3(0, 1.0, 0), Color(1, 0.35, 0.3))
	var push := (global_position - from)
	push.y = 0.0
	if push.length() > 0.01:
		velocity += push.normalized() * 4.5 + Vector3(0, 2.0, 0)


func get_camera_yaw() -> float:
	return _yaw


func get_forward() -> Vector3:
	## Facing direction, robust to a rig that failed to build: fall back to the
	## camera yaw so combat and FX never read a null node.
	var vis := _visual_node()
	if vis != null:
		return -vis.global_transform.basis.z
	return Vector3(-sin(_yaw), 0.0, -cos(_yaw))


func skill_ready_ratio() -> float:
	var cd: float = float(Game.character()["skill_cd"])
	return 1.0 - clampf(_skill_cd / maxf(cd, 0.01), 0.0, 1.0)


func set_control_enabled(enabled: bool) -> void:
	set_physics_process(enabled)
