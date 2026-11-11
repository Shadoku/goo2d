class_name Arena
extends StaticBody2D
## The container: a wide 16:9 floor, two walls and a wedge standing on the floor
## right of centre, a sharp triangle that pinches a big blob landing on it in two
## (see Goo2D.pinch()) and cuts one that its apex gets into (wedge_axis()), and two Blade children: FloorBlade standing
## on the floor left of centre and WallBlade sticking out of the left wall, steel
## spikes that cut any blob their tip gets into (see Game._check_blades()).
## Blobs launch from the upper right and are thrown left and down across the
## arena. Positions are in the arena's local space; the accessors return global
## coordinates, through the arena's transform (tools/stability.gd and
## tools/bench.gd scale it with --unit).

## X of the left wall's inner face.
const INNER_LEFT: float = 160.0
## X of the right wall's inner face.
const INNER_RIGHT: float = 1760.0
## Distance between the inner wall faces.
const INNER_WIDTH: float = INNER_RIGHT - INNER_LEFT
## Y of the floor's top face.
const FLOOR_Y: float = 1000.0
## Y of the top of the walls.
const WALL_TOP_Y: float = 120.0
## Y at which new blobs are dropped.
const DROP_Y: float = 140.0
## Distance of the launch point left of the right wall's inner face: clear of
## the wall for the largest drop (DropController.DROP_MAX_RADIUS) with room to aim.
const LAUNCH_INSET: float = 120.0
## Point, in the arena's local space, that new blobs are launched from: the
## upper right, LAUNCH_INSET in from the right wall, at DROP_Y. Blobs are thrown
## left and down from here across the arena.
const LAUNCH_POINT := Vector2(INNER_RIGHT - LAUNCH_INSET, DROP_Y)
## Friction of the arena's PhysicsMaterial (set in arena.tscn), which GooStatics
## hands the goo's kernel with the arena's shapes. A contact uses the lower
## friction of the two, so blobs feel min(this, GooTuning.BLOB_FRICTION), plus
## the wall grip (GooTuning.WALL_GRIP_DAMP) the arena's walls and floor give.
const WALL_FRICTION: float = 0.4
## Bounce of the arena's PhysicsMaterial (set in arena.tscn). A contact adds the
## two bounces, clamped to 0..1, so this adds to GooTuning.bounce().
const WALL_BOUNCE: float = 0.3
## X of the wedge's apex and of the middle of its base. Right of the arena
## centre, where blobs land and rest, and left of the launch column, so a blob
## let go straight down from the launch point misses it.
const WEDGE_X: float = 1300.0
## Half the width of the wedge's base on the floor.
const WEDGE_HALF_WIDTH: float = 40.0
## Height of the wedge's apex above the floor.
const WEDGE_HEIGHT: float = 140.0
## Direction, in the arena's local space, the wedge points in from its base
## to its apex: the axis Game cuts a blob with the apex inside it along (see
## Game._check_blades()), as a Blade's axis.
const WEDGE_AXIS := Vector2.UP

## Global x of the left wall's inner face.
func inner_left() -> float:
	return to_global(Vector2(INNER_LEFT, 0.0)).x

## Global x of the right wall's inner face.
func inner_right() -> float:
	return to_global(Vector2(INNER_RIGHT, 0.0)).x

## Global y of the floor's top face.
func floor_y() -> float:
	return to_global(Vector2(0.0, FLOOR_Y)).y

## Global position of the wedge's apex.
func wedge_apex() -> Vector2:
	return to_global(Vector2(WEDGE_X, FLOOR_Y - WEDGE_HEIGHT))

## Unit vector, in global space, from the middle of the wedge's base to its
## apex (the arena is not rotated, as wedge_apex() assumes too).
func wedge_axis() -> Vector2:
	return WEDGE_AXIS

## Global point new blobs are launched from.
func launch_point() -> Vector2:
	return to_global(LAUNCH_POINT)

## The arena's blades: its direct children that are Blades.
func blades() -> Array[Blade]:
	var result: Array[Blade] = []
	for child: Node in get_children():
		var blade := child as Blade
		if blade != null:
			result.append(blade)
	return result
