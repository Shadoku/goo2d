extends RefCounted
## Creature designs for GooCells (docs/explore-cells.md), as Array[Vector3] (x, y, radius)
## about the centroid: hex worms and blobs, a tadpole (a hex blob with a hex tail) and
## free-form packings of mixed sizes (the colony bench's generator, tools/colony_bench.gd's
## _design(), with a radius range: cells placed tangent to two touching cells, scored by
## the shape). Helpers to add one to a GooCells.

const R := 14.0

## A hex worm `long` cells along +x by `wide` rows.
static func worm(long: int, wide: int, r: float = R) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for row: int in wide:
		var y := (row - (wide - 1) * 0.5) * 2.0 * r * 0.8660254
		var shift := r if row % 2 == 1 else 0.0
		for k: int in long:
			out.append(Vector3((k - (long - 1) * 0.5) * 2.0 * r + shift, y, r))
	return _centred(out)

## A hex blob of `rings` rings (1 + 3 rings (rings + 1) cells).
static func blob(rings: int, r: float = R) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for q: int in range(-rings, rings + 1):
		for s: int in range(-rings, rings + 1):
			if absi(-q - s) > rings:
				continue
			out.append(Vector3(2.0 * r * (q + s * 0.5), 2.0 * r * s * 0.8660254, r))
	return _centred(out)

## A hex blob of about `count` cells (the hex cells nearest the centre).
static func blob_count(count: int, r: float = R) -> Array[Vector3]:
	var all := blob(int(ceil(sqrt(count / 3.0))) + 1, r)
	all.sort_custom(func(a: Vector3, b: Vector3) -> bool: return Vector2(a.x, a.y).length_squared() < Vector2(b.x, b.y).length_squared() or (Vector2(a.x, a.y).length_squared() == Vector2(b.x, b.y).length_squared() and a.x < b.x))
	return _centred(all.slice(0, count))

## A tadpole: a hex head of `head` cells at +x and a tail `tail_long` × `tail_wide` behind it.
static func tadpole(head: int, tail_long: int, tail_wide: int, r: float = R) -> Array[Vector3]:
	var h := blob_count(head, r)
	var hr := 0.0
	for c: Vector3 in h:
		hr = maxf(hr, absf(c.x))
	var out: Array[Vector3] = h.duplicate()
	var t := worm(tail_long, tail_wide, r)
	var tl := 0.0
	for c: Vector3 in t:
		tl = maxf(tl, c.x)
	for c: Vector3 in t:
		var p := Vector3(c.x - tl - hr - 2.0 * r + r * 0.0, c.y, r)
		out.append(p)
	return _centred(out)

static func _centred(cells: Array[Vector3]) -> Array[Vector3]:
	var mean := Vector2.ZERO
	for c: Vector3 in cells:
		mean += Vector2(c.x, c.y)
	mean /= maxf(cells.size(), 1)
	var out: Array[Vector3] = []
	for c: Vector3 in cells:
		out.append(Vector3(c.x - mean.x, c.y - mean.y, c.z))
	return out

## Body length along x (outer edge to outer edge).
static func length_x(cells: Array[Vector3]) -> float:
	var lo := INF
	var hi := -INF
	for c: Vector3 in cells:
		lo = minf(lo, c.x - c.z)
		hi = maxf(hi, c.x + c.z)
	return hi - lo

static func width_y(cells: Array[Vector3]) -> float:
	var lo := INF
	var hi := -INF
	for c: Vector3 in cells:
		lo = minf(lo, c.y - c.z)
		hi = maxf(hi, c.y + c.z)
	return hi - lo

## Adds a design to `cells` at `at`, turned by `turn`; `typer(cell: Vector3) -> int` (or a
## null Callable: type 0). Returns the creature.
static func add(cells: GooCells, design: Array[Vector3], at: Vector2, turn: float = 0.0, typer: Callable = Callable()) -> int:
	var xf := Transform2D(turn, at)
	var centers := PackedVector2Array()
	var radii := PackedFloat32Array()
	var types := PackedInt32Array()
	for c: Vector3 in design:
		centers.append(xf * Vector2(c.x, c.y))
		radii.append(c.z)
		types.append(typer.call(c) if typer.is_valid() else 0)
	return cells.add_creature(centers, radii, types)

static func packed(shape: String, count: int, seed_value: int, rmin: float, rmax: float, width_cells: float = 5.0) -> Array[Vector3]:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var base := rmin
	var mix := "uniform" if rmax <= rmin else "mixed"
	var phases := [rng.randf() * TAU, rng.randf() * TAU, rng.randf() * TAU]
	var half_width := width_cells * base * (1.0 if mix == "uniform" else 0.5 * (1.0 + rmax / rmin))
	var cells: Array[Vector3] = []
	var hash := {}
	var cell_size := 4.0 * base
	var pairs: Array[Vector2i] = []
	var first_r := _next_radius(rng, rmin, rmax)
	cells.append(Vector3(0, 0, first_r))
	_hash_add(hash, cell_size, 0, Vector2.ZERO)
	var second_r := _next_radius(rng, rmin, rmax)
	cells.append(Vector3(first_r + second_r, 0, second_r))
	_hash_add(hash, cell_size, 1, Vector2(first_r + second_r, 0))
	pairs.append(Vector2i(0, 1))
	var pending := 0.0
	while cells.size() < count:
		var r := pending if pending > 0.0 else _next_radius(rng, rmin, rmax)
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
	return cells

static func _next_radius(rng: RandomNumberGenerator, rmin: float, rmax: float) -> float:
	# Mostly small cells, a few large: r = rmin + (rmax - rmin) u^3.
	return rmin if rmax <= rmin else rmin + (rmax - rmin) * pow(rng.randf(), 3.0)

static func _tangent(a: Vector3, b: Vector3, r: float, side: float) -> Vector2:
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

static func _score(shape: String, at: Vector2, r: float, half_width: float, phases: Array) -> float:
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

static func _hash_key(cell_size: float, at: Vector2) -> Vector2i:
	return Vector2i(floori(at.x / cell_size), floori(at.y / cell_size))

static func _hash_add(hash: Dictionary, cell_size: float, index: int, at: Vector2) -> void:
	var key := _hash_key(cell_size, at)
	if not hash.has(key):
		hash[key] = PackedInt32Array()
	var list: PackedInt32Array = hash[key]
	list.append(index)
	hash[key] = list

static func _hash_near(hash: Dictionary, cell_size: float, at: Vector2) -> PackedInt32Array:
	var out := PackedInt32Array()
	var key := _hash_key(cell_size, at)
	for dy: int in range(-1, 2):
		for dx: int in range(-1, 2):
			var k := key + Vector2i(dx, dy)
			if hash.has(k):
				out.append_array(hash[k])
	return out

static func _overlaps(cells: Array[Vector3], hash: Dictionary, cell_size: float, at: Vector2, r: float) -> bool:
	for other: int in _hash_near(hash, cell_size, at):
		var o := cells[other]
		if Vector2(o.x, o.y).distance_to(at) < o.z + r - 0.01:
			return true
	return false

