class_name Game
extends GooWorld2D
## The demo's game: a GooWorld2D that launches blobs from the arena's launch
## point (launch(), sizes and shapes from its DropController), cuts every blob
## that one of the arena's Blades reaches (_check_blades(), through
## GooWorld2D.cut_at_tips()) and starts over on reset(). Merging, splitting and
## the rest of the goo's rules are the world's.
##
## Blades: every physics frame, a blob whose collision outline a blade's tip
## touches or is inside is cut along the blade's axis, whatever its speed or
## pressure, through the same cut() a pinch uses. A cut that would leave a
## sliver is refused and tried again next frame while the tip only touches the
## blob, so a blob grazing a tip is cut once it has slid or sunk onto it far
## enough for both pieces to be viable; the pieces' split lock keeps them from
## being cut again straight away. A blob with the tip inside its bead loop is
## never left on it: it is cut through its split lock, woken if asleep, and
## trimmed off the tip if a cut would leave a sliver (GooWorld2D.cut_along()).
## The wedge's apex does the same to a blob it has got into, along the wedge's
## axis (GooWorld2D.pierce()); a blob merely resting on it is left to its pinch.

## The arena the blobs play in; launch() starts blobs from its launch_point().
@export var arena: Arena

## Decides the next drop's size and the cooldown. Replace it to inject a seeded RNG.
var controller: DropController = DropController.new()

func _physics_process(delta: float) -> void:
	controller.tick(delta)
	_check_blades()
	super(delta)

## Launches a blob of next_radius() and next_shape() from the arena's launch
## point at `velocity` (px/s; see DropController.launch_velocity()). Returns
## null while the cooldown is running.
func launch(velocity: Vector2) -> Goo2D:
	if not controller.can_drop():
		return null
	var shape := controller.next_shape
	var radius := controller.take()
	var point := arena.launch_point() if arena != null else Arena.LAUNCH_POINT
	var blob := spawn(radius, point, shape)
	blob.set_velocity(velocity)
	return blob

## Removes every blob, forgets pending merges (clear()) and ends the cooldown.
func reset() -> void:
	clear()
	controller.cooldown_remaining = 0.0

## Radius, in px, of the next drop.
func next_radius() -> float:
	return controller.next_radius

## Shape of the next drop, at next_radius().
func next_shape() -> GooShape:
	return controller.next_shape

# Asks for a cut of every blob a blade's tip touches or is inside, along that
# blade's axis (GooWorld2D.cut_at_tips(): blobs that are merging or already
# waiting for a split are left alone, and split-locked ones unless the tip is
# inside), at most one per blob; then of every blob the wedge's apex is inside,
# along the wedge's axis (GooWorld2D.pierce()).
func _check_blades() -> void:
	if arena == null:
		return
	var tips := PackedVector2Array()
	var axes := PackedVector2Array()
	for blade: Blade in arena.blades():
		tips.append(blade.tip())
		axes.append(blade.axis())
	cut_at_tips(tips, axes)
	pierce(arena.wedge_apex(), arena.wedge_axis())
