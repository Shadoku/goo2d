class_name ColorMergeWorld
extends GooWorld2D
## A GooWorld2D whose blobs merge by colour, not by size: two touching blobs
## combine when their `color`s are equal, whatever their sizes, as long as the
## merged blob stays within GooTuning.max_radius() (the largest size the goo's
## tuning was measured for); the merged blob takes their colour. Blobs of two
## colours only ever bump into each other.
##
## The two hooks it overrides are the only ones it needs: may_merge(), the one
## place the world asks which touching pairs combine, and merged_color(), the
## colour of the body a merge makes (split pieces keep their parent's colour by
## themselves, Goo2D.inherit_look()).

## The four colours blobs come in: red, yellow, green, blue.
const PALETTE: Array[Color] = [
	Color(0.95, 0.27, 0.33),
	Color(1.0, 0.82, 0.2),
	Color(0.22, 0.84, 0.46),
	Color(0.26, 0.5, 0.98),
]
## The colours' names, in PALETTE's order, for the UI.
const PALETTE_NAMES: Array[String] = ["red", "yellow", "green", "blue"]

## True when the touching `a` and `b` combine: their colours are equal and the
## merged blob is no bigger than GooTuning.max_radius(). Two blobs both left at
## Goo2D.COLOR_BY_SIZE (say, placed in the editor without a colour) follow the
## default rule (by size, GooWorld2D.can_merge()).
func may_merge(a: Goo2D, b: Goo2D) -> bool:
	if a.color != b.color:
		return false
	if a.color == Goo2D.COLOR_BY_SIZE:
		return can_merge(a, b)
	return GooTuning.merged_radius(a.radius, b.radius) <= GooTuning.max_radius()

## The merged blob's colour: the pair's (may_merge() only lets equal colours
## merge; for two blobs coloured by size, by its own size).
func merged_color(a: Goo2D, _b: Goo2D) -> Color:
	return a.color

## Spawns a round blob of `radius` (px) centred on `global_pos` in `colour`.
func spawn_colored(radius: float, global_pos: Vector2, colour: Color) -> Goo2D:
	var body := spawn(radius, global_pos)
	body.color = colour
	return body

## A random palette colour, drawn from `rng`.
static func random_color(rng: RandomNumberGenerator) -> Color:
	return PALETTE[rng.randi_range(0, PALETTE.size() - 1)]
