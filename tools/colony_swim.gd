extends SceneTree
## explore-frozen: a worm-shaped creature swimming by a travelling wave of per-cell resizes
## against the colony's water drag, full model against frozen topology.
##
##   godot --headless --fixed-fps 60 --path . -s tools/colony_swim.gd -- [options]
##
## Options: --long=L --wide=W (cells along and across, hex-packed; default 24 × 5),
## --gait=bend|squeeze (bend: cells on one side grow while the other side's shrink, a bend
## wave; squeeze: whole columns grow and shrink, a peristaltic wave), --amp=A (0.15 of the
## radius), --freq=F (1 Hz), --waves=K (1 wave along the body), --seconds=S (10, after 1 s
## to settle), --threads=T (4), --frozen, --retopo-every=N, --frozen-self=none|kept|full|verlet,
## --fast-search=on, --stick-every=N, --substeps=S, --cores=on|off (interior cells as cores),
## --crowd=N (N more worms swimming alongside, for the time per frame).

const UNIT: float = 0.5
const RADIUS: float = 14.0

var _long: int = 24
var _wide: int = 5
var _gait: String = "bend"
var _amp: float = 0.15
var _freq: float = 1.0
var _waves: float = 1.0
var _seconds: float = 10.0
var _threads: int = 4
var _frozen: bool = false
var _retopo_every: int = 0
var _frozen_self: int = 3
var _fast: bool = false
var _stick_every: int = 1
var _substeps: int = 6
var _cores: bool = true
var _crowd: int = 0
var _frozen_breaks: bool = false
var _break: float = -1.0
var _beads: int = 12
var _fast_rings: bool = false
var _skin: float = 10.0

var _colony: GooColony
var _cells: Array = []  # per creature: Array of Vector3(u, v, base radius)
var _frame: int = 0
var _settle_frames: int = 60
var _start := Vector2.ZERO
var _times := PackedFloat64Array()
var _sums := {}
var _worst := {}
var _head_y := Vector2(INF, -INF)
var _mid_y := Vector2(INF, -INF)

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--long="): _long = int(value)
		elif arg.begins_with("--wide="): _wide = int(value)
		elif arg.begins_with("--gait="): _gait = value
		elif arg.begins_with("--amp="): _amp = float(value)
		elif arg.begins_with("--freq="): _freq = float(value)
		elif arg.begins_with("--waves="): _waves = float(value)
		elif arg.begins_with("--seconds="): _seconds = float(value)
		elif arg.begins_with("--threads="): _threads = int(value)
		elif arg == "--frozen": _frozen = true
		elif arg.begins_with("--retopo-every="): _retopo_every = int(value)
		elif arg.begins_with("--frozen-self="): _frozen_self = ["none", "kept", "full", "verlet"].find(value)
		elif arg.begins_with("--fast-search="): _fast = value == "on"
		elif arg.begins_with("--stick-every="): _stick_every = int(value)
		elif arg.begins_with("--substeps="): _substeps = int(value)
		elif arg.begins_with("--cores="): _cores = value == "on"
		elif arg.begins_with("--crowd="): _crowd = int(value)
		elif arg.begins_with("--break="): _break = float(value)
		elif arg.begins_with("--beads="): _beads = int(value)
		elif arg.begins_with("--skin="): _skin = float(value)
		elif arg.begins_with("--fast-rings="): _fast_rings = value == "on"
		elif arg.begins_with("--frozen-breaks="): _frozen_breaks = value == "on"
		else: push_error("colony_swim: unknown option %s" % arg)
	GooTuning.unit = UNIT
	var opts := GooColonySim.EXPOSURE_OPTIONS.duplicate()
	opts.merge(GooColonySim.DRAG_OPTIONS)
	var sim := GooColonySim.new(opts)
	_colony = sim.colony
	_colony.set_options({ "threads": _threads, "substeps": _substeps, "intra_contacts": true,
		"frozen": _frozen, "retopo_every": _retopo_every, "frozen_self": _frozen_self, "fast_search": _fast,
		"stick_every": _stick_every, "frozen_breaks": _frozen_breaks, "spin": _threads > 1, "fast_rings": _fast_rings, "pair_skin": _skin })
	if _break > 0.0:
		_colony.set_options({ "break_force": _break * UNIT })
	for k: int in 1 + _crowd:
		_add_worm(Vector2(0, k * (_wide * 2.0 * RADIUS + 80.0)))
	print("colony_swim: %d worm(s) of %d × %d cells (%s), gait %s amp %.2f freq %.1f Hz waves %.1f, frozen %s retopo %d self %d fast %s substeps %d stick_every %d" % [
		1 + _crowd, _long, _wide, "cores inside" if _cores else "all rings", _gait, _amp, _freq, _waves, _frozen, _retopo_every,
		_frozen_self, _fast, _substeps, _stick_every])

func _add_worm(origin: Vector2) -> void:
	var floats := PackedFloat32Array()
	var list: Array = []
	var r := RADIUS
	for c: int in _long:
		for j: int in _wide:
			var at := origin + Vector2(c * 2.0 * r + (j % 2) * r, j * sqrt(3.0) * r)
			var core := _cores and j > 0 and j < _wide - 1 and c > 0 and c < _long - 1
			var f := cell_floats_beads(at, r, core, _beads, 0.0)
			f[14] *= 0.25  # internal damping × 0.25, as the fluid game's bodies
			floats.append_array(f)
			# u: 0 at the tail (c = 0) to 1 at the head; v: -1..1 across.
			list.append(Vector3(float(c) / maxf(_long - 1, 1), (j - (_wide - 1) * 0.5) / maxf((_wide - 1) * 0.5, 1.0), r))
	_colony.add_creature(floats)
	_cells.append(list)

func _physics_process(delta: float) -> bool:
	var t := _frame * delta
	var ramp := clampf((_frame - 20) / 40.0, 0.0, 1.0)
	for ci: int in _cells.size():
		var list: Array = _cells[ci]
		for i: int in list.size():
			var c: Vector3 = list[i]
			var phase := TAU * (_waves * c.x + _freq * t)
			var s := sin(phase) * (c.y if _gait == "bend" else 1.0)
			_colony.resize_cell(ci, i, c.z * (1.0 + _amp * ramp * s))
	_colony.step(delta)
	_frame += 1
	if _frame == _settle_frames:
		_start = _colony.creature_center(0)
	if _frame > _settle_frames:
		var centers: PackedVector2Array = _colony.creature_cell_centers(0)
		var mid_row := _wide / 2
		var head := centers[(_long - 1) * _wide + mid_row]
		var mid := centers[(_long / 2) * _wide + mid_row]
		var body := _colony.creature_center(0)
		_head_y = Vector2(minf(_head_y.x, head.y - body.y), maxf(_head_y.y, head.y - body.y))
		_mid_y = Vector2(minf(_mid_y.x, mid.y - body.y), maxf(_mid_y.y, mid.y - body.y))
		var stt := _colony.stats()
		_times.append(stt["total_us"] / 1000.0)
		for key: String in ["own_cpu_us", "pairs_us", "solve_us", "settle_us", "pair_builds", "exposure_runs", "rings_cpu_us", "sticks_cpu_us", "intra_cpu_us", "retopo_cpu_us", "cross_us"]:
			_sums[key] = _sums.get(key, 0.0) + float(stt[key])
		if _frame % 10 == 0:
			var snd := _colony.soundness()
			for key: String in snd:
				var w: float = _worst.get(key, -INF if key != "area_min" else INF)
				_worst[key] = minf(w, snd[key]) if key == "area_min" else maxf(w, snd[key])
	if _frame >= _settle_frames + int(_seconds * 60.0):
		var moved := _colony.creature_center(0) - _start
		_times.sort()
		var st := _colony.stats()
		print("colony_swim: moved (%.1f, %.1f) px in %.1f s: %.1f px/s along the body (+x), %.1f px/s across; body length %.0f px (%.3f lengths/s)" % [
			moved.x, moved.y, _seconds, moved.x / _seconds, moved.y / _seconds, _long * 2.0 * RADIUS, moved.x / _seconds / (_long * 2.0 * RADIUS)])
		print("colony_swim: lateral swing about the centre: head %.1f px, middle %.1f px (peak to peak)" % [_head_y.y - _head_y.x, _mid_y.y - _mid_y.x])
		print("colony_swim: step ms median %.2f p95 %.2f; sticks %d, rings %d, cores %d, exposure passes in the last step %d" % [
			_times[_times.size() / 2], _times[int(_times.size() * 0.95)], st["sticks"], st["rings"], st["cores"], st["exposure_runs"]])
		print("colony_swim: soundness worst: own inside %d, cross inside %d, inside out %d, ring area min %.2f, own core overlap %.2f px" % [
			int(_worst["own_inside"]), int(_worst["cross_inside"]), int(_worst["inverted"]), _worst["area_min"], _worst["own_core_overlap"]])
		var line := "colony_swim: means per frame:"
		for key: String in _sums:
			line += " %s=%.2f" % [key.trim_suffix("_us"), _sums[key] / _times.size() / (1000.0 if key.ends_with("_us") else 1.0)]
		print(line)
		print("colony_swim: sticks at the end %d" % st["sticks"])
		print("SWIM gait=%s frozen=%s retopo=%d self=%d speed=%.2f across=%.2f step_ms=%.2f/%.2f own_inside=%d inverted=%d area_min=%.2f" % [
			_gait, _frozen, _retopo_every, _frozen_self, moved.x / _seconds, moved.y / _seconds, _times[_times.size() / 2],
			_times[int(_times.size() * 0.95)], int(_worst["own_inside"]), int(_worst["inverted"]), _worst["area_min"]])
		return true
	return false

## The bench's _cell_floats(): GooTuning.tuning(r) with the bead count changed by `beads`
## - 12 (masses, bead radius, ring radius and springs recomputed), linear damping `damp`.
static func cell_floats_beads(at: Vector2, r: float, core: bool, beads: int, damp: float) -> PackedFloat32Array:
	var t := GooTuning.tuning(r)
	var n: int = maxi(int(t["bead_count"]) + beads - 12, 6)
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
		GooTuning.BENDING_RATIO * skin_d, t["internal_damp"], damp, PI * r * r, 1.0, 1.0, 1.0])
