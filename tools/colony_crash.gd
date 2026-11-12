extends SceneTree
## Two hex clusters thrown into each other (docs/colony-exposure.md's crash), the full
## model (GooColonySim.everything_options()) against the frozen topology
## (frozen_options()) and some of its knobs, soundness every frame (docs/colony-frozen.md).
##
##   godot --headless --fixed-fps 60 --path . -s tools/colony_crash.gd -- [--rings=3] [--threads=4] [--beads=12]
##
## --rings: rings of cells around the middle one (3: 37 cells, 5: 91); --beads: beads of
## the smallest cell (12 is GooTuning's); --substeps (6). Each row settles 30 frames in its own model, then
## the clusters meet at 300 and at 600 px/s each; the table has the worst over the 90
## frames after the throw.

const DELTA: float = 1.0 / 60.0

var _rings: int = 3
var _threads: int = 4
var _beads: int = 12
var _substeps: int = 6

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--rings="): _rings = int(value)
		elif arg.begins_with("--threads="): _threads = int(value)
		elif arg.begins_with("--beads="): _beads = int(value)
		elif arg.begins_with("--substeps="): _substeps = int(value)
		else: push_error("colony_crash: unknown option %s" % arg)
	GooTuning.unit = 0.5
	var full := GooColonySim.everything_options()
	var frozen := GooColonySim.frozen_options()
	var rows := [
		["full (everything_options)", full],
		["frozen (frozen_options)", frozen],
		["frozen, Verlet own list (skin 10)", frozen.merged({ "frozen_self": 3, "pair_skin": 10.0 }, true)],
		["frozen, no own contacts", frozen.merged({ "frozen_self": 0 }, true)],
	]
	print("colony_crash: two hex clusters of %d cells, %d beads, unit 0.5, %d threads; worst over 90 frames after the throw, soundness every frame" % [_hex(_rings).size(), _beads, _threads])
	print("| impact, each | model | ring area min | inside out | particles inside the other creature | own particles inside own cells | core overlap own / cross px | most contacts | sticks broken |")
	print("|---|---|---|---|---|---|---|---|---|")
	for speed: float in [300.0, 600.0]:
		for row: Array in rows:
			var w := _throw((row[1] as Dictionary), speed)
			print("| %.0f px/s | %s | %.2f | %d | %d | %d | %.2f / %.2f | %d | %d |" % [speed, row[0], w["area_min"], int(w["inverted"]),
				int(w["cross_inside"]), int(w["own_inside"]), w["own_cc"], w["cross_cc"], w["hits"], w["broken"]])
	quit(0)

func _throw(options: Dictionary, speed: float) -> Dictionary:
	var opts := options.duplicate()
	opts["threads"] = _threads
	opts["substeps"] = _substeps
	var sim := GooColonySim.new(opts)
	var gap := (_rings + 1) * 2.0 * GooTuning.min_radius() * 1.1
	var a := _add(sim, _hex(_rings, Vector2(-gap, 0)))
	var b := _add(sim, _hex(_rings, Vector2(gap, 14)))
	for i: int in 30:
		sim.step(DELTA)
	sim.colony.set_creature_velocity(a, Vector2(speed, 0))
	sim.colony.set_creature_velocity(b, Vector2(-speed, 0))
	var w := { "area_min": INF, "inverted": 0.0, "cross_inside": 0.0, "own_inside": 0.0, "own_cc": 0.0, "cross_cc": 0.0, "hits": 0, "broken": 0 }
	for f: int in 90:
		sim.step(DELTA)
		var snd := sim.colony.soundness()
		w["area_min"] = minf(w["area_min"], snd["area_min"])
		w["inverted"] = maxf(w["inverted"], snd["inverted"])
		w["cross_inside"] = maxf(w["cross_inside"], snd["cross_inside"])
		w["own_inside"] = maxf(w["own_inside"], snd["own_inside"])
		w["own_cc"] = maxf(w["own_cc"], snd["own_core_overlap"])
		w["cross_cc"] = maxf(w["cross_cc"], snd["cross_core_overlap"])
		var st := sim.colony.stats()
		w["hits"] = maxi(w["hits"], st["cross_hits"])
		w["broken"] += st["broken"]
	return w

func _add(sim: GooColonySim, cells: Array) -> int:
	var floats := PackedFloat32Array()
	for c: Dictionary in cells:
		floats.append_array(cell_floats_beads(c["position"], c["radius"], false, _beads, GooTuning.tuning(c["radius"])["linear_damp"]))
	return sim.colony.add_creature(floats)

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

static func _hex(rings: int, at: Vector2 = Vector2.ZERO) -> Array:
	var r := GooTuning.min_radius()
	var cells: Array = []
	for q: int in range(-rings, rings + 1):
		for p: int in range(-rings, rings + 1):
			if absi(p + q) <= rings:
				cells.append({ "position": at + Vector2(p * 2.0 * r + q * r, q * sqrt(3.0) * r), "radius": r })
	return cells
