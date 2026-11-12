extends SceneTree
## Colony propulsion (docs/colony-frozen.md): creatures swimming by travelling waves of
## per-cell muscles (GooColony.set_cell_muscles(), one call per creature a frame) against
## the colony's water drag, with the surface tension on: the frozen preset
## (GooColonySim.frozen_options()) against the full model (everything_options()).
##
##   godot --headless --fixed-fps 60 --path . -s tools/colony_swim.gd -- [options]
##
## Options:
##   --model=frozen|full      GooColonySim.frozen_options() (default) or everything_options()
##   --shape=worm|blob        a worm of --long × --wide cells (hex-packed, 24 × 5) or a hex
##                            blob of --rings rings around a cell (3: 37 cells)
##   --gait=bend|squeeze      bend: the cells on one side grow while the other side's shrink,
##                            a bend wave; squeeze: whole columns grow and shrink together
##   --amp=A --freq=F --waves=K   the muscle's amplitude (0.15 of the size), cycles per s (1),
##                            waves along the body (1); the wave runs tail-ward, so the
##                            creature swims toward its head (+x)
##   --crowd=N                N creatures swimming at once, side by side, all timed (1)
##   --seconds=S              measured seconds after 1 s to settle (10)
##   --threads=T --beads=K --retopo-every=N --skin=PX (at unit 0.5) --frozen-self=none|kept|full|verlet|cells
##   --tension=T              the surface tension at unit 1 (GooColonySim.TENSION; 0 off)
##   --cores=on|off           a worm's interior cells as cores from the start (on)
##   --trace                  one line per measured frame
## It prints the speed (px/s along +x, body lengths per cycle), the lateral swing, the
## step's median and 95th percentile (ms, the colony's step; script: the muscles' calls),
## the worst soundness over the frames (every 5th), and the step's means.

const UNIT: float = 0.5
const RADIUS: float = 14.0

var _model: String = "frozen"
var _shape: String = "worm"
var _long: int = 24
var _wide: int = 5
var _rings: int = 3
var _gait: String = "bend"
var _amp: float = 0.15
var _freq: float = 1.0
var _waves: float = 1.0
var _seconds: float = 10.0
var _threads: int = 4
var _crowd: int = 1
var _cores: bool = true
var _beads: int = 12
var _tension: float = GooColonySim.TENSION
var _extra := {}
var _trace: bool = false

var _sim: GooColonySim
var _colony: GooColony
var _cells: Array = []  # per creature: PackedVector3Array of (u, v, unused)
var _length: float = 0.0
var _frame: int = 0
var _settle_frames: int = 60
var _start: Array[Vector2] = []
var _times := PackedFloat64Array()
var _script_times := PackedFloat64Array()
var _sums := {}
var _worst := {}
var _head_y := Vector2(INF, -INF)
var _scales := PackedFloat32Array()

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--model="): _model = value
		elif arg.begins_with("--shape="): _shape = value
		elif arg.begins_with("--long="): _long = int(value)
		elif arg.begins_with("--wide="): _wide = int(value)
		elif arg.begins_with("--rings="): _rings = int(value)
		elif arg.begins_with("--gait="): _gait = value
		elif arg.begins_with("--amp="): _amp = float(value)
		elif arg.begins_with("--freq="): _freq = float(value)
		elif arg.begins_with("--waves="): _waves = float(value)
		elif arg.begins_with("--seconds="): _seconds = float(value)
		elif arg.begins_with("--threads="): _threads = int(value)
		elif arg.begins_with("--crowd="): _crowd = int(value)
		elif arg.begins_with("--cores="): _cores = value == "on"
		elif arg.begins_with("--beads="): _beads = int(value)
		elif arg.begins_with("--tension="): _tension = float(value)
		elif arg.begins_with("--retopo-every="): _extra["retopo_every"] = int(value)
		elif arg.begins_with("--skin="): _extra["pair_skin"] = float(value)
		elif arg.begins_with("--frozen-self="): _extra["frozen_self"] = ["none", "kept", "full", "verlet", "cells"].find(value)
		elif arg.begins_with("--substeps="): _extra["substeps"] = int(value)
		elif arg.begins_with("--spin="): _extra["spin"] = value == "on"
		elif arg == "--trace": _trace = true
		else: push_error("colony_swim: unknown option %s" % arg)
	GooTuning.unit = UNIT
	var opts := GooColonySim.frozen_options(_tension) if _model == "frozen" else GooColonySim.everything_options(_tension)
	if _tension <= 0.0:
		opts["tension"] = 0.0
	opts["threads"] = _threads
	opts["cpu_timers"] = true
	opts.merge(_extra, true)
	_sim = GooColonySim.new(opts)
	_colony = _sim.colony
	var columns := ceili(sqrt(float(_crowd)))
	for k: int in _crowd:
		var size := Vector2(_long * 2.0 * RADIUS, _wide * 1.8 * RADIUS) if _shape == "worm" else Vector2.ONE * (2 * _rings + 1) * 2.0 * RADIUS
		_add_creature(Vector2((k % columns) * (size.x + 120.0), (k / columns) * (size.y + 120.0)))
	print("colony_swim: model %s, %d %s(s) of %d cells, %d beads per smallest cell, gait %s amp %.2f freq %.1f Hz waves %.1f, tension %.0f, threads %d, options %s" % [
		_model, _crowd, _shape, (_cells[0] as PackedVector3Array).size(), _beads, _gait, _amp, _freq, _waves, _tension, _threads, _extra])

func _add_creature(origin: Vector2) -> void:
	var floats := PackedFloat32Array()
	var list := PackedVector3Array()
	var r := RADIUS
	var spots: Array[Vector3] = []  # x, y, core
	if _shape == "worm":
		for c: int in _long:
			for j: int in _wide:
				var core := _cores and j > 0 and j < _wide - 1 and c > 0 and c < _long - 1
				spots.append(Vector3(c * 2.0 * r + (j % 2) * r, j * sqrt(3.0) * r, 1.0 if core else 0.0))
	else:
		for q: int in range(-_rings, _rings + 1):
			for p: int in range(-_rings, _rings + 1):
				if absi(p + q) <= _rings:
					var core := _cores and maxi(maxi(absi(p), absi(q)), absi(p + q)) < _rings
					spots.append(Vector3(p * 2.0 * r + q * r, q * sqrt(3.0) * r, 1.0 if core else 0.0))
	var lo := Vector2(INF, INF)
	var hi := Vector2(-INF, -INF)
	for s: Vector3 in spots:
		lo = lo.min(Vector2(s.x, s.y))
		hi = hi.max(Vector2(s.x, s.y))
	_length = hi.x - lo.x + 2.0 * r
	var half := maxf((hi.y - lo.y) * 0.5, 1.0)
	for s: Vector3 in spots:
		floats.append_array(cell_floats_beads(origin + Vector2(s.x, s.y), r, s.z > 0.5, _beads))
		# u: 0 at the tail (-x) to 1 at the head (+x); v: -1..1 across.
		list.append(Vector3((s.x - lo.x) / maxf(hi.x - lo.x, 1.0), (s.y - (lo.y + hi.y) * 0.5) / half, 0.0))
	_colony.add_creature(floats)
	_cells.append(list)

func _physics_process(delta: float) -> bool:
	var t := _frame * delta
	var ramp := clampf((_frame - 20) / 40.0, 0.0, 1.0)
	var t0 := Time.get_ticks_usec()
	for ci: int in _cells.size():
		var list: PackedVector3Array = _cells[ci]
		_scales.resize(list.size())
		for i: int in list.size():
			var c := list[i]
			var s := sin(TAU * (_waves * c.x + _freq * t)) * (c.y if _gait == "bend" else 1.0)
			_scales[i] = 1.0 + _amp * ramp * s
		_colony.set_cell_muscles(ci, _scales)
	var script_us := Time.get_ticks_usec() - t0
	_sim.step(delta)
	_frame += 1
	if _frame == _settle_frames:
		for ci: int in _cells.size():
			_start.append(_colony.creature_center(ci))
	if _frame > _settle_frames:
		var stt := _colony.stats()
		_times.append(stt["total_us"] / 1000.0)
		_script_times.append(script_us / 1000.0)
		var centers: PackedVector2Array = _colony.creature_cell_centers(0)
		var head_i := 0
		for i: int in centers.size():
			if centers[i].x > centers[head_i].x:
				head_i = i
		var body := _colony.creature_center(0)
		_head_y = Vector2(minf(_head_y.x, centers[head_i].y - body.y), maxf(_head_y.y, centers[head_i].y - body.y))
		for key: String in ["own_cpu_us", "own_pairs_us", "pairs_us", "solve_us", "settle_us", "cross_us", "rings_cpu_us", "sticks_cpu_us",
				"intra_cpu_us", "tension_cpu_us", "drag_cpu_us", "exposure_runs", "exposure_us", "retopos", "retopo_cpu_us", "urgent",
				"pair_builds", "cp_rebuilt", "cp_lists", "cp_snaps", "to_core", "to_ring", "broken", "made"]:
			_sums[key] = _sums.get(key, 0.0) + float(stt[key])
		if _trace:
			print("frame %d step %.2f pairs %.2f solve %.2f settle %.2f retopos %d urgent %d cp_rebuilt %d/%d" % [_frame, stt["total_us"] / 1000.0,
				stt["pairs_us"] / 1000.0, stt["solve_us"] / 1000.0, stt["settle_us"] / 1000.0, stt["retopos"], stt["urgent"], stt["cp_rebuilt"], stt["cp_lists"]])
		if _frame % 5 == 0:
			var snd := _colony.soundness()
			for key: String in snd:
				var w: float = _worst.get(key, INF if key == "area_min" else -INF)
				_worst[key] = minf(w, snd[key]) if key == "area_min" else maxf(w, snd[key])
	if _frame >= _settle_frames + int(_seconds * 60.0):
		_report()
		return true
	return false

func _report() -> void:
	var speeds := PackedFloat64Array()
	var across := 0.0
	for ci: int in _cells.size():
		var moved := _colony.creature_center(ci) - _start[ci]
		speeds.append(moved.x / _seconds)
		across += absf(moved.y) / _seconds / _cells.size()
	var mean := 0.0
	for v: float in speeds:
		mean += v / speeds.size()
	var sorted := speeds.duplicate()
	sorted.sort()
	var n := _times.size()
	var tt := _times.duplicate()
	tt.sort()
	var ss := _script_times.duplicate()
	ss.sort()
	var st := _colony.stats()
	print("colony_swim: speed %.1f px/s along +x (creatures %.1f..%.1f), %.1f px/s across; body %.0f px long: %.3f body lengths per cycle" % [
		mean, sorted[0], sorted[sorted.size() - 1], across, _length, mean / _freq / _length])
	print("colony_swim: head's swing about the centre %.1f px peak to peak" % (_head_y.y - _head_y.x))
	print("colony_swim: step ms median %.2f p95 %.2f max %.2f; script (muscles) median %.2f p95 %.2f; sticks %d, rings %d, cores %d" % [
		tt[n / 2], tt[int(n * 0.95)], tt[n - 1], ss[n / 2], ss[int(n * 0.95)], st["sticks"], st["rings"], st["cores"]])
	print("colony_swim: soundness worst (every 5th frame): own inside %d, cross inside %d, inside out %d, ring area min %.2f, core overlap own %.2f / cross %.2f px" % [
		int(_worst["own_inside"]), int(_worst["cross_inside"]), int(_worst["inverted"]), _worst["area_min"], _worst["own_core_overlap"], _worst["cross_core_overlap"]])
	var line := "colony_swim: means per frame:"
	for key: String in _sums:
		line += " %s=%.3f" % [key.trim_suffix("_us"), _sums[key] / n / (1000.0 if key.ends_with("_us") else 1.0)]
	print(line)
	print("SWIM model=%s shape=%s gait=%s beads=%d crowd=%d speed=%.2f bl_per_cycle=%.3f step_ms=%.2f/%.2f own_inside=%d cross_inside=%d inverted=%d area_min=%.2f" % [
		_model, _shape, _gait, _beads, _crowd, mean, mean / _freq / _length, tt[n / 2], tt[int(n * 0.95)], int(_worst["own_inside"]),
		int(_worst["cross_inside"]), int(_worst["inverted"]), _worst["area_min"]])

## The CELL_STRIDE floats of a cell of radius `r` with `beads` beads for the smallest cell
## (GooTuning.tuning() otherwise: masses, bead radius, ring radius and springs recomputed
## for the count, as tools/colony_bench.gd's), no linear damping (the water drags it) and
## a quarter of the internal damping (the fluid game's RING_INTERNAL_DAMP_SCALE).
static func cell_floats_beads(at: Vector2, r: float, core: bool, beads: int) -> PackedFloat32Array:
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
		GooTuning.BENDING_RATIO * skin_d, t["internal_damp"] * 0.25, 0.0, PI * r * r, 1.0, 1.0, 1.0])
