extends SceneTree
## The colony spike's bench (docs/colony-spike.md): N fake creatures of M goo cells
## each, kept moving and now and then running into each other, timed per physics frame.
##
##   godot --headless --fixed-fps 60 --path . -s tools/colony_bench.gd -- [options]
##
## Modes (--mode=):
##   colony  (default) the creatures in a GooColony (src/colony.rs): cells that are not
##           nodes, optional core cells, bonds holding each creature together, threads.
##   nodes   today's path: every cell a Goo2D in a GooWorld2D (merges and splits off,
##           never settling); nothing holds a creature together but its common push.
##   kernel  today's kernel alone: every cell a ring in a GooKernel driven from here
##           (no nodes), the pair passes on as in a world (--pair-passes=off: without).
## Options:
##   --creatures=N --cells=M      (default 4 × 150)
##   --shape=blob|worm|ragged     the creature's outline (worm: 5 cells wide)
##   --mix=uniform|mixed          every cell the smallest size, or 14..26 px (at unit 0.5)
##   --beads=K                    beads of the smallest cell (12 is GooTuning's); larger
##                                cells keep their count minus the same difference
##   --cores=on|off               enclosed cells as cores (colony mode)
##   --threads=T --substeps=S --cell-scale=X --bond-scale=X
##   --intra=on|off|cores         contacts between a creature's own cells: all, none (the
##                                bonds alone), or only those of its cores
##   --hold=bonds|adhesion        what holds a creature together: the spike's bonds, set
##                                once at spawn (default), or adhesion (milestone 1,
##                                docs/colony-adhesion.md: cells stick where they touch,
##                                captured in the first frame)
##   --capture=PX --break=F       adhesion's capture gap and break force at unit 1 (scaled
##                                by UNIT; GooColonySim's CAPTURE and BREAK_FORCE by
##                                default); --sticky: sticky-only walls
##   --exposure=on|off            milestone 2 (docs/colony-exposure.md): exposure, pockets
##                                and the outline computed in the step (adhesion only)
##   --auto-cores=on|off          rings wholly enclosed become cores, exposed cores rings
##   --skip=none|cells|beads      what of a creature takes no part in contacts with others
##                                (none: the default; cells: cells with no exposed bead;
##                                beads: every enclosed bead; both unsound, see the doc)
##   --core-contact=X             cores' contacts with their own creature compliant (0.3 in
##                                GooColonySim.EXPOSURE_OPTIONS; 0 rigid)
##   --core-anchors=on|off        beads anchored on cores' rims
##   --exposure-every=F --exposure-hot=F   the exposure pass's safety net (every F frames,
##                                30) and how long it runs every frame after a parting (6)
##   --m2                         all of milestone 2 at once: GooColonySim.EXPOSURE_OPTIONS
##   --water-drag=on|off          the game's water drag on exposed edges, in the kernel
##                                (GooColonySim.DRAG_OPTIONS); the linear damping --drag
##                                stays unless --drag=0
##   --water=uniform|cells        the water's velocity: one per creature (zero), or each
##                                cell's sampled in GDScript from a stand-in vortex every frame
##                                (what feeding a FlowField's velocities costs)
##   --sleep=F                    the fraction of creatures asleep (colony mode)
##   --coarse=F                   the fraction stepped every other frame (colony mode)
##   --frames=F --warmup=W        measured frames after W warm-up frames (300, 60)
##   --draw=none|region|world|attrs|rebuild|multimesh   colony mode's drawing (needs a
##                                renderer: run under xvfb-run with --rendering-driver
##                                opengl3, not --headless); nodes mode always draws its
##                                Goo2D skins in _process
##   --png=PATH                   saves the last frame (with a renderer)
##   --zoom=Z                     draws Z screen px per px, following creature 0
##   --drag=D                     the linear damping standing in for water drag (1.5 /s)
##   --seed=S
##   --seal=PX                    the gap between two cells _classify() counts as sealed
##                                (CAPTURE, 1.5 px)
## Special runs (they print and quit):
##   --ratios                     ring/core counts of packed designs per shape, mix, size
##   --promote-test               promotion and demotion: cost and how far neighbours jump
##
## Per frame it prints min / median / p95 (ms) over the measured frames of: kernel (the
## kernel's own step), holds (the bonds; CPU time summed over threads), script (the
## physics frame's GDScript: the push and everything around the step but the kernel's
## step; nodes mode: every _physics_process but the step), push (part of script),
## draw (drawing set-up: colony: building the arrays in Rust, crossing into Godot,
## RenderingServer updates; nodes: every Goo2D's _process), physics (kernel + script),
## and the colony's breakdown and health. All times are this machine's wall clock.

const UNIT: float = 0.5
const CAPTURE: float = 1.5
const PUSH: float = 250.0
const RETARGET_TIME: float = 5.0

var _mode: String = "colony"
var _creatures: int = 4
var _cells: int = 150
var _shape: String = "blob"
var _mix: String = "uniform"
var _beads: int = 12
var _cores: bool = true
var _threads: int = 1
var _substeps: int = 6
var _cell_scale: float = 1.0
var _intra: bool = true
# --intra=cores: only a creature's cores collide with its own beads and cores.
var _core_contacts: bool = false
var _bond_scale: float = 1.0
var _hold: String = "bonds"
var _capture: float = -1.0
var _break: float = -1.0
var _sticky: bool = false
var _exposure: bool = false
var _auto_cores: bool = false
var _skip: int = 0
var _core_contact: float = 0.0
var _core_anchors: bool = false
var _water_drag: bool = false
var _water: String = "uniform"
var _exp_every_hot := Vector2i(30, 6)
var _sleep: float = 0.0
var _coarse: float = 0.0
var _frames: int = 300
var _warmup: int = 60
var _draw: String = "none"
var _png: String = ""
var _drag: float = 1.5
var _seed: int = 20261112
var _pair_passes: bool = true
# How far apart two cells may be and still seal the gap between them (_classify()).
var _seal: float = CAPTURE
# Screen px per canvas px, following creature 0 (0: the whole arena fits the window).
var _zoom: float = 0.0

var _rng := RandomNumberGenerator.new()
var _frame: int = 0
var _arena := Rect2()
var _targets: Array[Vector2] = []
var _retarget: PackedFloat32Array = PackedFloat32Array()
var _samples: Dictionary = {}
var _health: Dictionary = {}

# colony mode
var _colony: GooColony
var _meshes: Array[RID] = []
var _items: Array[RID] = []
var _multimeshes: Array[RID] = []
var _world_mesh: RID
var _disc: RID
var _color_bytes: int = 4
var _canvas: Node2D
var _materials: Array[ShaderMaterial] = []

# nodes and kernel modes
var _world: GooWorld2D
var _bodies: Array = []   # per creature: Array of Goo2D
var _kernel: GooKernel
var _keys: Array = []     # per creature: PackedInt64Array of ring keys
var _bead_masses: Array = []   # per creature: PackedFloat32Array
var _t_phys_first: int = 0
var _t_push: int = 0
var _t_proc_first: int = 0
var _design_cache: Dictionary = {}
var _done: bool = false
var _switches: int = 0
var _switch_frames: PackedInt64Array = PackedInt64Array([0, 0])

# ---- Setup ----

func _initialize() -> void:
	var ratios := false
	var promote := false
	for arg: String in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--mode="): _mode = value
		elif arg.begins_with("--creatures="): _creatures = int(value)
		elif arg.begins_with("--cells="): _cells = int(value)
		elif arg.begins_with("--shape="): _shape = value
		elif arg.begins_with("--mix="): _mix = value
		elif arg.begins_with("--beads="): _beads = int(value)
		elif arg.begins_with("--cores="): _cores = value == "on"
		elif arg.begins_with("--threads="): _threads = int(value)
		elif arg.begins_with("--substeps="): _substeps = int(value)
		elif arg.begins_with("--cell-scale="): _cell_scale = float(value)
		elif arg.begins_with("--intra="):
			_intra = value == "on"
			_core_contacts = value == "cores"
		elif arg.begins_with("--bond-scale="): _bond_scale = float(value)
		elif arg.begins_with("--hold="): _hold = value
		elif arg.begins_with("--capture="): _capture = float(value)
		elif arg.begins_with("--break="): _break = float(value)
		elif arg == "--sticky": _sticky = true
		elif arg.begins_with("--exposure="): _exposure = value == "on"
		elif arg.begins_with("--auto-cores="): _auto_cores = value == "on"
		elif arg.begins_with("--skip="): _skip = ["none", "cells", "beads"].find(value)
		elif arg.begins_with("--core-contact="): _core_contact = float(value)
		elif arg.begins_with("--core-anchors="): _core_anchors = value == "on"
		elif arg == "--m2":
			_exposure = true
			_auto_cores = true
			_core_contact = GooColonySim.EXPOSURE_OPTIONS["core_contact"]
			_core_anchors = true
		elif arg.begins_with("--water-drag="): _water_drag = value == "on"
		elif arg.begins_with("--water="): _water = value
		elif arg.begins_with("--exposure-every="): _exp_every_hot.x = int(value)
		elif arg.begins_with("--exposure-hot="): _exp_every_hot.y = int(value)
		elif arg.begins_with("--sleep="): _sleep = float(value)
		elif arg.begins_with("--coarse="): _coarse = float(value)
		elif arg.begins_with("--frames="): _frames = int(value)
		elif arg.begins_with("--warmup="): _warmup = int(value)
		elif arg.begins_with("--draw="): _draw = value
		elif arg.begins_with("--png="): _png = value
		elif arg.begins_with("--drag="): _drag = float(value)
		elif arg.begins_with("--seed="): _seed = int(value)
		elif arg.begins_with("--pair-passes="): _pair_passes = value == "on"
		elif arg.begins_with("--seal="): _seal = float(value)
		elif arg.begins_with("--zoom="): _zoom = float(value)
		elif arg == "--ratios": ratios = true
		elif arg == "--promote-test": promote = true
		else:
			push_error("colony_bench: unknown option %s" % arg)
	GooTuning.unit = UNIT
	_rng.seed = _seed
	if ratios:
		_print_ratios()
		quit(0)
		return
	if promote:
		_promote_test()
		quit(0)
		return
	var design := _design(_shape, _mix, _cells, _seed)
	var kinds := _classify(design) if _cores and _mode == "colony" else PackedByteArray()
	var bound := 0.0
	for c: Vector3 in design:
		bound = maxf(bound, Vector2(c.x, c.y).length() + c.z)
	# Creatures on a grid 3.2 bounding radii apart, each turned at random: about a
	# third of the arena covered, so they meet now and then.
	var columns := ceili(sqrt(float(_creatures)))
	var rows := ceili(float(_creatures) / columns)
	var spacing := 3.2 * bound
	_arena = Rect2(0, 0, columns * spacing, rows * spacing)
	var starts: Array[Transform2D] = []
	for i: int in _creatures:
		var at := Vector2((i % columns + 0.5) * spacing, (i / columns + 0.5) * spacing)
		starts.append(Transform2D(_rng.randf() * TAU, at))
		_targets.append(_random_target())
		_retarget.append(_rng.randf() * RETARGET_TIME)
	var ring_count := 0
	for k: int in kinds:
		ring_count += 1 - k
	print("colony_bench: mode %s, %d creatures × %d cells (%s, %s), beads %d, cores %s (%d rings, %d cores per creature), threads %d, substeps %d, draw %s, arena %.0f × %.0f px" % [
		_mode, _creatures, design.size(), _shape, _mix, _beads, "on" if not kinds.is_empty() else "off",
		ring_count if not kinds.is_empty() else design.size(), design.size() - ring_count if not kinds.is_empty() else 0,
		_threads, _substeps, _draw, _arena.size.x, _arena.size.y])
	match _mode:
		"colony": _build_colony(design, kinds, starts)
		"nodes": _build_nodes(design, starts)
		"kernel": _build_kernel(design, starts)
		_:
			push_error("colony_bench: unknown mode %s" % _mode)
			quit(1)
			return
	if DisplayServer.get_name() != "headless":
		RenderingServer.viewport_set_measure_render_time(root.get_viewport_rid(), true)
	var first := Clock.new(self, true)
	first.process_physics_priority = -100000
	first.process_priority = -100000
	root.add_child(first)
	var last := Clock.new(self, false)
	last.process_physics_priority = 100000
	last.process_priority = 100000
	root.add_child(last)

func _random_target() -> Vector2:
	return Vector2(_rng.randf_range(_arena.position.x, _arena.end.x), _rng.randf_range(_arena.position.y, _arena.end.y))

# A node at the start or the end of each frame's physics and process callbacks.
class Clock extends Node:
	var bench: Object
	var first: bool
	func _init(b: Object, is_first: bool) -> void:
		bench = b
		first = is_first
	func _physics_process(delta: float) -> void:
		bench.call("_on_physics", first, delta)
	func _process(_delta: float) -> void:
		bench.call("_on_process", first)

# A world for today's path: no merges, no splits, nothing settling, the drag's damping.
class CellWorld extends GooWorld2D:
	var drag: float = 1.5
	func may_merge(_a: Goo2D, _b: Goo2D) -> bool:
		return false
	func may_split(_body: Goo2D) -> bool:
		return false
	func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
		var t := super(shape, tags)
		t["linear_damp"] = drag
		t["settle_speed"] = 0.0
		return t

# ---- Designs ----

## A creature's cells packed edge to edge, each new cell placed touching two others
## where the shape's score is lowest: [x, y, radius] about the origin.
func _design(shape: String, mix: String, count: int, seed_value: int) -> Array[Vector3]:
	var key := "%s/%s/%d/%d" % [shape, mix, count, seed_value]
	if _design_cache.has(key):
		return _design_cache[key]
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var base := GooTuning.min_radius()
	var phases := [rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU]
	var half_width := 5.0 * base * (1.0 if mix == "uniform" else 1.25)
	var cells: Array[Vector3] = []
	var hash := {}
	var cell_size := 4.0 * base
	var pairs: Array[Vector2i] = []
	var first_r := _next_radius(rng, mix, base)
	cells.append(Vector3(0, 0, first_r))
	_hash_add(hash, cell_size, 0, Vector2.ZERO)
	var second_r := _next_radius(rng, mix, base)
	cells.append(Vector3(first_r + second_r, 0, second_r))
	_hash_add(hash, cell_size, 1, Vector2(first_r + second_r, 0))
	pairs.append(Vector2i(0, 1))
	var pending := 0.0
	while cells.size() < count:
		var r := pending if pending > 0.0 else _next_radius(rng, mix, base)
		pending = 0.0
		var best := INF
		var best_at := Vector2.ZERO
		var dead: Array[int] = []
		for pi: int in pairs.size():
			var a := cells[pairs[pi].x]
			var b := cells[pairs[pi].y]
			var free := false
			for side: float in [-1.0, 1.0]:
				var at := _tangent(a, b, r, side)
				if not at.is_finite() or _overlaps(cells, hash, cell_size, at, r):
					continue
				free = true
				var score := _score(shape, at, r, half_width, phases) + rng.randf() * 0.01
				if score < best:
					best = score
					best_at = at
			if not free and r <= base * 1.001:
				dead.append(pi)
		for k: int in range(dead.size() - 1, -1, -1):
			pairs.remove_at(dead[k])
		if best == INF:
			# No spot touching two cells: one touching a single cell, anywhere around it.
			for ci: int in cells.size():
				var c := cells[ci]
				for s: int in 16:
					var at := Vector2(c.x, c.y) + Vector2.from_angle(TAU * s / 16.0) * (c.z + r)
					if _overlaps(cells, hash, cell_size, at, r):
						continue
					var score := _score(shape, at, r, half_width, phases)
					if score < best:
						best = score
						best_at = at
		if best == INF:
			if r > base * 1.001:
				# No room for one this big: the smallest size instead.
				pending = base
				continue
			break
		var index := cells.size()
		cells.append(Vector3(best_at.x, best_at.y, r))
		for other: int in _hash_near(hash, cell_size, best_at):
			var o := cells[other]
			if Vector2(o.x, o.y).distance_to(best_at) <= o.z + r + 0.01:
				pairs.append(Vector2i(other, index))
		_hash_add(hash, cell_size, index, best_at)
	# About the centroid.
	var mean := Vector2.ZERO
	for c: Vector3 in cells:
		mean += Vector2(c.x, c.y)
	mean /= cells.size()
	for i: int in cells.size():
		cells[i] = Vector3(cells[i].x - mean.x, cells[i].y - mean.y, cells[i].z)
	_design_cache[key] = cells
	return cells

func _next_radius(rng: RandomNumberGenerator, mix: String, base: float) -> float:
	return base if mix == "uniform" else base * (1.0 + 0.85 * pow(rng.randf(), 2.0))

func _tangent(a: Vector3, b: Vector3, r: float, side: float) -> Vector2:
	var ca := Vector2(a.x, a.y)
	var cb := Vector2(b.x, b.y)
	var d := ca.distance_to(cb)
	var r1 := a.z + r
	var r2 := b.z + r
	if d <= 0.0 or d > r1 + r2 or d < absf(r1 - r2):
		return Vector2(NAN, NAN)
	var x := (d * d + r1 * r1 - r2 * r2) / (2.0 * d)
	var h := sqrt(maxf(r1 * r1 - x * x, 0.0))
	var dir := (cb - ca) / d
	return ca + dir * x + dir.orthogonal() * h * side

func _score(shape: String, at: Vector2, r: float, half_width: float, phases: Array) -> float:
	match shape:
		"worm":
			if absf(at.y) + r > half_width:
				return INF
			return absf(at.x) + 0.01 * absf(at.y)
		"ragged":
			var angle := at.angle()
			var lobes := 1.0 + 0.35 * sin(3.0 * angle + phases[0]) + 0.25 * sin(5.0 * angle + phases[1]) + 0.15 * sin(2.0 * angle + phases[2])
			return at.length() / maxf(lobes, 0.2)
		_:
			return at.length()

func _hash_key(cell_size: float, at: Vector2) -> Vector2i:
	return Vector2i(floori(at.x / cell_size), floori(at.y / cell_size))

func _hash_add(hash: Dictionary, cell_size: float, index: int, at: Vector2) -> void:
	var key := _hash_key(cell_size, at)
	if not hash.has(key):
		hash[key] = PackedInt32Array()
	var list: PackedInt32Array = hash[key]
	list.append(index)
	hash[key] = list

func _hash_near(hash: Dictionary, cell_size: float, at: Vector2) -> PackedInt32Array:
	var out := PackedInt32Array()
	var key := _hash_key(cell_size, at)
	for dy: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var k := key + Vector2i(dx, dy)
			if hash.has(k):
				out.append_array(hash[k])
	return out

func _overlaps(cells: Array[Vector3], hash: Dictionary, cell_size: float, at: Vector2, r: float) -> bool:
	for other: int in _hash_near(hash, cell_size, at):
		var o := cells[other]
		if Vector2(o.x, o.y).distance_to(at) < o.z + r - 0.01:
			return true
	return false

## 1 for a cell enclosed by its neighbours (a core), 0 for one that touches the outside:
## the cells rasterised 1 px a pixel, each grown by CAPTURE (what will seal two touching
## cells), the outside flooded from the border, and a cell exposed when a point just
## outside its outline is reached by the flood (pockets between cells are not).
func _classify(cells: Array[Vector3]) -> PackedByteArray:
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for c: Vector3 in cells:
		lo = lo.min(Vector2(c.x - c.z, c.y - c.z))
		hi = hi.max(Vector2(c.x + c.z, c.y + c.z))
	lo -= Vector2(6, 6)
	hi += Vector2(6, 6)
	var w := ceili(hi.x - lo.x)
	var h := ceili(hi.y - lo.y)
	var grid := PackedByteArray()
	grid.resize(w * h)
	for c: Vector3 in cells:
		var rr := c.z + _seal
		var cx := c.x - lo.x
		var cy := c.y - lo.y
		for y: int in range(maxi(floori(cy - rr), 0), mini(ceili(cy + rr) + 1, h)):
			var dy := y + 0.5 - cy
			var span := rr * rr - dy * dy
			if span < 0.0:
				continue
			var dx := sqrt(span)
			for x: int in range(maxi(floori(cx - dx), 0), mini(ceili(cx + dx) + 1, w)):
				grid[y * w + x] = 1
	# Flood the outside (2) from the border.
	var stack := PackedInt32Array()
	for x: int in w:
		stack.append(x)
		stack.append((h - 1) * w + x)
	for y: int in h:
		stack.append(y * w)
		stack.append(y * w + w - 1)
	while not stack.is_empty():
		var i: int = stack[stack.size() - 1]
		stack.resize(stack.size() - 1)
		if grid[i] != 0:
			continue
		grid[i] = 2
		var x := i % w
		if x > 0: stack.append(i - 1)
		if x < w - 1: stack.append(i + 1)
		if i >= w: stack.append(i - w)
		if i < (h - 1) * w: stack.append(i + w)
	var kinds := PackedByteArray()
	kinds.resize(cells.size())
	for ci: int in cells.size():
		var c := cells[ci]
		var exposed := false
		for s: int in 32:
			var at := Vector2(c.x, c.y) + Vector2.from_angle(TAU * s / 32.0) * (c.z + _seal + 1.0) - lo
			var x := clampi(int(at.x), 0, w - 1)
			var y := clampi(int(at.y), 0, h - 1)
			if grid[y * w + x] == 2:
				exposed = true
				break
		kinds[ci] = 0 if exposed else 1
	return kinds

func _print_ratios() -> void:
	print("colony_bench --ratios: rings (cells touching the outside) / cores (enclosed) of packed designs")
	print("| shape | mix | cells | rings | cores | core share | beads if all rings | beads + cores with cores |")
	print("|---|---|---|---|---|---|---|---|")
	for shape: String in ["blob", "worm", "ragged"]:
		for mix: String in ["uniform", "mixed"]:
			for count: int in [60, 100, 150, 200]:
				var design := _design(shape, mix, count, _seed)
				var kinds := _classify(design)
				var cores := 0
				var all_beads := 0
				var beads := 0
				for i: int in design.size():
					var n: int = GooTuning.bead_count(design[i].z) + _beads - 12
					all_beads += n
					if kinds[i] == 1:
						cores += 1
					else:
						beads += n
				print("| %s | %s | %d | %d | %d | %.0f%% | %d | %d |" % [shape, mix, design.size(), design.size() - cores,
					cores, 100.0 * cores / design.size(), all_beads, beads + cores])

# ---- Cell tuning ----

## The CELL_STRIDE floats of a cell of radius `r` at `at`: GooTuning.tuning(r) with
## the bead count changed by --beads (its masses, spacing, bead radius, ring radius and
## springs recomputed as tuning() would for that count), the drag's damping.
func _cell_floats(at: Vector2, r: float, core: bool, color: Color) -> PackedFloat32Array:
	var t := GooTuning.tuning(r)
	var n: int = maxi(int(t["bead_count"]) + _beads - 12, 6)
	var blob := GooTuning.blob_mass(r)
	var bead_mass := blob / n
	var bead_r := GooTuning.BEAD_RADIUS_RATIO * TAU * r / n
	var qa := 0.5 * n * sin(TAU / n)
	var qb := 2.0 * n * sin(PI / n) * bead_r
	var qc := PI * bead_r * bead_r - PI * r * r
	var ring_r := (-qb + sqrt(qb * qb - 4.0 * qa * qc)) / (2.0 * qa)
	var omega := GooTuning._skin_frequency(r)
	var zeta := GooTuning.joint_damping_ratio(r)
	var skin_k := bead_mass * omega * omega
	var skin_d := 2.0 * zeta * bead_mass * omega
	return PackedFloat32Array([at.x, at.y, r, 1.0 if core else 0.0, n, ring_r, bead_r, bead_mass,
		t["pressure_k"], t["shape_match_k"], skin_k, skin_d, GooTuning.BENDING_RATIO * skin_k,
		GooTuning.BENDING_RATIO * skin_d, t["internal_damp"], _drag, PI * r * r, color.r, color.g, color.b])

# ---- Building ----

func _build_colony(design: Array[Vector3], kinds: PackedByteArray, starts: Array[Transform2D]) -> void:
	_colony = GooColony.new()
	_colony.set_options({ "threads": _threads, "substeps": _substeps, "cell_scale": _cell_scale,
		"intra_contacts": _intra, "core_contacts": _core_contacts, "bond_scale": _bond_scale, "max_speed": GooTuning.MAX_BEAD_SPEED * UNIT })
	if _hold == "adhesion":
		_colony.set_options({ "adhesion": true,
			"capture": (_capture if _capture > 0.0 else GooColonySim.CAPTURE) * UNIT,
			"join_reach": GooColonySim.JOIN_REACH * UNIT,
			"break_force": (_break if _break > 0.0 else GooColonySim.BREAK_FORCE) * UNIT })
		if _sticky:
			_colony.set_join_mode(0, 0, GooColony.JOIN_STICKY)
		_colony.set_options({ "exposure": _exposure, "auto_cores": _auto_cores, "skip_enclosed": maxi(_skip, 0),
			"skip_speed": GooColonySim.SKIP_SPEED * UNIT, "core_contact": _core_contact, "core_anchors": _core_anchors,
			"exposure_every": _exp_every_hot.x, "exposure_hot": _exp_every_hot.y })
	if _water_drag:
		_colony.set_options(GooColonySim.DRAG_OPTIONS)
	for ci: int in _creatures:
		var hue := fmod(0.13 + ci * 0.618, 1.0)
		var floats := PackedFloat32Array()
		for i: int in design.size():
			var c := design[i]
			var core := not kinds.is_empty() and kinds[i] == 1
			var color := Color.from_hsv(hue, 0.55 if core else 0.7, 0.75 if core else 0.9)
			floats.append_array(_cell_floats(starts[ci] * Vector2(c.x, c.y), c.z, core, color))
		_colony.add_creature(floats)
		if _hold == "bonds":
			_colony.build_bonds(ci, CAPTURE)
		if ci < roundi(_sleep * _creatures):
			_colony.set_asleep(ci, true)
		elif ci < roundi((_sleep + _coarse) * _creatures):
			_colony.set_every(ci, 2, ci % 2)
	var stats := _colony.stats()
	print("colony_bench: %d beads, %d cores, %d rings, %d bonds (%.1f per cell)" % [stats["beads"], stats["cores"],
		stats["rings"], stats["bonds"], float(stats["bonds"]) / (_creatures * design.size())])
	if _draw != "none":
		_build_drawing()

func _build_nodes(design: Array[Vector3], starts: Array[Transform2D]) -> void:
	var world := CellWorld.new()
	world.drag = _drag
	world.gravity_scale = 0.0
	root.add_child(world)
	_world = world
	for ci: int in _creatures:
		var list: Array = []
		for c: Vector3 in design:
			list.append(_world.spawn(c.z, starts[ci] * Vector2(c.x, c.y)))
		_bodies.append(list)
	print("colony_bench: %d Goo2D nodes" % (_creatures * design.size()))

func _build_kernel(design: Array[Vector3], starts: Array[Transform2D]) -> void:
	_kernel = GooTuning.make_kernel()
	var solver := GooTuning.solver_settings()
	solver["gravity"] = Vector2.ZERO
	_kernel.set_solver(solver)
	_kernel.set_pair_passes(_pair_passes)
	var key := 1
	for ci: int in _creatures:
		var keys := PackedInt64Array()
		var masses := PackedFloat32Array()
		for c: Vector3 in design:
			var t := GooTuning.tuning(c.z)
			var n: int = t["bead_count"]
			var ring_r: float = t["ring_radius"]
			var rest := GooLoop.circle_points(Vector2.ZERO, ring_r, n)
			var points := GooLoop.circle_points(starts[ci] * Vector2(c.x, c.y), ring_r, n)
			var edges := PackedFloat32Array()
			for i: int in n:
				edges.append(rest[i].distance_to(rest[(i + 1) % n]))
			var params := t.duplicate()
			params["shape_match_k"] = t["shape_match_k"]
			params["linear_damp"] = _drag
			params["settle_speed"] = 0.0
			params["min_neck_rest"] = 2.0 * ring_r * sin(PI * maxi(n / 4, 2) / n)
			params["split_lock"] = GooTuning.SPLIT_LOCK
			_kernel.add_ring(key, points, rest, edges, PackedFloat32Array(), PackedByteArray(), params)
			keys.append(key)
			masses.append(t["bead_mass"])
			key += 1
		_keys.append(keys)
		_bead_masses.append(masses)
	print("colony_bench: %d rings in a GooKernel, %d beads, pair passes %s" % [_creatures * design.size(),
		_kernel.particle_count(), "on" if _pair_passes else "off"])

# ---- Drawing (colony mode) ----

const CELL_SHADER := """
shader_type canvas_item;
varying vec4 cell;
void vertex() {
	cell = CUSTOM0;
}
void fragment() {
	float d = length(UV);
	// A per-cell bubble field in the cell's rest frame (UV), seeded by its index.
	vec2 q = UV * 3.0 + vec2(cell.z * 1.7, cell.z * 0.37);
	vec2 f = fract(q) - 0.5;
	float seed = fract(sin(dot(floor(q), vec2(12.9898, 78.233))) * 43758.5453);
	float bubble = (1.0 - smoothstep(0.08, 0.12, length(f))) * step(0.7, seed);
	float px = fwidth(d) * 2.0;
	float rim = smoothstep(1.0 - px * 1.5, 1.0, d) * cell.y;
	float wall = smoothstep(1.0 - px, 1.0, d) * (1.0 - cell.y) * 0.35;
	vec3 col = COLOR.rgb * (0.85 + 0.15 * (1.0 - d)) + bubble * 0.25;
	col = mix(col, col * 0.55, wall);
	col = mix(col, vec3(1.0), rim * 0.85);
	COLOR = vec4(col, 1.0);
}
"""

const CORE_SHADER := """
shader_type canvas_item;
varying vec4 cell;
void vertex() {
	cell = INSTANCE_CUSTOM;
}
void fragment() {
	float d = length(UV);
	vec2 q = UV * 3.0 + vec2(cell.z * 1.7, cell.z * 0.37);
	vec2 f = fract(q) - 0.5;
	float seed = fract(sin(dot(floor(q), vec2(12.9898, 78.233))) * 43758.5453);
	float bubble = (1.0 - smoothstep(0.08, 0.12, length(f))) * step(0.7, seed);
	float px = fwidth(d) * 2.0;
	float wall = smoothstep(1.0 - px, 1.0, d) * 0.35;
	vec3 col = COLOR.rgb * (0.85 + 0.15 * (1.0 - d)) + bubble * 0.25;
	COLOR = vec4(mix(col, col * 0.55, wall), 1.0);
}
"""

func _mesh_flags() -> int:
	return (RenderingServer.ARRAY_CUSTOM_RGBA_FLOAT << RenderingServer.ARRAY_FORMAT_CUSTOM0_SHIFT) \
		| RenderingServer.ARRAY_FLAG_USE_DYNAMIC_UPDATE

func _surface_arrays(data: Array) -> Array:
	var arrays := []
	arrays.resize(RenderingServer.ARRAY_MAX)
	arrays[RenderingServer.ARRAY_VERTEX] = data[0]
	arrays[RenderingServer.ARRAY_COLOR] = data[1]
	arrays[RenderingServer.ARRAY_TEX_UV] = data[2]
	arrays[RenderingServer.ARRAY_CUSTOM0] = data[3]
	arrays[RenderingServer.ARRAY_INDEX] = data[4]
	return arrays

func _build_drawing() -> void:
	_canvas = Node2D.new()
	root.add_child(_canvas)
	var view := Vector2(1920, 1080)
	var fit := minf(view.x / _arena.size.x, view.y / _arena.size.y)
	_canvas.scale = Vector2(fit, fit)
	_canvas.position = (view - _arena.size * fit) * 0.5
	var cell_material := ShaderMaterial.new()
	cell_material.shader = Shader.new()
	cell_material.shader.code = CELL_SHADER
	var core_material := ShaderMaterial.new()
	core_material.shader = Shader.new()
	core_material.shader.code = CORE_SHADER
	_materials = [cell_material, core_material]
	var rings_only := _draw == "multimesh"
	var rs := RenderingServer
	if _draw == "world":
		var verts := PackedVector2Array()
		var colors := PackedColorArray()
		var uvs := PackedVector2Array()
		var custom := PackedFloat32Array()
		var indices := PackedInt32Array()
		for ci: int in _creatures:
			var data := _colony.mesh_arrays(ci, false)
			var offset := verts.size()
			verts.append_array(data[0])
			colors.append_array(data[1])
			uvs.append_array(data[2])
			custom.append_array(data[3])
			for index: int in data[4]:
				indices.append(index + offset)
		_world_mesh = rs.mesh_create()
		rs.mesh_add_surface_from_arrays(_world_mesh, RenderingServer.PRIMITIVE_TRIANGLES,
			_surface_arrays([verts, colors, uvs, custom, indices]), [], {}, _mesh_flags())
		var item := rs.canvas_item_create()
		rs.canvas_item_set_parent(item, _canvas.get_canvas_item())
		rs.canvas_item_add_mesh(item, _world_mesh)
		rs.canvas_item_set_material(item, cell_material.get_rid())
		_items.append(item)
		_report_surface(_world_mesh, verts.size())
		return
	var disc := RID()
	if rings_only:
		disc = rs.mesh_create()
		_disc = disc
		var dv := PackedVector2Array([Vector2.ZERO])
		var du := PackedVector2Array([Vector2.ZERO])
		var di := PackedInt32Array()
		for s: int in GooColony.CORE_SIDES:
			var d := Vector2.from_angle(-TAU * s / GooColony.CORE_SIDES)
			dv.append(d)
			du.append(d)
			di.append_array([0, 1 + s, 1 + (s + 1) % GooColony.CORE_SIDES])
		var arrays := []
		arrays.resize(RenderingServer.ARRAY_MAX)
		arrays[RenderingServer.ARRAY_VERTEX] = dv
		arrays[RenderingServer.ARRAY_TEX_UV] = du
		arrays[RenderingServer.ARRAY_INDEX] = di
		rs.mesh_add_surface_from_arrays(disc, RenderingServer.PRIMITIVE_TRIANGLES, arrays)
	for ci: int in _creatures:
		var mesh := rs.mesh_create()
		rs.mesh_add_surface_from_arrays(mesh, RenderingServer.PRIMITIVE_TRIANGLES,
			_surface_arrays(_colony.mesh_arrays(ci, rings_only)), [], {}, _mesh_flags())
		var item := rs.canvas_item_create()
		rs.canvas_item_set_parent(item, _canvas.get_canvas_item())
		rs.canvas_item_add_mesh(item, mesh)
		rs.canvas_item_set_material(item, cell_material.get_rid())
		_meshes.append(mesh)
		_items.append(item)
		if rings_only:
			var mm := rs.multimesh_create()
			var info := _colony.creature_info(ci)
			rs.multimesh_allocate_data(mm, info[1], RenderingServer.MULTIMESH_TRANSFORM_2D, true, true)
			rs.multimesh_set_mesh(mm, disc)
			var core_item := rs.canvas_item_create()
			rs.canvas_item_set_parent(core_item, _canvas.get_canvas_item())
			rs.canvas_item_add_multimesh(core_item, mm)
			rs.canvas_item_set_material(core_item, core_material.get_rid())
			_multimeshes.append(mm)
			_items.append(core_item)
	_report_surface(_meshes[0], _colony.vertex_count(0, rings_only))

# Prints the surface's vertex and attribute strides (checks the byte layouts the
# updates write) and the drawing's size.
func _report_surface(mesh: RID, vertices: int) -> void:
	var surface := RenderingServer.mesh_get_surface(mesh, 0)
	var vertex_bytes: int = (surface["vertex_data"] as PackedByteArray).size()
	var attribute_bytes: int = (surface["attribute_data"] as PackedByteArray).size()
	var stride := attribute_bytes / maxi(vertices, 1)
	_color_bytes = 4 if stride == 4 + 8 + 16 else 16
	var total_vertices := 0
	var total_triangles := 0
	for ci: int in _creatures:
		var data := _colony.mesh_arrays(ci, _draw == "multimesh")
		total_vertices += (data[0] as PackedVector2Array).size()
		total_triangles += (data[4] as PackedInt32Array).size() / 3
	var instances := 0
	if _draw == "multimesh":
		for ci: int in _creatures:
			instances += _colony.creature_info(ci)[1]
	print("colony_bench: drawing %s: vertex stride %d B, attribute stride %d B (colour %d B); %d vertices, %d triangles, %d core instances (12 triangles each), %d canvas items (draw calls)" % [
		_draw, vertex_bytes / maxi(vertices, 1), stride, _color_bytes, total_vertices, total_triangles, instances, _items.size()])

func _free_drawing() -> void:
	for rid: RID in _items + _meshes + _multimeshes:
		RenderingServer.free_rid(rid)
	if _world_mesh.is_valid():
		RenderingServer.free_rid(_world_mesh)
	if _disc.is_valid():
		RenderingServer.free_rid(_disc)
	_items.clear()
	_meshes.clear()
	_multimeshes.clear()

func _update_drawing() -> void:
	if _zoom > 0.0:
		_canvas.scale = Vector2(_zoom, _zoom)
		_canvas.position = Vector2(960, 540) - _colony.creature_center(0) * _zoom
	var rs := RenderingServer
	match _draw:
		"world":
			rs.mesh_surface_update_vertex_region(_world_mesh, 0, 0, _colony.all_mesh_positions(false))
		"region":
			for ci: int in _creatures:
				rs.mesh_surface_update_vertex_region(_meshes[ci], 0, 0, _colony.mesh_positions(ci, false))
		"attrs":
			for ci: int in _creatures:
				rs.mesh_surface_update_vertex_region(_meshes[ci], 0, 0, _colony.mesh_positions(ci, false))
				rs.mesh_surface_update_attribute_region(_meshes[ci], 0, 0, _colony.mesh_attributes(ci, false, _color_bytes))
		"rebuild":
			for ci: int in _creatures:
				rs.mesh_clear(_meshes[ci])
				rs.mesh_add_surface_from_arrays(_meshes[ci], RenderingServer.PRIMITIVE_TRIANGLES,
					_surface_arrays(_colony.mesh_arrays(ci, false)), [], {}, _mesh_flags())
		"multimesh":
			for ci: int in _creatures:
				rs.mesh_surface_update_vertex_region(_meshes[ci], 0, 0, _colony.mesh_positions(ci, true))
				rs.multimesh_set_buffer(_multimeshes[ci], _colony.core_instances(ci))

# ---- The frame ----

func _push_all(delta: float) -> void:
	for ci: int in _creatures:
		var center := _center(ci)
		_retarget[ci] -= delta
		if _retarget[ci] <= 0.0 or center.distance_to(_targets[ci]) < 60.0:
			_targets[ci] = _random_target()
			_retarget[ci] = RETARGET_TIME
		var push := (_targets[ci] - center).normalized() * PUSH
		match _mode:
			"colony":
				_colony.push_creature(ci, push)
				if _water_drag and _water == "cells":
					_colony.set_cell_water(ci, _vortex(_colony.creature_cell_centers(ci)))
			"nodes":
				for body: Goo2D in _bodies[ci]:
					body.apply_impulse(push * delta * body.body_mass() / body.particle_count())
			"kernel":
				var keys: PackedInt64Array = _keys[ci]
				var masses: PackedFloat32Array = _bead_masses[ci]
				for k: int in keys.size():
					_kernel.apply_impulse(keys[k], push * delta * masses[k])

## A stand-in for the game's FlowField: one slow vortex over the arena, sampled per point
## in GDScript as velocities_at() would be.
func _vortex(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(points.size())
	var centre := _arena.get_center()
	var radius := 0.5 * _arena.size.length()
	for i: int in points.size():
		var rel := points[i] - centre
		var x := rel.length() / radius
		out[i] = rel.orthogonal().normalized() * (4.0 * x * (1.0 - x) * 60.0) if x < 1.0 else Vector2.ZERO
	return out

func _center(ci: int) -> Vector2:
	match _mode:
		"colony":
			return _colony.creature_center(ci)
		"nodes":
			var list: Array = _bodies[ci]
			var total := Vector2.ZERO
			for k: int in range(0, list.size(), 10):
				total += (list[k] as Goo2D).center()
			return total / ceili(list.size() / 10.0)
		_:
			var keys: PackedInt64Array = _keys[ci]
			var total := Vector2.ZERO
			for k: int in range(0, keys.size(), 10):
				total += _kernel.center(keys[k])
			return total / ceili(keys.size() / 10.0)

func _on_physics(first: bool, delta: float) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	if first:
		_t_phys_first = now
		_push_all(delta)
		_t_push = Time.get_ticks_usec() - now
		if _mode == "colony":
			_colony.step(delta)
		elif _mode == "kernel":
			_kernel.step(delta)
		return
	var span := now - _t_phys_first
	var kernel_us := 0
	match _mode:
		"colony":
			var s := _colony.stats()
			kernel_us = s["total_us"]
			_sample("holds", s["bonds_cpu_us"] + s["sticks_cpu_us"])
			_sample("capture", s["capture_us"])
			_sample("settle", s["settle_us"])
			_sample("sticks", s["sticks"], false)
			_sample("broken", s["broken"], false)
			for key: String in ["forces_us", "pairs_us", "solve_us", "cross_us", "vel_us", "rings_cpu_us", "intra_cpu_us"]:
				_sample(key.trim_suffix("_us"), s[key])
			_sample("cross_hits", s["cross_hits"], false)
			_sample("intra_pairs", s["intra_pairs"], false)
			_sample("cross_pairs", s["cross_pairs"], false)
			_sample("exposure", s["exposure_us"])
			_sample("exp_runs", s["exposure_runs"], false)
			_sample("drag_cpu", s["drag_cpu_us"])
			_sample("skipped", s["cross_skipped"], false)
			_sample("enclosed", s["enclosed"], false)
			_sample("pockets", s["pockets"], false)
			_switches += s["to_core"] + s["to_ring"]
			_switch_frames[0] += s["to_core"]
			_switch_frames[1] += s["to_ring"]
		"nodes":
			var solver := _world.kernel().solver()
			kernel_us = solver["last_step_usec"]
			_kernel_phases(solver)
		"kernel":
			var solver := _kernel.solver()
			kernel_us = solver["last_step_usec"]
			_kernel_phases(solver)
	_sample("kernel", kernel_us)
	_sample("script", span - kernel_us)
	_sample("push", _t_push)
	_sample("physics", span)

func _kernel_phases(solver: Dictionary) -> void:
	var phases: PackedInt64Array = solver["last_phase_usec"]
	var names := ["k_pairpass", "k_links", "k_solver", "k_rings", "k_skins"]
	for i: int in names.size():
		_sample(names[i], phases[i])

func _on_process(first: bool) -> void:
	if _done:
		return
	var now := Time.get_ticks_usec()
	if first:
		_t_proc_first = now
		if _mode == "colony" and _draw != "none":
			_colony.reset_draw_clock()
			_update_drawing()
			var spent := Time.get_ticks_usec() - now
			_sample("draw", spent)
			_sample("draw_rust", _colony.stats()["draw_build_us"])
		return
	if _mode == "nodes":
		_sample("draw", now - _t_proc_first)
	if DisplayServer.get_name() != "headless":
		# The renderer's own CPU time for the last frame (canvas set-up and the GL calls;
		# under llvmpipe the GL calls include its rasterising, so read it as an upper bound).
		_sample("rs_setup", RenderingServer.get_frame_setup_time_cpu() * 1000.0)
		_sample("rs_render", RenderingServer.viewport_get_measured_render_time_cpu(root.get_viewport_rid()) * 1000.0)
	_frame += 1
	if _mode == "colony" and _frame % 10 == 0 and OS.get_environment("COLONY_TRACE") == "1":
		print("frame %d health %s" % [_frame, _colony.health()])
	if _mode == "colony" and _frame > _warmup and _frame % 10 == 0:
		var h := _colony.health()
		for key: String in h:
			var worst: float = _health.get(key, -INF if key != "area_min" else INF)
			_health[key] = minf(worst, h[key]) if key == "area_min" else maxf(worst, h[key])
	if _frame == _warmup + _frames:
		_done = true
		_report()
		if not _png.is_empty():
			await RenderingServer.frame_post_draw
			var image := root.get_viewport().get_texture().get_image()
			if image != null and not image.is_empty():
				image.save_png(_png)
				print("colony_bench: saved %s" % _png)
		_free_drawing()
		quit(0)

func _sample(key: String, value: float, usec: bool = true) -> void:
	if _frame < _warmup:
		return
	if not _samples.has(key):
		_samples[key] = PackedFloat64Array()
	var list: PackedFloat64Array = _samples[key]
	list.append(value / 1000.0 if usec else value)
	_samples[key] = list

func _report() -> void:
	print("colony_bench: %d frames after %d warm-up (ms: min / median / p95)" % [_frames, _warmup])
	var order := ["physics", "kernel", "holds", "capture", "settle", "exposure", "exp_runs", "drag_cpu", "skipped", "enclosed", "pockets",
		"sticks", "broken", "script", "push", "draw", "draw_rust", "rs_setup", "rs_render",
		"forces", "pairs", "solve", "rings_cpu", "intra_cpu", "cross", "vel", "cross_hits", "intra_pairs", "cross_pairs",
		"k_pairpass", "k_links", "k_solver", "k_rings", "k_skins"]
	for key: String in order:
		if not _samples.has(key):
			continue
		var list: PackedFloat64Array = _samples[key]
		list.sort()
		var n := list.size()
		print("  %-11s %8.2f %8.2f %8.2f" % [key, list[0], list[n / 2], list[mini(int(n * 0.95), n - 1)]])
	if not _health.is_empty():
		print("  health (worst over the measured frames, every 10th): fastest %.0f px/s, ring area %.2f..%.2f of target, %d inside out, bond stretch %.2f, overlap %.2f px, sticks stretched %.2f / squeezed %.2f px, load %.0f, %d not finite" % [
			_health["fastest"], _health["area_min"], _health["area_max"], int(_health["inverted"]), _health["stretch"], _health["overlap"],
			_health["stick_stretch"], _health["stick_squeeze"], _health["stick_load"], int(_health["not_finite"])])
	if _mode == "colony" and _exposure:
		var st := _colony.stats()
		print("  milestone 2: %d rings and %d cores at the end; over every frame, warm-up included, %d rings became cores and %d cores rings" % [
			st["rings"], st["cores"], _switch_frames[0], _switch_frames[1]])
	if _mode == "colony" and _hold == "adhesion":
		var loads := PackedFloat32Array()
		for ci: int in _creatures:
			var st := _colony.creature_sticks(ci)
			for q: int in range(0, st.size(), GooColony.STICK_FLOATS):
				loads.append(st[q + 8])
		loads.sort()
		var n := loads.size()
		if n > 0:
			print("  stick loads at the end: min %.0f, p1 %.0f, p50 %.0f, p99 %.0f, max %.0f (break %.0f)" % [loads[0], loads[n / 100],
				loads[n / 2], loads[mini(n * 99 / 100, n - 1)], loads[n - 1], (_break if _break > 0.0 else GooColonySim.BREAK_FORCE) * UNIT])
	var line := "RESULT mode=%s n=%d m=%d shape=%s mix=%s beads=%d cores=%s intra=%s threads=%d substeps=%d draw=%s hold=%s" % [
		_mode, _creatures, _cells, _shape, _mix, _beads, _cores and _mode == "colony", "cores" if _core_contacts else ("on" if _intra else "off"), _threads, _substeps, _draw,
		_hold + ("/sticky" if _sticky else "")]
	line += " exposure=%s auto=%s skip=%d contact=%.2f anchors=%s water_drag=%s water=%s" % [_exposure, _auto_cores, _skip, _core_contact, _core_anchors, _water_drag, _water]
	for key: String in ["physics", "kernel", "holds", "exposure", "drag_cpu", "pairs", "cross", "script", "draw", "rs_setup"]:
		if _samples.has(key):
			var list: PackedFloat64Array = _samples[key]
			line += " %s=%.2f/%.2f" % [key + "_ms", list[list.size() / 2], list[mini(int(list.size() * 0.95), list.size() - 1)]]
	print(line)

# ---- Promotion and demotion ----

## Two identical colonies of four creatures at rest; in one, interior cores are promoted
## to rings (and rings demoted to cores) one at a time. Prints each change's cost and how
## far every other cell's centre ends up from its twin's, 1, 5 and 30 frames later.
func _promote_test() -> void:
	var design := _design(_shape, _mix, _cells, _seed)
	var kinds := _classify(design)
	var make := func() -> GooColony:
		var col := GooColony.new()
		col.set_options({ "threads": 1, "substeps": _substeps })
		var floats := PackedFloat32Array()
		for i: int in design.size():
			var c := design[i]
			floats.append_array(_cell_floats(Vector2(c.x, c.y), c.z, kinds[i] == 1, Color.WHITE))
		col.add_creature(floats)
		col.build_bonds(0, CAPTURE)
		for f: int in 90:
			col.step(1.0 / 60.0)
		return col
	print("colony_bench --promote-test: %s %s %d cells, at rest after 1.5 s; each change made on a fresh creature beside a twin whose bonds are rebuilt at the same moment" % [_shape, _mix, design.size()])
	print("| change | cell | cost µs | overlap at once px | worst other cell's centre off its twin's after 1 / 5 / 30 frames px | the cell's own centre px |")
	print("|---|---|---|---|---|---|")
	var cores: Array[int] = []
	var rings: Array[int] = []
	for i: int in design.size():
		if kinds[i] == 1:
			cores.append(i)
		else:
			rings.append(i)
	var trials: Array = []
	for k: int in 4:
		trials.append(["promote", cores[(k * 23) % cores.size()]])
	for k: int in 3:
		trials.append(["demote", rings[(k * 11) % rings.size()]])
	for trial: Array in trials:
		var a: GooColony = make.call()
		var b: GooColony = make.call()
		var cell: int = trial[1]
		var before := a.cell_center(0, cell)
		var t0 := Time.get_ticks_usec()
		var overlap: float = a.promote(0, cell, CAPTURE) if trial[0] == "promote" else a.demote(0, cell, CAPTURE)
		var cost := Time.get_ticks_usec() - t0
		var moved := a.cell_center(0, cell).distance_to(before)
		# The change rebuilds the creature's bonds from where its beads are now; the twin
		# rebuilds its own too, so what differs is the change alone.
		b.build_bonds(0, CAPTURE)
		var shifts := PackedFloat32Array()
		for f: int in 30:
			a.step(1.0 / 60.0)
			b.step(1.0 / 60.0)
			if f == 0 or f == 4 or f == 29:
				var worst := 0.0
				for i: int in design.size():
					if i != cell:
						worst = maxf(worst, a.cell_center(0, i).distance_to(b.cell_center(0, i)))
				shifts.append(worst)
		var own := a.cell_center(0, cell).distance_to(b.cell_center(0, cell))
		print("| %s | %d | %d | %.2f | %.2f / %.2f / %.2f | moved %.2f at the change, %.2f off its twin after 30 |" % [
			trial[0], cell, cost, overlap, shifts[0], shifts[1], shifts[2], moved, own])
