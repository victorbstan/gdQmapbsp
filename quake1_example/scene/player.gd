extends CharacterBody3D
class_name QmapbspQuakePlayer

# THESE VALUES WERE APPROXIMATELY MEASURED
# TO MATCH AN ORIGINAL AS CLOSE AS POSSIBLE >/\<

# my definition is 32 units/1 meter

var viewer : QmapbspQuakeViewer

@export var max_speed : float = 10
@export var max_air_speed : float = 0.5
@export var max_liquid_speed : float = 5
@export var accel : float = 100
@export var fric : float = 8
@export var sensitivity : float = 0.0025
@export var stairstep := 0.6
@export var stairstep_liquid := 1.25
@export var step_buffer := 1.125 # multiplier
@export var gravity : float = 20
@export var gravity_liquid : float = 15
@export var jump_up : float = 7.6
@export var jump_up_liquid : float = 1.9
@export var max_time_submerged : float = 5

var noclip : bool = false

@onready var col : CollisionShape3D = $col
@onready var around : Node3D = $around
@onready var head : Node3D = $around/head
@onready var camera : Camera3D = $around/head/cam
@onready var staircast : ShapeCast3D = $staircast
@onready var jump : AudioStreamPlayer3D = $jump
@onready var origin : Node3D = $origin

var wishdir : Vector3
var wish_jump : bool = false
var auto_jump : bool = true
var smooth_y : float
var time_submerged : float = 0
var fluid : QmapbspQuakeFluidVolume
var low_level := PhysicsPointQueryParameters3D.new()
var mid_level := PhysicsPointQueryParameters3D.new()
var eye_level := PhysicsPointQueryParameters3D.new()
var s_level : int = 0

# audio paths, naming convention: s_type + "_audio
const jump_audio = [ &"player/plyrjmp8.wav" ]
const axe_pain_audio = [ &"player/axhit1.wav" ]
const pain_audio = [ &"player/pain1.wav", &"player/pain2.wav", &"player/pain3.wav", &"player/pain4.wav", &"player/pain5.wav", &"player/pain6.wav" ]
const water_pain_audio = [ &"player/drown1.wav", &"player/drown2.wav" ]
const lava_pain_audio = [ &"player/lburn1.wav", &"player/lburn2.wav" ]
const slime_pain_audio = [ &"player/lburn1.wav", &"player/lburn2.wav" ] # the same as lava
const tele_death_audio = [ &"player/teledth1.wav" ]
const death_audio = [ &"player/death1.wav",  &"player/death2.wav",  &"player/death3.wav",  &"player/death4.wav",  &"player/death5.wav" ]
const water_death_audio = [ &"player/h2odeath.wav" ]
const gib_death_audio = [ &"player/gib.wav", &"player/udeath.wav" ]
const air_gasp_audio = [ &'player/gasp1.wav', &'player/gasp2.wav']
	
# cache some values:
var _p_size : Vector3 # player
var _p_height : float
var _p_half_height : float
var _p_low_pos_diff : Vector3
var _sc_size : Vector3 # stair check
var _sc_height : float
var _sc_half_height : float
var _sc_pos : Vector3
var _head_height : float # eye-level
	
	
func _ready() :
	# player height
	_p_size = col.shape.size
	_p_height = _p_size.y
	_p_half_height = _p_height / 2
	_p_low_pos_diff = Vector3(0, _p_half_height, 0) # foot/bottom level
	# staircast height
	_sc_pos = staircast.position
	_sc_size = staircast.shape.size
	_sc_height = _sc_size.y
	_sc_half_height = _sc_height / 2
	# around (head container)
	_head_height = around.position.y
	# setup query points
	low_level.set_collide_with_areas(true)
	low_level.set_collide_with_bodies(false)
	low_level.set_collision_mask(pow(2, 3-1)) # 3rd layer is LIQUID
	mid_level.set_collide_with_areas(true)
	mid_level.set_collide_with_bodies(false)
	mid_level.set_collision_mask(pow(2, 3-1)) # 3rd layer is LIQUID
	eye_level.set_collide_with_areas(true)
	eye_level.set_collide_with_bodies(false)
	eye_level.set_collision_mask(pow(2, 3-1)) # 3rd layer is LIQUID
	
	
func hurt(type: StringName, amount: int, duration: float) :
	# TODO: apply damage, flush out hurt types, etc.
	match type :
		&'water' :
			_play_sound(&'water_pain')
		&'lava' :
			_play_sound(&'lava_pain')
		&'slime' :
			_play_sound(&'slime_pain')
		_ : 
			print('UKNOWN HURT TYPE!')


func teleport_to(dest : Node3D, play_sound : bool = false) :
	global_position = dest.global_position
	var old := around.rotation
	around.rotation = dest.rotation
	old = around.rotation - old
	velocity = velocity.rotated(Vector3.UP, old.y)
	if play_sound :
		var p := AudioStreamPlayer3D.new()
		p.stream = (
			viewer.hub.load_audio('misc/r_tele%d.wav' % (randi() % 5 + 1))
		)
		p.finished.connect(func() : p.queue_free())
		viewer.add_child(p)
		p.global_position = global_position
		p.play()


func accelerate(in_speed : float, delta : float) -> void :
	velocity += wishdir * (
		clampf(in_speed - velocity.dot(wishdir), 0, accel * delta)
	)


func friction(delta : float) -> void :
	var speed : float = velocity.length()
	var svec : Vector3
	if speed > 0 :
		svec = velocity * maxf(speed - (
			fric * speed * delta
		), 0) / speed
	if speed < 0.1 :
		svec = Vector3()
	velocity = svec


func move_ground(delta : float) -> void :
	friction(delta)
	accelerate(max_speed, delta)
	_stairs(delta)
	move_and_slide()
	_coltest()
	_ceiling_test()
	
	
func move_air(delta : float) -> void :
	accelerate(max_air_speed, delta)
	_stairs(delta)
	move_and_slide()
	_coltest()
	
	
func move_liquid(delta : float) -> void :
	friction(delta)
	accelerate(max_liquid_speed, delta)
	_stairs(delta)
	move_and_slide()
	_coltest()
	_ceiling_test()
	
	
func move_noclip(delta : float) -> void :
	friction(delta)
	accelerate(max_speed, delta)
	translate(velocity * delta)
	_watercoltest()

func _physics_process(delta : float) -> void :
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED :
		return
		
	wishdir = (head if noclip or fluid else around).global_transform.basis * Vector3((
		Input.get_axis(&"q1_move_left", &"q1_move_right")
	), 0, (
		Input.get_axis(&"q1_move_forward", &"q1_move_back")
	)).normalized()
	
	if noclip :
		move_noclip(delta)
		return
	
	if auto_jump :
		wish_jump = Input.is_action_pressed(&"q1_jump")
	else :
		if !wish_jump and Input.is_action_just_pressed(&"q1_jump") :
			wish_jump = true
		if Input.is_action_just_released(&"q1_jump") :
			wish_jump = false
	
	# entered liquid volume
	if fluid : _process_liquid_hurt(delta)
	
	if _can_swim() : # half-way in liquid
		# slighly trash movement ;)
		if wish_jump :
			velocity.y = jump_up_liquid
		# apply gravity if not moving horizontally
		if not (wishdir.x > 0 or wishdir.z > 0 or wish_jump) :
			velocity.y -= gravity_liquid * delta
		move_liquid(delta)
	else :
		if is_on_floor() :
			if wish_jump :
				_play_sound(&'jump')
				velocity.y = jump_up
				move_air(delta)
				wish_jump = false
			else :
				velocity.y = 0
				move_ground(delta)
		else :
			velocity.y -= gravity * delta
			move_air(delta)
	
	if is_zero_approx(smooth_y) : smooth_y = 0.0
	else :
		smooth_y /= step_buffer
		around.position.y = smooth_y + _head_height
		
var ppqp_water : PhysicsPointQueryParameters3D
func _coltest() -> void :
	for i in get_slide_collision_count() :
		var k := get_slide_collision(i)
		for j in k.get_collision_count() :
			var obj := k.get_collider(j)
			if obj is QmapbspQuakeClipProxyStatic :
				obj = obj.get_parent()
			if obj is QmapbspQuakeClipProxyAnimated :
				obj = obj.get_parent()
				
			if obj.has_method(&'_player_touch') :
				obj._player_touch(self, k.get_position(j), k.get_normal(j))
				return
	_watercoltest()
		
func _watercoltest() -> void :
	# water touch test
	if !ppqp_water :
		ppqp_water = PhysicsPointQueryParameters3D.new()
		ppqp_water.collision_mask = 0b10
		ppqp_water.collide_with_bodies = false
		ppqp_water.collide_with_areas = true
		
	fluid = null
	ppqp_water.position = origin.global_position
	var arr := get_world_3d().direct_space_state.intersect_point(ppqp_water)
	if !arr.is_empty() :
		fluid = arr[0]["collider"]
		
func _input(event : InputEvent) -> void :
	if Input.get_mouse_mode() != Input.MOUSE_MODE_CAPTURED :
		return
		
	if Input.is_action_just_pressed(&'q1_toggle_noclip') :
		toggle_noclip()
	
	if event is InputEventMouseMotion :
		var r : Vector2 = event.relative * -1
		head.rotate_x(r.y * sensitivity)
		around.rotate_y(r.x * sensitivity)
		
		var hrot = head.rotation
		hrot.x = clampf(hrot.x, -PI/2, PI/2)
		head.rotation = hrot
		
#func _fluid_enter(f : QmapbspQuakeFluidVolume) :
#	fluid = f
#
#func _fluid_exit(f : QmapbspQuakeFluidVolume) :
#	if f == fluid : fluid = null

#########################################

func toggle_noclip() :
	noclip = !noclip
