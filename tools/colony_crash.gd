extends SceneTree
## explore-frozen: two hex clusters thrown into each other (docs/colony-exposure.md's
## crash), full model against frozen topology and the knobs, soundness every frame.
##
##   godot --headless --fixed-fps 60 --path . -s tools/colony_crash.gd -- [--rings=3] [--threads=4]

const DELTA: float = 1.0 / 60.0

var _rings: int = 3
var _threads: int = 4
var _beads: int = 12

func _initialize() -> void:
	for arg: String in OS.get_cmdline_user_args():
		var value := arg.get_slice("=", 1)
		if arg.begins_with("--rings="): _rings = int(value)
		elif arg.begins_with("--threads="): _threads = int(value)
		elif arg.begins_with("--beads="): _beads = int(value)
	GooTuning.unit = 0.5
	var frozen := { "frozen": true, "frozen_self": 3, "pair_skin": 10.0, "fast_search": true, "spin": true, "fast_rings": true }
	var rows := [
		["full (M2 preset)", {}],
		["full + drag", GooColonySim.DRAG_OPTIONS],
		["frozen", frozen],
		["frozen + drag", frozen.merged(GooColonySim.DRAG_OPTIONS)],
		["frozen, no own contacts", frozen.merged({ "frozen_self": 0 })],
		["frozen + 4 substeps", frozen.merged({ "substeps": 4 })],
		["frozen + sticks every 2nd substep", frozen.merged({ "stick_every": 2 })],
		["frozen + 4 substeps + sticks every 2nd", frozen.merged({ "substeps": 4, "stick_every": 2 })],
	]
	print("colony_crash: two hex clusters of %d cells, %d beads, unit 0.5, %d threads; worst over 90 frames after the throw, soundness every frame" % [_hex(_rings).size(), _beads, _threads])
	print("| impact, each | variant | ring area min | inside out | particles inside the other creature | own particles inside own cells | core overlap own / cross px | most contacts |")
	print("|---|---|---|---|---|---|---|---|")
	for speed: float in [300.0, 600.0]:
		for row: Array in rows:
			var w := _throw((row[1] as Dictionary), speed)
			print("| %.0f px/s | %s | %.2f | %d | %d | %d | %.2f / %.2f | %d |" % [speed, row[0], w["area_min"], int(w["inverted"]),
				int(w["cross_inside"]), int(w["own_inside"]), w["own_cc"], w["cross_cc"], w["hits"]])
	quit(0)

func _throw(extra: Dictionary, speed: float) -> Dictionary:
	# Settled 30 frames by the full model (cores form), then the variant's options.
	var opts := GooColonySim.EXPOSURE_OPTIONS.duplicate()
	opts["threads"] = _threads
	var sim := GooColonySim.new(opts)
	var gap := (_rings + 1) * 2.0 * GooTuning.min_radius() * 1.1
	var a := _add(sim, _hex(_rings, Vector2(-gap, 0)))
	var b := _add(sim, _hex(_rings, Vector2(gap, 14)))
	for i: int in 30:
		sim.step(DELTA)
	sim.colony.set_options(extra)
	sim.colony.set_creature_velocity(a, Vector2(speed, 0))
	sim.colony.set_creature_velocity(b, Vector2(-speed, 0))
	var w := { "area_min": INF, "inverted": 0.0, "cross_inside": 0.0, "own_inside": 0.0, "own_cc": 0.0, "cross_cc": 0.0, "hits": 0 }
	for f: int in 90:
		sim.step(DELTA)
		var snd := sim.colony.soundness()
		w["area_min"] = minf(w["area_min"], snd["area_min"])
		w["inverted"] = maxf(w["inverted"], snd["inverted"])
		w["cross_inside"] = maxf(w["cross_inside"], snd["cross_inside"])
		w["own_inside"] = maxf(w["own_inside"], snd["own_inside"])
		w["own_cc"] = maxf(w["own_cc"], snd["own_core_overlap"])
		w["cross_cc"] = maxf(w["cross_cc"], snd["cross_core_overlap"])
		w["hits"] = maxi(w["hits"], sim.colony.stats()["cross_hits"])
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
