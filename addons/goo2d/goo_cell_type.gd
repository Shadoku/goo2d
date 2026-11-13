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
## Mass per area × this (a cell's mass is its area × the world's density × this).
@export_range(0.05, 20.0, 0.01, "or_greater") var mass_factor: float = 1.0
## A design's radius × this when the creature is made.
@export_range(0.1, 4.0, 0.01, "or_greater") var radius_factor: float = 1.0
## The links' stretch stiffness × this (a link takes the geometric mean of its two cells').
@export_range(0.0, 4.0, 0.01, "or_greater") var stretch: float = 1.0
## The links' bending stiffness × this (oriented links and joints).
@export_range(0.0, 4.0, 0.01, "or_greater") var bend: float = 1.0
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
## Whatever a game's behaviours read (a thruster's force, a sensor's range...).
@export var behaviours: Dictionary = {}

## GooCells.set_type()'s parameters, but the join mask (the world works it out from every
## slot's layers) and the pad (× unit).
func kernel_params() -> Dictionary:
	var modes := [GooCells.BODY_DEFAULT, GooCells.BEND_LINK, GooCells.BEND_SHAPE, GooCells.BEND_NONE]
	return {
		"stretch": stretch, "bend": bend, "break": break_factor, "self_collide": self_collides,
		"pad": contact_pad * GooTuning.unit, "body": modes[body], "collide": collides,
		"walls": collides_walls, "color": color,
	}

## Whether cells of this type and of `other` may join (each one's mask holds a layer of
## the other's).
func joins(other: GooCellType) -> bool:
	return (join_mask & other.join_layer) != 0 and (other.join_mask & join_layer) != 0
