extends MultiMeshInstance

# Main settings
export var verbose = false
export var random_seed = 0
export var far_distance = 0.1
export var far_fade = false
export var spacing = 10.0
export var area_1_treshold = 0.3
export var area_2_treshold = 0.3
export var area_2_size_multiplier = 10.0
export var area_affects_treshold = true
export var slope_min = 0.0
export var slope_max = 0.2
export var align_with_ground = true
export var altitude_min = 8.0
export var altitude_max = 1024.0
export var base_scale = 1.0
export var random_scale = 0.3
export var area_affects_scale = true
var pool_size = 0

# These are calculated from ground_size
var view_distance
var upd_distance
var col_distance

var thread = Thread.new()
var view_point
var last_point
var gen_time

var lod_multimesh
var lod_dist = 16.0
var has_lod = false
var use_only_lod = false

var has_collider = false
var col_shape
export (Mesh) var collision_mesh

var hidden_transform
var noise = preload("res://Scripts/HeightGenerator.gd").new()

var quitting = false
var mutex = Mutex.new()

func _ready():
	
	set_process(false)
	if(is_visible_in_tree() == false):
		return
	
	noise.init()
	
	view_distance = float(Globals.ground_size)
	upd_distance = float(view_distance)
	view_distance *= far_distance
	upd_distance *= far_distance / 4.0
	col_distance = upd_distance * 1.5
	lod_dist = view_distance * 0.5
	
	if(use_only_lod):
		lod_dist = -1
	
	var fade_end = view_distance - 8.0
	var fade_start = fade_end - 16.0
	
	multimesh.set_instance_count(pool_size)
	
	if(has_node("Lod")):
		lod_multimesh = get_node("Lod")
		lod_multimesh.multimesh.set_instance_count(pool_size)
		has_lod = true
		
		if(far_fade):
			$Lod.material_override.set_shader_param("fade_start", fade_start);
			$Lod.material_override.set_shader_param("fade_end", fade_end);
	
	if(collision_mesh != null):
		has_collider = true
		col_shape = collision_mesh.create_convex_shape()
	
	
	
	random_seed = float(random_seed) * 1234.56
	
	view_point = get_vp()
	last_point = view_point
	
	hidden_transform = Transform.IDENTITY.scaled(Vector3(1,1,1))
	hidden_transform.origin = Vector3(0.0, -9999.9, 0.0)
	
	call_deferred("start_generating")

func get_vp():
	var p = get_viewport().get_camera().get_global_transform().origin
#	p -= get_viewport().get_camera().get_global_transform().basis.z * view_distance * 0.8
	p.y = 0.0
	return p

func _process(delta):
	view_point = get_vp()
	if(last_point.distance_to(view_point) > upd_distance):
		start_generating()
	
	

func start_generating():
#	print("Start generating ground objects, seed = ", game_seed)
	gen_time = OS.get_ticks_msec()
	set_process(false)
	view_point = get_vp()
	view_point.x = stepify(view_point.x, spacing)
	view_point.z = stepify(view_point.z, spacing)
	
	thread.start(self, "generate", view_point)

func finish_generating():
	
	if(quitting):
		return
	
	var arr = thread.wait_to_finish()
	
	if(arr.size() > pool_size):
		pool_size += (arr.size() - pool_size) * 2
		
		if(verbose):
			print("Set max ", name, " count to ", pool_size)
		
		multimesh.set_instance_count(pool_size)
		if(has_lod):
			lod_multimesh.multimesh.set_instance_count(pool_size)
	
	var cam_pos = get_viewport().get_camera().get_global_transform().origin
	
	var i = 0
	if(has_lod):
		var new_arr = []
		var lod_arr = []
		
		while(i < arr.size()):
			var tp = view_point + arr[i].origin
			tp -= cam_pos
			var d = Vector2(tp.x, tp.z).length()
			if(d < lod_dist):
				new_arr.append(arr[i])
			else:
				lod_arr.append(arr[i])
			i += 1
		i = 0
		while(i < pool_size):
			if(i < new_arr.size()):
				multimesh.set_instance_transform(i, new_arr[i])
			else:
				multimesh.set_instance_transform(i, hidden_transform)
			if(i < lod_arr.size()):
				lod_multimesh.multimesh.set_instance_transform(i, lod_arr[i])
			else:
				lod_multimesh.multimesh.set_instance_transform(i, hidden_transform)
			i += 1
	else:
		i = 0
		while(i < pool_size):
			if(i < arr.size()):
				multimesh.set_instance_transform(i, arr[i])
			else:
				multimesh.set_instance_transform(i, hidden_transform)
			i += 1
	
	gen_time = OS.get_ticks_msec() - gen_time
	if(verbose or gen_time >= 2000.0):
		print(name," x ", arr.size()," in ", gen_time / 1000.0, " s")
	transform.origin = view_point
	last_point = view_point
	
	if(Globals.generate_just_once == false):
		set_process(true)

func generate(userdata):
	
	var pos = userdata
	var arr = []
	
	pos.x = stepify(pos.x, spacing)
	pos.z = stepify(pos.z, spacing)
	
	var sb
	if(has_collider):
		sb = StaticBody.new()
		sb.name = "StaticBody"
	
	var w = stepify(float(view_distance), spacing)
	var x = -w
	while(x < w):
		var z = -w
		while(z < w):
			
			# Not sure if I'm doing this right
			if(mutex.try_lock() == OK):
				if(quitting):
					mutex.unlock()
					return # Break this loop
				else:
					mutex.unlock()
			
			var xx = x + pos.x
			var zz = z + pos.z
			
			var r = noise._noise.get_noise_2d((xx+random_seed) * 123.0 / area_2_size_multiplier, zz * 123.0 / area_2_size_multiplier + random_seed)
			
			if(r >= area_2_treshold):
				var rp = Vector3(r, 0.0, 0.0)
				var a2_aff = clamp(((r - area_2_treshold) / (1.0 - area_2_treshold)) * 3.0, 0.0, 1.0)
				
				r = noise._noise.get_noise_2d(xx * 1234.0, zz * 1234.0)
				
				if(area_affects_treshold):
					r *= 0.5 + a2_aff
				
				if(r >= area_1_treshold):
					# Randomize position
					rp.z = r
					rp *= 1000.0
					xx += sin(rp.x) * spacing
					zz += cos(rp.z) * spacing
					
					# Y-position
					var y = noise.get_h(Vector3(xx, 0.0, zz)) + 0.3
					if(y >= altitude_min && y <= altitude_max):
						
						# Slopes
						var difx = noise.get_h(Vector3(xx + 2.0, 0.0, zz))
						difx -= noise.get_h(Vector3(xx - 2.0, 0.0, zz))
						var difz = noise.get_h(Vector3(xx, 0.0, zz + 2.0))
						difz -= noise.get_h(Vector3(xx, 0.0, zz - 2.0))
						
						var dif = max(abs(difx), abs(difz)) / 5.0
#						print(dif)
						
						if(dif >= slope_min && dif <= slope_max):
							var p = Vector3(xx - pos.x, y, zz  - pos.z)
							
							# Randomize scale
							var s = sin(noise._noise.get_noise_2d((xx) * 1000.0 + (zz) * 1000.0, 0.0) * 100.0)
							s = base_scale + (s * random_scale)
#							print(base_scale)
							
							# Create transform
							var ya = r * 100.0
							var xa = -difz / 7.0
							var za = difx / 7.0
#							var tr = Transform(transform.basis.rotated(Vector3(0,1,0), ya), p / s).scaled(Vector3(s, s, s))
							var tr = Transform.IDENTITY.rotated(Vector3(0,1,0), ya)
							
							if(align_with_ground):
								var quat = Quat(tr.basis)
								quat.set_euler(Vector3(xa, 0.0, za))
								quat = Quat(Basis(quat).y, ya)
								tr.basis = Basis(quat);
							if(area_affects_scale):
								s *=  0.5 + a2_aff
							tr.basis = tr.basis.scaled(Vector3(s, s, s))
							tr.origin = p;
							
							
							# Append transform to list
							arr.append(tr)
							
							# Add a CollisionShape
							if(has_collider):
								if(abs(x) < col_distance):
									if(abs(z) < col_distance):
										var cs = CollisionShape.new()
										cs.set_shape(col_shape)
										cs.transform = tr
										sb.add_child(cs)
			
			z += spacing
		x += spacing
	
	if(has_collider):
		call_deferred("new_sb", sb)
	
	call_deferred("finish_generating")
	return arr

var old_sb
func new_sb(sb):
	
	if(quitting):
		return
	
	if(old_sb != null):
		if(old_sb.is_queued_for_deletion() == false):
			old_sb.queue_free()
	
	add_child(sb)
	old_sb = sb

func _notification(what):
	if what == MainLoop.NOTIFICATION_WM_QUIT_REQUEST:
		
		# Not sure if I'm doing this right
		mutex.lock()
		quitting = true # Break loop inside the thread
		mutex.unlock()
		
		if(thread.is_active()):
			thread.wait_to_finish()
