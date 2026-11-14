@tool
class_name GooCellType
extends Resource
## A kind of cell for GooCellWorld2D's creatures (docs/cells.md): how its cells look,
## weigh, hold their shape, collide and join, and a free dictionary for what a game makes
## of it (a thruster's force, a spike's damage, a sensor's range). A GooCellDesign names
## its types in its `types` palette; the world gives each distinct GooCellType one of the
## kernel's 16 type slots the first time a creature uses it, so a type edited after that
## needs GooCellWorld2D.update_type().

## How a type's cells hold their shape (GooCells' body modes).
enum Body {
	## The world's `body_mode`.
	DEFAULT,
	## Oriented links: each link remembers its angle in both cells' frames. Joints, hinges
	## and per-link bending; a little dearer.
	LINKS,
	## Shape matching: each cell and its linked neighbours of its region pulled toward
	## their design. Cheaper, holds its shape better; a region bends only as a whole at
	## its joints.
	SHAPE,
	## Nothing but the links' lengths: floppy.
	NONE,
}

## The type's name (for a game's own use; the world reads nothing from it).
@export var name: StringName = &"plain"
## The skin's colour of this type's cells.
@export var color: Color = Color(0.35, 0.75, 0.45)
@export_group("Look")
## The goo skin's walls round this type's cells (goo_honeycomb.gdshader): their colour
## (alpha 0: the type's colour, darker; alpha blends toward it) and how strong they are
## (× the world's wall_strength).
@export var wall_color: Color = Color(0, 0, 0, 0)
@export_range(0.0, 4.0, 0.01, "or_greater") var wall_strength: float = 1.0
## Each cell's own light (× the world's cell_light: its shading and dim reflection).
@export_range(0.0, 4.0, 0.01, "or_greater") var dome: float = 1.0
## Its highlights (the specular, the cells' own) × this.
@export_range(0.0, 4.0, 0.01, "or_greater") var gloss: float = 1.0
## The goo's own colour over what shows through (× the world's goo_opacity).
@export_range(0.0, 4.0, 0.01, "or_greater") var opacity: float = 1.0
@export_group("")
## Mass per area × this (a cell's mass is its area × the world's density × this).
@export_range(0.05, 20.0, 0.01, "or_greater") var mass_factor: float = 1.0
## A design's radius × this when the creature is made.
@export_range(0.1, 4.0, 0.01, "or_greater") var radius_factor: float = 1.0
## The links' stretch stiffness × this (a link takes the geometric mean of its two cells').
@export_range(0.0, 4.0, 0.01, "or_greater") var stretch: float = 1.0
## The links' bending stiffness × this (oriented links and joints).
@export_range(0.0, 4.0, 0.01, "or_greater") var bend: float = 1.0
## The world's elasticity (GooCellWorld2D.elasticity, or a creature's own) × this for its
## cells: below 1 stiffer (a spine row 0.5 keeps a worm's back while its flanks give), 0 as
## stiff as without elasticity, above 1 softer (clamped at 1 in all).
@export_range(0.0, 4.0, 0.01, "or_greater") var elasticity: float = 1.0
## The break force × this (a link takes the smaller of its two cells').
@export_range(0.0, 10.0, 0.01, "or_greater") var break_factor: float = 1.0
## How its cells hold their shape.
@export var body: Body = Body.DEFAULT
## Its outline cells collide with other creatures' cells.
@export var collides: bool = true
## Its cells collide with the walls.
@export var collides_walls: bool = true
## Its cells collide with their own creature's cells they are not linked to (the world's
## self_collision TYPES mode; the other modes ignore it).
@export var self_collides: bool = false
## px (at GooTuning.unit 1) added to its cells' radius against other creatures.
@export var contact_pad: float = 0.0
## The join layers this type is in (bits, like physics layers).
@export_flags("1", "2", "3", "4", "5", "6", "7", "8") var join_layer: int = 1
## The join layers it joins at a retopology: two cells may join when each one's mask
## holds a layer of the other.
@export_flags("1", "2", "3", "4", "5", "6", "7", "8") var join_mask: int = 255
## Its cells are the creature's spine for the handle-driven pose (GooCellWorld2D.pose_solve,
## docs/cells.md): the pose wave positions them and the rest follows. A creature with fewer
## than two such cells, or with them bunched in under a third of its length, gets an
## automatic centreline instead.
@export var pose_handle: bool = false
## Its cells' share of the swim drive (GooCellCreature.set_swim()): × their mass; 1 a
## plain cell, more a fin or spine that pushes harder, 0 none. The creature's whole push
## stays what set_swim() asks; the weights only share it out.
@export_range(0.0, 10.0, 0.01, "or_greater") var swim_weight: float = 1.0
@export_group("Thruster and tip")
## A thruster's maximum thrust (px/s² at GooTuning.unit 1): an acceleration of the cell's
## own mass. A thrust level (GooCellCreature.set_thrust_levels(), −1..1) pushes the cell
## along its facing (its design angle turned with it) with level × this × its mass, so a
## creature whose thrusters weigh a share s of it, all pushing one way at full level,
## accelerates at s × this (before drag). 0: not a thruster.
@export_range(0.0, 20000.0, 1.0, "or_greater") var max_thrust: float = 0.0
## A spike's tip: a small disc `tip_length` × the cell's radius out from its centre along
## its facing (0: no tip), of `tip_radius` × the cell's radius, held rigidly by the cell
## (a push on it pushes and turns the cell and its linked neighbours). It collides with
## walls, moving obstacles, coupled rings and other creatures' cells and tips (swept, so a
## spinning spike does not pass through a thin wall), never with its own creature, and is
## not drawn (GooCellCreature.tips() says where it is). Keep tip_length − tip_radius above
## 1 so the tip stands out of its cell, and tip_radius at most 1.
@export_range(0.0, 4.0, 0.01, "or_greater") var tip_length: float = 0.0
@export_range(0.0, 1.0, 0.01) var tip_radius: float = 0.3
@export_group("")
## Whatever a game's behaviours read (a thruster's force, a sensor's range...).
@export var behaviours: Dictionary = {}

## GooCells.set_type()'s parameters, but the join mask (the world works it out from every
## slot's layers); the pad and the maximum thrust × unit.
func kernel_params() -> Dictionary:
	var modes := [GooCells.BODY_DEFAULT, GooCells.BEND_LINK, GooCells.BEND_SHAPE, GooCells.BEND_NONE]
	return {
		"stretch": stretch, "bend": bend, "break": break_factor, "self_collide": self_collides,
		"pad": contact_pad * GooTuning.unit, "body": modes[body], "collide": collides,
		"walls": collides_walls, "color": color, "swim": swim_weight,
		"thrust": max_thrust * GooTuning.unit, "tip_len": tip_length, "tip_rad": tip_radius if tip_length > 0.0 else 0.0,
		"elastic": elasticity, "pose_handle": pose_handle,
	}

## The look table's row of this type (goo_honeycomb.gdshader's type_look): wall_strength,
## dome, gloss, opacity.
func look_row() -> Vector4:
	return Vector4(wall_strength, dome, gloss, opacity)

## Whether cells of this type and of `other` may join (each one's mask holds a layer of
## the other's).
func joins(other: GooCellType) -> bool:
	return (join_mask & other.join_layer) != 0 and (other.join_mask & join_layer) != 0
