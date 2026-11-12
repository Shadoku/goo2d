# Goo2D

Soft, wet, jiggly 2D goo bodies for Godot 4.7: round blobs and polygon shapes that squash,
bounce, settle, merge when they touch, split when they are pinched, crushed or cut, and are
drawn as translucent goo with bubbles inside.

The addon is nine scripts, one shader, the plugin's script and a native kernel (`GooKernel`, a
Rust GDExtension in `native/` that owns the goo's beads and moves them with its own
position-based solver). Each file is one system with its
knobs at the top. Most numbers you might want to change sit in one of two places:
`goo_tuning.gd` (how the goo feels, sizes and colours) and `goo.gdshader` (how it looks); the
body's and the rules' own constants head `goo2d.gd` and `goo_world_2d.gd`. The rest of this file
says where each system lives, what it exposes and which knobs it has.

## Requirements

- Godot 4.7 (the project this ships with pins `4.7.2-stable`).
- The native kernel's library for your platform in `addons/goo2d/bin/`:
  `addons/goo2d/goo2d.gdextension` loads it and registers `GooKernel`. The goo does not run
  without it: the kernel owns every bead and moves it. The libraries are committed (linux
  x86_64, windows x86_64, macOS universal: `.github/workflows/kernel.yml` builds them on every
  push that touches the kernel and commits them back), so a clone has them. Rebuild only to
  change the Rust crate in `addons/goo2d/native/` (`bash tools/build_native.sh` in the host
  project; needs [Rust](https://rustup.rs), stable; the first release build takes about two
  minutes, later ones only rebuild what changed). `bash tools/install_native.sh` fetches the
  libraries for a checkout that lacks them. No web build yet.
- No particular physics engine: Godot's default 2D physics is fine, and so is any other. The
  goo has no physics bodies of its own and never calls the physics server: its beads collide
  with each other and with the static geometry mirrored from your scene (below) inside the
  kernel. A contact uses the lower of the two frictions and the sum of the two bounces
  (clamped to 0..1), whatever the engine would do.
- Default 2D gravity of 980 px/s² (Godot's default): `GooTuning.gravity()` reads
  `physics/2d/default_gravity` (and the direction from `default_gravity_vector`) for the solver
  and scales the pressure by it, but every other constant was measured at 980.
- Walls and floors: every `StaticBody2D` (an `AnimatableBody2D` too) on physics layer 1
  (`GooTuning.LAYER_WALLS`) anywhere in the scene tree is what the goo collides with:
  `GooStatics` mirrors its `CollisionShape2D` children (rectangles, convex polygons, circles,
  capsules) and `CollisionPolygon2D` children into the kernel as convex polygons, with its
  material's friction and bounce, follows them when they move, and picks up bodies added or
  removed. Other shape types (segments, concave polygons, world boundaries) are skipped with a
  warning. A static body in the group `GooTuning.NO_GRIP_GROUP` (`"goo_no_grip"`) is not
  gripped: put sharp things there (the demo's blades), so a body grazing them slides off instead
  of hanging on. The goo uses no other physics layer.
- Tile walls: every `TileMapLayer` with `collision_enabled` whose TileSet has a physics layer on
  `LAYER_WALLS` is a wall too. `GooStatics` reads its used cells' collision polygons off the
  TileSet (at each cell's `map_to_local()`, flipped and transposed as the cell says), merges
  neighbouring cells and splits the outline into a few convex pieces (`GooStatics.bake_cells()`:
  a wall of sixty tiles is one rectangle, not sixty squares; a ring of tiles around an empty
  cell is filled, with a warning). Friction and bounce come from that physics layer's
  `PhysicsMaterial` (Godot's defaults without one) or, since a TileSet is often shared by several
  layers, from a `PhysicsMaterial` in the layer's metadata `GooStatics.MATERIAL_META`
  (`"goo_physics_material"`); a layer in `NO_GRIP_GROUP` is not gripped, as a body. A `Rect2` in
  its metadata `GooStatics.CLIP_META` (`"goo_clip"`, in the layer's space) leaves out the cells
  wholly outside it (where no goo can go; one crossing it is kept whole). The mirror follows the
  layer moving, its `changed` (a TileSet swapped, `collision_enabled` toggled) and its cells
  (`set_cell()` emits nothing, so `sync()` compares the layer's `tile_map_data` with what it last
  merged, a few kB, every frame); the merge is kept while the TileSet, cells and clip stay. Edit a
  TileSet's polygons, or a layer's metadata or group, and call `GooWorld2D.refresh_static_shapes()`.
  The layer's own physics bodies are never read (only its `collision_enabled`), so Godot's
  physics may keep them or not.

The renderer does not matter, but the goo shader reads the screen texture, so it needs something
drawn behind the goo to refract. The demo project draws a dotted backdrop for that.

## Install

Copy `addons/goo2d/` into your project; its `bin/` holds the native libraries for every
desktop platform, built from the same commit as the scripts (`bin/kernel-commit.txt` names it).
If they are missing or stale, either build them (`cargo build --release` in
`addons/goo2d/native/`, then copy `target/release/libgoo2d_kernel.so` to `bin/` under the name
`goo2d.gdextension` gives this platform, which is what the host project's
`tools/build_native.sh` does), or unzip a build's `goo2d-kernel.zip` at your project's root (it
holds `addons/goo2d/bin/`; the host project's `tools/install_native.sh [tag]` downloads it, the
branch's rolling build by default; `.github/workflows/kernel.yml` publishes one for every push
that touches the kernel and for every tag `v<crate version>`). Libraries and scripts belong
together: take both from the same commit.
The crate's folder holds a `.gdignore`, so Godot neither scans nor exports it. Then enable "Goo2D" under Project Settings > Plugins
(optional: the node types are registered by their `class_name` as soon as the project is
imported). Then the two node types appear in the Create New Node dialog under Node2D.

## Quick start

In the editor: add a `GooWorld2D` node, then one `Goo2D` child per blob. Set each blob's
`radius` (its nominal radius in px, 28 … 176) and either `sides` (0 for a round blob, 3 or more
for a regular polygon resting on a side) or a custom `outline` polygon; the viewport previews its
rest outline, filled in its `color` (left at its default, `Goo2D.COLOR_BY_SIZE`, the colour of
its size), centred where you put it. Give it something to land on: a `StaticBody2D` on physics
layer 1. Run the scene.

From a script:

```gdscript
var world: GooWorld2D = $GooWorld2D
var blob := world.spawn(40.0, Vector2(300, 100))                       # a round blob
var square := world.spawn(40.0, Vector2(500, 100), GooShape.regular(4, 40.0))
blob.set_velocity(Vector2(400, 0))
square.color = Color.ORANGE                         # its own colour; its split pieces keep it
world.cut_along(square, point, axis)                                  # a blade-style cut
world.cut_at_tips(blade_tips, blade_axes)       # every frame: what a set of blades does
world.pierce(apex, Vector2.UP)                  # every frame: cut whatever a static tip got into
world.despawn(blob)                                                   # remove one body
world.merged.connect(func(radius: float, at: Vector2) -> void: print("merged into %.0f px" % radius))
```

A game changes the world's rules by extending `GooWorld2D` and overriding its hooks:
`may_merge(a, b)` decides which touching pairs combine (the default is the static
`can_merge()`: round bodies by size, shapes flat face to flat face) and `merged_color(a, b)` what
colour the merged body is (the default, `Goo2D.COLOR_BY_SIZE`, colours it by its size). A world
that merges bodies of one colour, whatever their sizes:

```gdscript
class_name ColourWorld
extends GooWorld2D

func may_merge(a: Goo2D, b: Goo2D) -> bool:
	return a.color == b.color and GooTuning.merged_radius(a.radius, b.radius) <= GooTuning.MAX_RADIUS

func merged_color(a: Goo2D, _b: Goo2D) -> Color:
	return a.color
```

A world may instead draw a body merged from two colours in both: turn on its
`two_tone_merges` (an export, off by default) and the merged body gets each parent's colour on
the side that parent came from, the division between them crossing the line between the
parents' centres at their area ratio (the bigger parent owns the bigger side) and turning with
the body as it rolls or tips (`Goo2D.second_color`, `division_axis`, `division_offset`). The
colours are then `merged_colors(a, b)`' (a `PackedColorArray`: one colour, or two, the first on
`a`'s side), and `merged_color()` is not asked; its default: the same colour combination merges
as usual (one colour, or the same two), any other pair takes each one's dominant colour (the one
owning the larger share, `Goo2D.dominant_color()`), so no body ever shows more than two; two
bodies both left at `COLOR_BY_SIZE` stay by size. A world that overrides `merged_color()` and
turns the switch on gets `merged_colors()`' default unless it overrides that too. The pieces of a
split keep both colours, half and half, the division running the parent's way. A body can be made
two-tone by hand too: `body.set_two_tone(primary, second, axis_rest, offset)`
(`Goo2D.division_in_rest()` turns a division given in the world into those), `clear_two_tone()`.
`examples/two_tone/` shows it.

A body carries a list of tags for the game, `Goo2D.tags` (its kinds, in order: a `StringName`, a
kind resource, anything; empty by default), which the addon only carries: `spawn(radius, pos,
shape, tags)` sets a copy, the pieces of a split and a trimmed body get a copy of their parent's,
and a merged body gets `merged_tags(a, b)` of the pair, the hook beside `merged_color()` (by
default their union in order without duplicates: `a`'s tags, then each of `b`'s not already
there). The first tag is the one that counts for now, `Goo2D.tag()` (null without one): what a
world's `may_merge()` and `tuning_for()` read. The list is there for later: merging bodies of
different kinds into new ones, by overriding `merged_tags()` (earth and water into mud).

`tuning_for(shape, tags)` decides how the world's bodies are tuned: it returns the dictionary a
ring of that rest shape is built from (by default `GooTuning.tuning_for()`, whatever the tags),
and every body the world builds goes through it with the body's tags (spawned, merged, cut,
trimmed, or placed in a scene under the world, which has none unless they were set before it
entered the tree). A world whose earth bodies are twice as heavy:

```gdscript
func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
	var values := super(shape, tags)
	if not tags.is_empty() and tags[0] == &"earth":       # the body's tag()
		for key: String in ["blob_mass", "bead_mass"]:
			values[key] *= 2.0
	return values
```

A world whose bodies are four times stiffer than everywhere else, without touching `GooTuning`
(an override keeps the `tags` parameter even when it ignores it: GDScript refuses an override
with a narrower signature):

```gdscript
extends GooWorld2D

func tuning_for(shape: GooShape, tags: Array = []) -> Dictionary:
	var values := super(shape, tags)
	for key: String in ["skin_stiffness", "bending_stiffness", "shape_match_k"]:
		values[key] *= 4.0
	return values
```

Change stiffness, damping, pressure, shape matching or masses this way; leave the keys that shape
the ring (`bead_count`, `bead_radius`, `spacing`, `target_area`) as `GooTuning` gives them, since
cuts and merges count beads from them. Which keys take how much (measured by the `tower`
example, stacking squares): `skin_stiffness` and `bending_stiffness` are XPBD constraints and
stay stable at any value (scale `skin_damping` and `bending_damping` by the square root of the
same factor to keep the damping ratio); `shape_match_k` is a compliant pull, not a fraction,
and is what keeps a square square under load (a stack leans as its squares shear into
rhombi); `pressure_k` is an explicit force and blows a resting ring apart past about 7×, so
cap it; `linear_damp` is what lets a block survive a long fall.

`may_split(body)` decides which bodies the goo may cut (default `true`): it is asked before every
cut a pinch, a crush, a blade (`cut_along()`, `cut_at_tips()`) or a tip (`pierce()`) asks for, and
a body it refuses is neither cut nor trimmed (a body of stone: `return not body.is_in_group("stone")`).
A direct `cut()` is an order and is not asked.

`gravity_scale` (an export, 1.0 by default, as `RigidBody2D`'s) scales the world's gravity, set in
the editor or at any time from a script (`world.gravity_scale = 0.5`: everything falls at half
the pull at once). Ring pressure stays tuned for the project's gravity; lone bodies keep it.

**Grabbing.** A world holds its bodies by a point for interactive play (a pointer, a finger):
`body_at(point)` finds the body whose outline holds a global point (the one drawn on top;
`Goo2D.has_point()` asks one body), `grab(body, point)` returns a handle, `move_grab(handle,
point)` moves the point it is pulled toward, `release_grab(handle, velocity)` lets go (with a
velocity, not zero, a throw: the body's mean velocity becomes it, its wobble kept), and
`grabbed(body)`, `grab_body(handle)` and `grab_point(handle)` say what is held where. Several
grabs hold at once, on several bodies or one. Each physics frame, before the step, each bead
near the point (within `GooTuning.GRAB_REACH` × the radius beyond the nearest one, weighted from
1 down to 0) gets its velocity from a critically damped spring toward the point plus its offset
when grabbed (`GRAB_STIFFNESS` × weight, `GRAB_DAMPING` × √weight; solved implicitly, so stable at
any stiffness, and moving with the point, so a dragged body does not trail it), and the beads not
held get `GRAB_CARRY` of the change the held ones get as a whole: held by its rim, a body dangles
and stretches under gravity without tearing off when dragged fast; held at its centre, it is
carried whole. Built on the bead API in GDScript; the kernel caps every bead's speed
(`MAX_BEAD_SPEED`). A held body never settles. A split, a merge, a trim, `despawn()` or `clear()`
releases its grabs (the handle then answers null, `move_grab()` does nothing, `release_grab()`
returns false); shaken hard by its rim, a body may still tear (a pinch splits it). A pointer's
grab:

```gdscript
var handle := -1

func _unhandled_input(event: InputEvent) -> void:
	var button := event as InputEventMouseButton
	if button != null and button.button_index == MOUSE_BUTTON_LEFT:
		var point := world.get_global_mouse_position()
		if button.pressed and world.body_at(point) != null:
			handle = world.grab(world.body_at(point), point)
		elif not button.pressed:
			world.release_grab(handle, Input.get_last_mouse_velocity().limit_length(800.0))
			handle = -1
	elif event is InputEventMouseMotion and handle >= 0:
		world.move_grab(handle, world.get_global_mouse_position())
```

**Resizing and deforming.** A live body changes size with `resize(new_radius, time)` and its rest
outline with `set_rest_deform(squash, axis_rest, area_scale)`, at any moment (moving, resting,
in contact, held), as often as every physics frame:

```gdscript
body.resize(120.0)                      # ease to 120 px over GooTuning.RESIZE_TIME (0.5 s)
body.resize(GooTuning.min_radius(), 2.0)   # or over 2 s; a polygon scales about its centroid
body.resized.connect(func(old: float, new: float) -> void: print("%.0f -> %.0f px" % [old, new]))
world.body_rebuilt.connect(_reattach)   # a resize rebuilt a ring with another bead count

func _physics_process(_delta: float) -> void:          # a creature swimming: every frame
	var beat := sin(Time.get_ticks_msec() * 0.006)
	body.set_rest_deform(1.0 + 0.3 * beat, Vector2.RIGHT, 1.0 + 0.1 * beat)   # squash, axis, area
```

`radius` is the new size at once (what the merge-by-size rules, a cut and the colour by size
read); the ring eases into it over `time`, or longer where `GooTuning.RESIZE_MAX_LOG_RATE` (1.5 of
log radius per second: the smallest body grows to the largest in no less than 1.23 s) asks
(`GooTuning.resize_time()`); `eased_radius()` is where it is, `is_resizing()` whether it eases.
Every physics frame of the ease the body's rest outline, bead radius and target area are its base
ring's (the ring it was last built with) scaled by eased radius / base radius, which at one bead
count is exactly the ring `GooTuning` builds at that size, and its size-dependent tuning (masses,
stiffnesses, pressure, damping, shape matching, split thresholds) runs from where it was to its
world's `tuning_for()` of the new size; all of it reaches the kernel in place
(`GooKernel.set_rest()`, `set_ring_params()`), so the beads follow through their own constraints
and push on whatever they touch. A new `resize()` while one eases starts from where the body is
(a target every frame is followed with a lag of about `time`); a merged or cut body still
inflating carries its inflate on in the ease. Only where the eased radius passes a bead count's
boundary by `GooTuning.RESIZE_COUNT_HYSTERESIS` (0.03 of `size_t()`) is the ring rebuilt with the
new count, in place (`Goo2D.rebuilt(old_points)`, then `GooWorld2D.body_rebuilt(body)`): its own
bead loop resampled at the new rest loop's perimeter fractions (`GooLoop.place_like()`), the
velocities interpolated along it, the rest lengths eased in from that loop; the same node, `id`,
kernel key, tags, colours, skin (bubbles, rotation) and children, and the world's grabs
re-attached at the point they held. A body whose ease ended inside that band holds its count and
re-rings to the size's own count after `RESIZE_SETTLE_TIME`, so a body left at a size ends up as
one spawned at it. Sizes outside `min_radius()` … `max_radius()` are clamped with a warning.

`set_rest_deform()` scales the rest outline by `squash` along `axis_rest` (a unit vector of the
rest space, turned into the world by `ring_rotation()`) and by 1 / squash across it, keeping its
area, then by √`area_scale` with the bead radius, so the target area is `area_scale` times; on top
of an ongoing resize. Nothing is rebuilt (one pass over the ring and one kernel call; nothing when
the values did not change), so it is cheap enough for every body every frame. `squash` is clamped
to `DEFORM_SQUASH_MIN` … `DEFORM_SQUASH_MAX` (0.5 … 2), `area_scale` to `DEFORM_AREA_MIN` …
`DEFORM_AREA_MAX` (0.6 … 1.6). `clear_rest_deform()` takes it away, `rest_deform()` reads it.
`ring_rotation()` (and the skin's patterns) are measured against the undeformed rest shape, which
a squash does not turn. The skin's bubbles (and a two-tone division) follow the goo through
both: while the rest outline changes (a resize's ease, a deformation, a merged or cut body's
inflate, and `Goo2D.FIELD_SETTLE_TIME`, 1 s, after) the body measures each skin update the affine
map that best carries its outline points from where they sat in the bubble field to where they
are (least squares over the beads, `GooLoop.affine_fit()`) and hands it to the skin
(`GooSkin.set_field_matrix()`), so its bubbles grow, shrink and squash with the goo instead of
the goo sliding past them; a re-ring reads the new beads' places off the old outline, so nothing
jumps; then the field is kept as it is. Measured rather than taken from the resize's and
deformation's numbers, because the beads lag both. A body that never changes its rest outline is
never measured and draws exactly as before. While a body's size eases, and whenever its deformation changes, the kernel
does not split it by a pinch or a crush for `RESIZE_SPLIT_GUARD` (0.3 s): its beads lag a rest
shape and target area that lead them, which the pinch and splat checks would read as a squeeze or
an impact. Blades and tips still cut it. `examples/resize/` shows both.
**Linking.** A world joins two of its bodies with a link, so they hold together, bend at the
joint and are drawn as one blob with a neck (a creature built from several bodies):
`link(a, b, strength, anchor_a, anchor_b)` returns a handle (-1, with an error, for a body not
its own, the same body twice or a pair linked already), `unlink(handle)` parts them,
`set_link_strength(handle, s)` and `set_link_rest_angle(handle, radians)` change it at any time
(`link_strength()`, `link_rest_angle()`, `link_bend()` read it), and `links()`, `links_of(body)`,
`linked(a, b)`, `link_bodies(handle)` and `link_info(handle)` (the `GooLink`: anchors, patch,
bridge) say what is linked; `bodies_linked(handle, a, b)` and `bodies_unlinked(handle, a_id,
b_id)` announce it. Round and polygon bodies link alike, in any combination.

```gdscript
var head := world.spawn(40.0, Vector2(400, 300))
var body := world.spawn(36.0, Vector2(480, 300), GooShape.regular(4, 36.0))
var neck := world.link(head, body, 0.7)        # 0: a thread … 1: a neck as wide as the smaller radius
world.set_link_rest_angle(neck, 0.4 * sin(t))  # every frame: a joint a game bends (clockwise > 0)
world.unlink(neck)
```

A link ties a patch of beads on one body to a patch on the other, pair by pair, in the kernel:
each pair a compliant XPBD distance constraint (`GooTuning.LINK_STIFFNESS`, `LINK_DAMPING`, per
reduced bead mass) solved every substep after the bodies' own constraints, and an angular term
pulling the bodies' relative rotation (each ring's best-fit rotation, the one shape matching
pulls toward) toward the link's rest angle (`LINK_BEND_STIFFNESS`, `LINK_BEND_DAMPING`, per
reduced moment of inertia, × the strength: a thread bends freely). Both come from one rest
pose: the two patches facing each other, `LINK_GAP` bead radii apart, the second body turned
by the rest angle about the neck, so a turned rest angle also shortens the pairs on one side of
the neck and lengthens the others, and a wide neck and a thread bend alike. The patches are
named by anchors in each body's rest space (`Goo2D.rest_shape`'s frame), so they survive a ring
rebuilt in place (the world sends the link again, its patch found from the anchors); left out,
they are the points of the two bodies nearest each other (on a polygon a face or a corner,
whichever faces the other body). `strength` sets the patch's width: `LINK_PATCH_RATIO` × the
smaller radius at 1, one pair below about 0.15. The tied beads pass through each other (the
neck does not fight itself; `LINK_THROUGH_BEADS` more beyond each end, 0 by default); every
other bead collides, and the overlap push leaves only the tied beads alone (a linked pair is
never handed to the Untangler). Linked bodies settle together and wake together. A new link
eases from where its bodies are into its rest pose over `LINK_EASE_TIME`, longer for bodies far
apart (`link_ease_speed()`), so they are drawn together rather than snapped. Linked bodies
never merge with each other (`may_merge()` is not asked; a merge transition between them is
cancelled). A split, a cut, a trim, a merge with a third body, `despawn()` or `clear()` releases
the body's links (`bodies_unlinked`, as it goes), as it releases grabs; `may_split()` is the way
to keep a linked body whole.

The joined look is the bridge skin (`GooLink.bridge_polygon()`): a polygon from one body's
outline to the other's, its two sides waist curves leaving each outline along its tangent,
reaching back into both bodies, drawn under every body (an internal child of the world, in front
of its other children, so each skin covers the part inside it) with a goo skin of its own in the
larger body's tint, shader and look uniforms (copied again whenever one changes on that body,
`GooLink.follow_look()`); the shader's rim runs along the neck's waist. Its bubble field rides
the neck: its origin is the mean of the neck's beads (the patches and the beads beyond them,
`GooSkin.field_center`) and its map the affine one that best carries their places in the field
to where they are, so the neck's bubbles turn with the pair, stretch as it is pulled, shear as
the joint bends and grow with a body, read anew when the patch is tied again (a re-ring).
`GooLink2D` places a link in the editor: a child of the world naming two `Goo2D` siblings, its
`strength` and `rest_angle`, linked once both are registered; `examples/links/` shows links of
every kind.

A subclass that overrides `_physics_process()` calls `super(delta)` (after its own cuts, as the
demo's `Game` does with `cut_at_tips()`).

A `Goo2D` also works on its own, outside any `GooWorld2D`: placed in a scene, it builds itself
in `_ready()`; from a script, `Goo2D.make(radius, global_pos, parent, shape)` builds one. It
jiggles, grips walls and emits `pinched` when it should split, but nothing merges or cuts it.
Lone bodies share one kernel of their own: they collide with each other and with the scene's
static bodies, not with the bodies of a `GooWorld2D`.
`GooWorld2D` is what turns those signals into merges and splits, keeps bodies that sank into
each other apart and frees rings threaded through each other.

### Another skin shader

Every body is drawn by `goo.gdshader` unless told otherwise: set `Goo2D.skin_shader` on a body,
or `GooWorld2D.skin_shader` on a world (every body registered in it that has none of its own
gets it; set at any time, the bodies already in the world that draw with the world's take the
new one at once, a body with a shader of its own keeps it). Split pieces and merged bodies keep their parent's shader. Any `canvas_item` shader
works; the skin pushes it these uniforms, of which it may declare any subset (`GooSkin.UNIFORMS`;
a value for one it does not declare is dropped silently):

| Uniform | What |
|---|---|
| `int point_count` | how many of `points` are the outline (at most 32) |
| `vec2 points[32]` | the collision outline in global space, a closed loop, padded with its last point |
| `vec2 center` | the body's centre, global space |
| `float radius` | px, `sqrt(target_area / PI)`: grows while a merged or cut body inflates |
| `vec2 velocity` | the body's velocity smoothed over about 0.1 s, px/s |
| `float rotation` | radians the ring has turned from its rest pose (`Goo2D.ring_rotation()`, the best-fit rotation shape matching pulls toward): a round body as it rolls, a shape as it tips over; turn a pattern by it to keep it on the body |
| `float seed` | a per-body random value (1 … 98), kept by its pieces |
| `vec2 bubble_origin`, `float bubble_cell`, `float bubble_turn` | a point moving with the body (global), a length (px: the cell the field was made with × the body's growth since) and the turn the field was inherited with (radians): the bubble field's frame, fixed in the rest pose (turned by `rotation + bubble_turn`), inherited by pieces |
| `mat2 bubble_basis` | the body's rest deformation since the field was made, in its **rest** space, determinant 1 (the scale is in `bubble_cell`): `mat2(1.0)` for a body never resized, deformed, merged or cut. A point `p`'s place in the field, in cells: `rest = rot(-rotation) * (p - bubble_origin)`, `lp = rot(-bubble_turn) * inverse(bubble_basis) * rest`, `lp / bubble_cell` (`GooSkin.field_point()` is this map in GDScript); a shader's own rest-pose patterns may undo the deformation the same way (`assets/goo/gem.gdshader`'s facets) |
| `vec4 second_color` | a two-tone body's second colour (`source_color`); transparent black (alpha 0) for a body of one colour, to be read as "the same as `COLOR`" (`GooSkin.NO_SECOND_COLOR`), so a shader that mixes it in blindly still works |
| `vec2 division_axis` | a unit vector in the body's **rest** space (a fragment's rest position is `(world - center)` turned by `-rotation`), pointing toward `second_color`'s side |
| `float division_offset` | px along `division_axis` from the rest centroid to where the division crosses it (0: half and half; above 0, `COLOR` owns more); both pushed as the division lies on the body's material now (`GooSkin` carries it as the body grows and deforms) |

`COLOR` is the body's tint (`set_tint()`: its colour, flashed during merges; a two-tone body's
primary colour, `second_color` beyond its division) and `TIME` is free. `goo.gdshader`'s
`two_tone()` is the mix to copy (the addon's shader and the project's cel, gem and pixel-art
skins in `assets/goo/` all do it): `second_color` fades in over the look uniform `division_fade`
(px, 10 by default) across the division. `goo.gdshader`'s look uniform `bubble_wobble` (1)
scales each bubble's own sway and pulse over `TIME` (0: still); with `bubble_speed` and
`bubble_lag` at 0 too, the bubbles stay put in the goo.
The `Skin` polygon is in its own local space; the top of `goo.gdshader` shows how to get a
fragment's global position (`MODEL_MATRIX` in `vertex()`). Call
`GooSkin.warm_up(self, my_shader)` once at boot for each shader a scene draws, so it compiles
before the first body shows (and `check.py`'s render stage compiles it).

```gdscript
@export var cel: Shader
func _ready() -> void:
	$GooWorld2D.skin_shader = cel          # its bodies, placed or to come, draw with it
	GooSkin.warm_up(self, cel)
```

Place a body when it is built (the builders take its centre) or set its position in the editor:
once built, the beads carry the goo in global space and the node's own transform must stay put.
Move or push beads through the body (`set_bead_position()`, `set_bead_velocity()`,
`set_velocity()`, `apply_impulse()`, `apply_force()`); there are no bead nodes.
A bare `Goo2D.new()` added from a script stays empty until a builder or `setup()` builds it.

## Where each system lives

| File | System | What it owns |
|---|---|---|
| `goo2d.gd` | **The body**: `Goo2D` (Node2D) | Its ring of beads in a `GooKernel` (its world's, or the one lone bodies share): the rest shape, rest edge lengths, corners and tuning it is built from, the kernel's events turned into signals and node state (`dispatch_events()`: `touched`, `pinched`, waking), queries on where the last step left the beads (`bead_points()`, `bead_position()`, `bead_velocity()`, `center()`, `area()`, `average_velocity()`, `bead_gripping()`, `ring_rotation()`...) and actions on them (`set_velocity()`, `apply_impulse()`, `apply_force()`, `set_bead_velocity()`, `set_bead_position()`, `set_frictionless()`, `set_pass_through()`, `wake()`) and whether a point lies inside its outline (`has_point()`); its beads' positions and velocities kept while it is out of the tree; the skin drawn from the kernel's outline, in the body's own `color` (`base_color()`; `COLOR_BY_SIZE` by default; split pieces inherit it, `inherit_look()`), or in two (`second_color` beyond a division fixed in its rest space, `division_axis`, `division_offset`; `set_two_tone()`, `clear_two_tone()`, `is_two_tone()`, `dominant_color()`, `color_set()`, the static `division_in_rest()`; split pieces get both, half and half), tinted for the moment by `set_tint(tint, second)` (`reset_tint()` back); the game's `tags` on the body (its kinds, in order; `tag()`, the first, is the one that counts), carried through splits, trims and merges, never read by the addon; the builders `make()`, `make_merged()`, `make_from_loop()` (each takes the body's tuning and tags, set before the ring is built); the GDScript reference versions of the kernel's math the tests compare it with (`find_pinch()`, `hull_depths()`, `skin_pieces()`...); the editor-facing exports and the editor preview of the rest outline (`preview_outline()`, a `@tool` script that builds nothing in the editor); resizing a live body (`resize()`, `eased_radius()`, `is_resizing()`, `resized`; the ease in `_physics_process()`, on only while it runs; the re-ring in place, `rebuilt`) and deforming its rest outline (`set_rest_deform()`, `clear_rest_deform()`, `rest_deform()`). Its only child is the `Skin`. |
| `goo_world_2d.gd` | **The rules**: `GooWorld2D` (Node2D) | The world's `GooKernel` (`kernel()`) and its `GooStatics`, stepped in `_physics_process()`; bodies coming and going (`spawn()`, `despawn()`, `clear()`); which touching bodies merge and into what (`judge_contact()` for every contact the kernel reports asks `may_merge()`, the override point, by default the static `can_merge()`; `merged_color()`, the merged body's colour, or with `two_tone_merges` on `merged_colors()`, its one or two colours, the division between them from the parents' centres and areas; `merged_tags()`, its tags, by default the pair's deduped union), how its bodies are tuned (`tuning_for(shape, tags)`, the override point every body it builds is tuned by, with its tags, by default `GooTuning.tuning_for()`; `spawn()` takes the tags), the pull-together transition, the swap for one rebuilt ring; cutting a body along a chord (`cut()`) or a line (`cut_along()`, what a blade does; `cut_at_tips()`, what a set of blades does; `pierce()`, every body a static tip is inside), trimming a body off a tip when the cut would leave a crumb; which bodies became which (the signals `body_split`, `bodies_merged`, `body_trimmed`, by `Goo2D.id`, beside `split`, `merged`, `trimmed`) and every body it registers (`body_spawned`); which bodies the goo may cut (`may_split()`, the override point asked before every cut a pinch, a blade or a tip asks for, by default true; a direct `cut()` is not asked); the world's gravity (`gravity_scale`, sent to its kernel); grabs (`grab()`, `move_grab()`, `release_grab()`, `grabbed()`, `grab_body()`, `grab_point()`: a spring from a point to the beads nearest it, applied before the step; `body_at()`, the body under a point; their offsets scale with a resized body, and a body re-rung by a resize gets them back at the point they held, then `body_rebuilt`); links (`link()`, `unlink()`, `set_link_strength()`, `set_link_rest_angle()`, `links_of()`, `linked()`, `link_bodies()`, `link_info()`, `link_bend()`; `bodies_linked`, `bodies_unlinked`; released by `_remove()` with the body, sent to the kernel again when it dropped one, bridges drawn after every step); the merge lock after a merge or split; the rules of the kernel's pair passes (pushing apart bodies that sank into each other, `intrusion()`; untangling rings threaded through each other, `Untangler`), kept here as the reference the kernel is tested against. Inner classes `MergeQueue`, `MergeTransition`, `Untangler`, `Grab`. |
| `goo_link.gd` | **A link**: `GooLink` (RefCounted) | What the world keeps about one link (its bodies, strength, rest angle, rest-space anchors, the patch sent to the kernel, `attach()`) and its bridge skin (`draw_bridge()`: a `Polygon2D` with a `GooSkin` of its own, its bubble field fitted to the neck's beads, its look following the larger body's, `follow_look()`); the link's geometry as pure statics: the tied patch from anchors and strength (`patch()`), the facing anchors (`facing_anchors()`, `rest_anchor()`), the kernel's knobs (`kernel_params()`, `ease_time()`), the bridge polygon (`bridge_polygon()`: always simple and drawable, or empty). |
| `goo_link_2d.gd` | **A link in the editor**: `GooLink2D` (Node2D, `@tool`) | A child of a `GooWorld2D` naming two `Goo2D` siblings (`body_a`, `body_b`), `strength`, `rest_angle`: linked once both are registered, unlinked when freed, its exports passed on while linked; draws the link and its neck's width in the editor. |
| `goo_statics.gd` | **The scenery**: `GooStatics` (RefCounted) | Mirrors the scene's `StaticBody2D` nodes on `LAYER_WALLS` into a kernel as convex polygons (`shape_points()` of each collision shape), with their friction, bounce and grip, and every `TileMapLayer` with collision on that layer: its cells' polygons merged into few convex pieces (`bake_cells()`, `cell_polygons()`, `convex_pieces()`, `layer_pieces()`; the layer's material and clip in its metadata, `MATERIAL_META` and `CLIP_META`, `tile_material()`, `tile_clip()`); rebuilds the mirror when static bodies, collision nodes or tile layers enter or leave the tree or a layer's cells or `changed` say so, moves shapes whose nodes moved (`sync()`, every step), `refresh()` for changes it cannot see. |
| `goo_tuning.gd` | **The numbers**: `GooTuning` (static) | The length unit `unit` (see "What `unit` scales"); sizes (`min_radius()` … `max_radius()`, `MIN_RADIUS` … `MAX_RADIUS` at unit 1), the log size scale `size_t()`, colour by size, the merge-by-size rule; every size-dependent physical quantity (bead count and radius, masses, spring frequency and damping, pressure, shape matching, internal damping, bounce, friction, wall grip, split thresholds); `tuning(radius)` and `tuning_for(shape)`, the dictionaries a body is built from; the solver's knobs (`SUBSTEPS`, `MAX_SUBSTEPS`, `TOUCH_SLOP`, `WAKE_DEPTH`, `WAKE_SPEED`, `MAX_BEAD_SPEED`, the Untangler's `UNTANGLE_STRENGTH` and `UNTANGLE_SEPARATION_SPEED`; `solver_settings()`, `make_kernel()`); the wall layer (`LAYER_WALLS`). |
| `goo_shape.gd` | **Rest outlines**: `GooShape` (RefCounted value) | A body's shape at rest: round or any simple polygon; its equivalent radius, area, perimeter, corners; the bead loop a ring of it is built on; fusing two outlines into one (`fused()`); fitting an outline onto a deformed ring; cutting a polygon body in rest space along a chord (`cut()`, `cut_ring()`: the pieces decided by the beads they hold, the sliver guard) and trimming it (`trim_ring()`). |
| `goo_loop.gd` | **Loop geometry**: `GooLoop` (static) | Math on closed point loops: signed area and orientation (CCW on screen is negative shoelace area), outward edge normals, Chaikin smoothing (with corners kept), resampling, beads spread over a polygon, centroid, best-fit rotation and goal positions for shape matching, self-intersection, where a loop first crosses itself and the loops it falls into cut there (`split_at_crossings()`), point-in-loop, union outlines; the chord a line through a tip cuts a loop on (`chord()`, `pierces()`). |
| `goo_skin.gd` + `goo.gdshader` | **The look**: `GooSkin` | One `ShaderMaterial` per body and the uniforms it pushes each frame (outline, centre, radius, smoothed velocity, the ring's rotation, bubble field), and a two-tone body's second colour and division (`set_two_tone()`, `clear_two_tone()`, pushed at once), remembered so a shader swap (`shader`, `set_shader()`) re-pushes them at once; the bubble field a split piece or a merged ring inherits, and its field matrix (`set_field_matrix()`, `field_matrix()`: how the body's material has grown and deformed since the field was made, pushed as `bubble_cell`'s scale and `bubble_basis`, the division carried with it; `field_center` for a bridge's origin on the neck), `field_point()` (the shader's map in GDScript); `warm_up(parent, shader)`, which draws a shader once at boot so it compiles then; the default shader: pseudo-3D rim from the distance to the outline, refraction with a motion ripple, fresnel, specular, sheen, two layers of bubbles. Its head documents the uniform contract a replacement shader may use (see "Another skin shader" above). |
| `native/` + `goo2d.gdextension` | **The native kernel**: `GooKernel` (RefCounted, Rust) | The beads and everything that runs every frame, for every ring of a world in one `step()`: the particles (position, previous position, velocity, inverse mass, radius) in flat arrays, a ring a contiguous range of them; the static shapes; the pair passes (the overlap push, as a force and as a displacement over the step, with per-bead pass-through; the Untangler); the solver's substeps (gravity, the step's forces, linear damping and the wall grip; skin and bending distances as XPBD constraints with compliance 1 / stiffness and the springs' damping, shape matching, the hard stretch limit, the links between rings (bead pairs and an angular term, `add_link()`, `set_link_param()`, `remove_link()`, `link_info()`; a ring's links go with it); contacts with the static shapes, swept for fast particles, and between particles through candidate pairs found once a step on a hashed grid; restitution and friction; every velocity capped at `MAX_BEAD_SPEED`); the pressure and internal damping as forces over the step; calm detection and settling by contact groups, the rings touched (from the solver's own contacts), the pinch scan and splat check; the skin outline (a folded ring cut into loops at its crossings; per loop the kink-clamped offset, Chaikin, triangulation check and repair) and the shader's outline. A ring's rest shape and tuning change in place (`set_rest()`, `set_ring_params()`: a resize's ease and a rest deformation, every frame). It holds ids and numbers, never a Godot object; GDScript reads its events and each ring's results. Modules: `kernel.rs` (the rings, the particles, the solver and the step), `statics.rs` (the static shapes), `grid.rs` (the hashed grid), `forces.rs` (the pair passes' forces), `links.rs` (the links: their rest pose, rest lengths and angle as pure functions, with `cargo test` unit tests), `pinch.rs`, `skin.rs`, `geom.rs` (loop math in Godot's float semantics), `consts.rs` (the GDScript constants it mirrors; `constants()` hands them back), `lib.rs` (the class, and static versions of the math on plain arrays for the tests). The crate `goo2d_kernel` (godot-rust 0.5, `api-4-7`) is built into `bin/` by the host project's `tools/build_native.sh` (or downloaded by `tools/install_native.sh`, from what `kernel.yml` builds on every push: linux x86_64, windows x86_64, a macOS universal framework); the `.gdextension` loads it (web entries named for a build not made yet). |
| `plugin.cfg`, `plugin.gd` | Plugin registration | Shows the addon under Project Settings > Plugins. |

Dependencies run downward only: `GooWorld2D` → `Goo2D` → (`GooTuning`, `GooShape`, `GooSkin`,
`GooStatics`) → `GooLoop`. Within the middle group, `GooTuning` and `GooShape` use each other (`tuning_for()`
takes a shape, `cut_ring()` tunes its pieces). Nothing in the addon knows about the demo's arena,
blades, dropper or input.

## Tuning knobs, by what you want to change

Every constant has a `##` doc comment next to it saying what it does and, where it was measured,
what the measurement found. Start from the effect you want:

| I want to … | Change | In |
|---|---|---|
| Change the size range, or what counts as the smallest and largest goo | `MIN_RADIUS`, `MAX_RADIUS` (px at `unit` 1; read through `min_radius()`, `max_radius()`; every size-dependent value lerps over `size_t()`, a log scale between them) | `goo_tuning.gd` |
| Draw the goo at another scale (a game at half resolution, pixel art) | `unit` (a static var, 1.0 by default; 0.5 makes every blob, gap, threshold, speed and gravity half and the motion the same picture at half size; set it before any body or world exists). See "What `unit` scales" below | `goo_tuning.gd` |
| Change the colours | `color(radius)` (hue runs red → blue over `size_t()`): every body left at `Goo2D.COLOR_BY_SIZE`; a body's own `Goo2D.color` (an export; split pieces keep it); a merged body's, `GooWorld2D.merged_color()` (override it); a body in two colours: `Goo2D.second_color` (an export; `set_two_tone()` with its division, `clear_two_tone()`; split pieces keep both), and a world's merges in both parents' colours, `GooWorld2D.two_tone_merges` with `merged_colors()` (override it) | `goo_tuning.gd`; `goo2d.gd`, `goo_world_2d.gd` |
| Tune one world's bodies differently | `GooWorld2D.tuning_for(shape, tags)`: override it in a subclass, call `super()` and change values (stiffness, damping, pressure, shape matching, masses; not `bead_count`, `bead_radius`, `spacing`, `target_area`); every body the world spawns, merges, cuts or has placed under it is built from it, asked with the body's `Goo2D.tags` (tune by the first, `tag()`: an earth body heavier from its first frame; the pieces of a split, a trimmed body and a merged one, tagged `merged_tags()` of the pair, are tuned by theirs) | `goo_world_2d.gd`; `goo2d.gd` for `tags` |
| Make the goo softer or stiffer | `JOINT_FREQUENCY_SMALL` / `_LARGE` (spring frequency per size), `SKIN_FREQUENCY_RATIO`, `BENDING_RATIO` (the kernel's skin and bending constraints have compliance 1 / stiffness, the stiffness `bead_mass × ω²` of these frequencies) | `goo_tuning.gd` |
| Keep some bodies from splitting | `GooWorld2D.may_split()`: override it in a subclass and return false for them; asked before every cut a pinch, a crush, a blade or a tip asks for (not a direct `cut()`), every frame the neck or the tip persists, so keep it cheap | `goo_world_2d.gd` |
| Change one world's gravity | `GooWorld2D.gravity_scale` (1.0; the kernel's gravity is `GooTuning.solver_settings()["gravity"]` × it, re-sent at once when set at run time; settled bodies stay asleep until something wakes them). It scales the solver's pull only: ring pressure stays `GooTuning`'s, tuned for the project's gravity (`physics/2d/default_gravity` changes it for every world) | `goo_world_2d.gd` |
| Make it bouncier or deader | `JOINT_DAMPING_SMALL` / `_LARGE`, `bounce(radius)`, `INTERNAL_DAMP_SMALL` / `_LARGE`, `linear_damp(radius)` | `goo_tuning.gd` |
| Make it rounder or saggier at rest | `PRESSURE_GAIN`, `SHAPE_MATCH_K`, `SHAPE_MATCH_EXPONENT`; `POLYGON_SHAPE_MATCH_RATIO` for shapes | `goo_tuning.gd` |
| Make it heavier or lighter | `particle_mass(radius)`, `MASS_PARTICLES` | `goo_tuning.gd` |
| Change how it grips walls and floors | `BLOB_FRICTION` (Coulomb friction; a contact uses the lower of the bead's and the wall's), `WALL_GRIP_DAMP` (extra linear damping on a bead touching a gripping static shape: what makes goo cling and slide slowly; 0 turns it off); `NO_GRIP_GROUP` for static bodies and tile layers it should not grip; a wall's own friction and bounce are its `physics_material_override`'s (a tile layer's: its TileSet physics layer's material, or its `GooStatics.MATERIAL_META`) | `goo_tuning.gd` |
| Change the ring's resolution | `MIN_BEADS`, `MAX_BEADS` (12 … 22 beads by size), `MAX_POLYGON_BEADS` (44), `BEAD_RADIUS_RATIO`. Fewer beads are cheaper (the solver's work and the skin's points follow the bead count) and more faceted; the split thresholds in bead widths (`GooShape.MIN_PIECE_WIDTH_BEADS`) were measured for 12-22 | `goo_tuning.gd` |
| Trade accuracy for speed in the solver | `SUBSTEPS` (6 per 60 Hz frame; 4 left wobble dying slower and changed which landings split), `MAX_SUBSTEPS` (12: more while a bead would move further than its radius in one), `TOUCH_SLOP` (how close counts as touching), `WAKE_DEPTH` / `WAKE_SPEED` (what wakes a settled body), `MAX_BEAD_SPEED` (3000 px/s: no bead moves faster, in the solver or when set from GDScript; above play, where a throw is at most 1600 and impacts stay under about 2500, below the 4000-8000 a ring born wrong throws its beads at, so it bounds what such a ring hands its neighbours; 0 turns it off) | `goo_tuning.gd` |
| Make splitting easier or harder | `SPLIT_NECK_SMALL` / `_LARGE` (how narrow a pinch), `SPLAT_AREA_SMALL` / `_LARGE` (how crushed an impact), `SPLIT_HOLD`, `SPLAT_HOLD_FRAMES`, `SPLIT_LOCK` | `goo_tuning.gd` |
| Decide what a pinch is | `PINCH_CONSTRICTION`, `PINCH_SCAN_FRAMES`, `CORNER_ANGLE` | `goo2d.gd` |
| Change when it falls asleep | `SETTLE_SPEED`, `SETTLE_TIME`; `GROUP_CHECK_INTERVAL` | `goo_tuning.gd`; `goo2d.gd` |
| Change which bodies merge | `may_merge()`, the one place the world asks: override it in a `GooWorld2D` subclass (any pair, shapes and round bodies alike; keep it cheap, it is asked for every contact); its default, the static `can_merge()` (round by size, shapes flat face to flat face, never a shape with a round body), `MERGE_TOLERANCE`, `FLAT_CONTACT_ANGLE`, `CONTACT_SLACK_BEADS`, `CONTACT_RANGE_BEADS`, `SHAPE_REJUDGE_FRAMES` (how often two shapes that keep touching are judged again) | `goo_world_2d.gd`; `goo_tuning.gd` for `MERGE_TOLERANCE` |
| Change how a merge feels | `MERGE_PULL`, `MergeTransition.DURATION` / `RAMP`, `MERGE_LOCK`; when the swap may happen: `MERGE_FIT`, `MergeTransition.MAX_DURATION` / `RECHECK_FRAMES`; how the merged ring is placed: `Goo2D.MERGE_CLOSE_BEADS`, `MERGE_GROW`; the flash `MERGE_FLASH`, `MERGE_FLASH_BLEND`; the inflate `INFLATE_TIME` (the target area and the rest lengths, `Goo2D.rest_blend`, both ease in over it) | `goo_world_2d.gd`, `goo2d.gd`; `goo_tuning.gd` |
| Change the smallest piece a cut may leave | `MIN_PIECE_RATIO`, `SPLIT_GAP` (round bodies); `GooShape.MIN_PIECE_WIDTH_BEADS` (shapes) | `goo_world_2d.gd`; `goo_shape.gd` |
| Change how sunk-in bodies are pushed apart | Each bead inside another body's bead loop (or within the margin of it) is pushed out through the nearest edge, like a contact, and passes through that body's beads until it is out: `INTRUSION_MARGIN_BEADS` (where the push starts), `INTRUSION_FREQUENCY` (its stiffness; critically damped). Bodies deep inside each other (a centre inside the other, or one swallowed): `UNTANGLE_STRENGTH`, `UNTANGLE_SEPARATION_SPEED` (the kernel's solver settings; `Untangler.STRENGTH` and `SEPARATION_SPEED` name them), `Untangler.RELEASE_MARGIN`, `MIN_OVERLAP_RATIO` | `goo_tuning.gd`; `goo_world_2d.gd` |
| Keep an impact from tearing the skin open | `MAX_STRETCH` (longest a skin edge may get, × its rest length) | `goo2d.gd` |
| Change the look | Shader uniforms: `rim_width`, `rim_strength`, `fresnel_power`, `specular_power`, `refraction_px`, `motion_distortion_px`, `goo_opacity`, `bubble_density`, `bubble_speed`, `bubble_lag`, `bubble_wobble` (each bubble's own sway and pulse, 1; 0 still), `light_dir`, `division_fade` (px over which a two-tone body's colours fade into each other, 10) (per body: the `ShaderMaterial` of its `Skin` child, `body.get_node("Skin").material`; or edit the defaults in the shader). Or replace the shader: `skin_shader` on a body or a world, any `canvas_item` shader using any subset of the skin's uniforms (`point_count`, `points[32]`, `center`, `radius`, `velocity`, `rotation`, `seed`, `bubble_origin`, `bubble_cell`, `bubble_turn`, `bubble_basis`, `second_color`, `division_axis`, `division_offset`; `COLOR` is the tint), see "Another skin shader" | `goo.gdshader`; `Goo2D.skin_shader`, `GooWorld2D.skin_shader` |
| Change how the outline is smoothed | `SKIN_SMOOTHING` (Chaikin passes), `SKIN_KINK_TURN` / `SKIN_KINK_REACH` / `SKIN_KINK_CLEARANCE` (the offset's clamp at concave kinks), `SKIN_MAX_SPLITS` (how many times a folded ring's outline is cut at a crossing before what is left is drawn as it is), `CORNER_ANGLE` / `CORNER_TOLERANCE` (which beads of a rest shape are corners kept sharp), `GooSkin.MAX_POINTS`, `VELOCITY_SMOOTHING` | `goo2d.gd`; `goo_skin.gd` |
| Change how a grab holds a body | `GRAB_STIFFNESS` (the spring, 1/s²: how fast the grab point closes on the point and how far a hanging body sags below it), `GRAB_DAMPING` (1/s; 2 × √stiffness is critical), `GRAB_REACH` (how much of the ring beyond the nearest bead is held, a fraction of the radius: less dangles more and tears more easily), `GRAB_CARRY` (how much of the hold the beads not held follow: less dangles more, tears more easily when dragged fast) | `goo_tuning.gd` |
| Change how a live body resizes or deforms | `RESIZE_TIME` (0.5 s: `resize()`'s default ease), `RESIZE_MAX_LOG_RATE` (1.5 /s of log radius: the fastest growth or shrink; faster growth pushes harder on neighbours and walls), `RESIZE_COUNT_HYSTERESIS` (0.03 of `size_t()` past a bead count's boundary before the ring is rebuilt with the new count), `RESIZE_SETTLE_TIME` (0.5 s before a body held off its size's count re-rings to it), `RESIZE_SPLIT_GUARD` (0.3 s of split lock each frame a size eases or a deformation changes), `DEFORM_SQUASH_MIN` / `_MAX` (0.5 / 2), `DEFORM_AREA_MIN` / `_MAX` (0.6 / 1.6). Every one is a time, a ratio or a fraction of `size_t()`: `unit` leaves them alone | `goo_tuning.gd` |
| Change how links hold and look | `LINK_STIFFNESS`, `LINK_DAMPING` (the pairs' XPBD constraints, per reduced bead mass, 1/s² and 1/s: how far a pulled link stretches), `LINK_BEND_STIFFNESS`, `LINK_BEND_DAMPING` (the angular term at strength 1: how hard a joint keeps its rest angle), `LINK_PATCH_RATIO` (the neck's width at strength 1, × the smaller radius), `LINK_GAP` (the tied beads' gap at rest, in bead radii), `LINK_MIN_REST`, `LINK_THROUGH_BEADS`, `LINK_EASE_TIME` and `LINK_EASE_SPEED` (how a new link draws its bodies together); none but `LINK_EASE_SPEED` is scaled by `unit` (they are frequencies and fractions); the bridge's waist: `GooLink.BRIDGE_WAIST_MIN` / `_MAX`, `BRIDGE_SAMPLES` | `goo_tuning.gd`; `goo_link.gd` |
| Use another layer for the goo's walls | `LAYER_WALLS` (the layer `GooStatics` mirrors) | `goo_tuning.gd` |

### What `unit` scales

`GooTuning.unit` is the goo's length unit, pixels per tuned pixel. Every number in the addon was
tuned in screen pixels at 1.0; at another unit the absolute ones below are multiplied by it, and
everything else is a ratio of a body's radius, a time, a mass, a frequency or a count and is left
alone. Physics similarity then makes a body of half the radius move as the body of the full
radius did, at half the size: with lengths, speeds and accelerations halved and times, masses
and frequencies kept, the equations are the same.

Scaled by `unit` (the values at 1):

| Value | At unit 1 | Read through |
|---|---|---|
| `GooTuning.MIN_RADIUS`, `MAX_RADIUS`: the size range, so `size_t()`, `radius_at()`, `can_merge()`'s cap, `shape_match_k()`'s reference size, and through `size_t()` every size-dependent value | 28, 176 px | `min_radius()`, `max_radius()` |
| Gravity: the project's `physics/2d/default_gravity` (the setting stays as it is), so the solver's pull and `pressure_k()` | 980 px/s² | `gravity()` |
| `SETTLE_SPEED`: a ring under it counts as at rest | 4 px/s | `settle_speed()` |
| `TOUCH_SLOP`, `WAKE_DEPTH`, `WAKE_SPEED`, `MAX_BEAD_SPEED` | 1 px, 0.5 px, 30 px/s, 3000 px/s | `solver_settings()` |
| `UNTANGLE_SEPARATION_SPEED` (the kernel's `untangle_separation_speed`; `consts.rs` keeps the default) | 1600 px/s | `solver_settings()` |
| `GooWorld2D.MERGE_PULL`, `SPLIT_GAP`; the smallest piece a cut leaves, `MIN_PIECE_RATIO` × the smallest size | 1500 px/s², 2 px, 14 px | `merge_pull()`, `split_gap()`, `min_piece_radius()` |
| `Goo2D.MERGE_GROW` | 2 px | `merge_grow()` |
| `GooSkin.MAX_SPEED` (the shader's velocity clamp), `MIN_BUBBLE_CELL` | 4000 px/s, 16 px | (inline) |

They follow a body's radius already, so they scale with it: bead spacing and radius, ring radius,
target area (by `unit`²), `split_neck()`, and every threshold counted in bead radii or as a
fraction of the ring (`INTRUSION_MARGIN_BEADS`, `CONTACT_SLACK_BEADS`, `CONTACT_RANGE_BEADS`,
`MERGE_CLOSE_BEADS`, `Untangler.RELEASE_MARGIN`, `GooShape.MIN_PIECE_WIDTH_BEADS`,
`CUT_DEPTH_BEADS`, `CHORD_ABSTAIN`). `pressure_k()` is the weight spread over the perimeter, both
of which halve, so it is the same number.

Kept, being no length: masses (`particle_mass()`, `MASS_PARTICLES`), the springs' frequencies and
damping ratios, `INTRUSION_FREQUENCY`, the grab's `GRAB_STIFFNESS` and `GRAB_DAMPING` (per px of
error, 1/s² and 1/s), `GRAB_REACH` (a fraction of the radius) and `GRAB_CARRY`, every damping per second, every time (`SETTLE_TIME`,
`INFLATE_TIME`, `SPLIT_HOLD`, `SPLIT_LOCK`, `MERGE_LOCK`, the merge transition's), every ratio,
`UNTANGLE_STRENGTH` (px/s² per px of overlap is 1/s²: the overlap halves and the push with it).

Left absolute on purpose, tolerances far under a pixel that set no motion: `GooShape.SAME_POINT`
(0.01 px), `FUSED_DETAIL` (0.5 px: Geometry2D rounds an offset's arcs at a sagitta of about 0.75 px
whatever their radius, and this keeps those points), `Goo2D.SKIN_REPAIR_GROW` (0.01 px),
`SKIN_REST_SPEED` (0.01 px/s), the editor preview's line width, and in the kernel `PAIR_PAD` (1 px
added to each particle's reach for its candidate pairs: a broad-phase margin) and `SKIN_STILL`
(0.25 px a bead moves before its skin is rebuilt). Geometry2D (the outlines of merges and cuts)
works at a fixed precision. Not scaled either: the look, `goo.gdshader`'s `rim_width` (16 px),
`refraction_px` (18), `motion_distortion_px` (10), `bubble_speed` (16 px/s) and `division_fade`
(10 px), which a game at another scale sets on its skins' material or its own shader.

The host's numbers follow the functions: the demo's `DropController.drop_min_radius()` /
`drop_max_radius()`, `Hopper`'s inspector range (`_validate_property()`).

**The gate** (`tools/stability.gd -- scale --unit=1` and `--unit=0.5`; every scenario of
`tools/stability.gd` and `tools/bench.gd` takes `--unit=U`, the arena scaled by U in the scene and
every size, distance and speed with it):

| Measured (2026-10-17, this machine's kernel build) | Unit 1 | Unit 0.5 | Wanted |
|---|---|---|---|
| Smallest blob's rebound: 28 px from 500 px (unit 1), 14 px from 250 px (0.5) | 16.92 px | 8.46 px (0.500 ×) | half, within 10% |
| Rebound of a 40 and a 90 px blob (unit-1 sizes) | 26.37, 10.12 px | 13.18, 5.06 px | half |
| First touch of the floor to settled, blobs of 28, 40, 90 px (unit-1 sizes) | 2.57, 2.72, 3.02 s | 2.57, 2.72, 3.02 s | the same, within 10% |
| Launch-size blobs let go above the wedge's apex (28, 36, 48 px round and square) | the 48 round and the three squares split; the 28 and 36 round roll off | the same | the wedge still splits |
| Thrown onto the apex from the launch point at 370 px/s (the trace's first launch) | 48 splits; 28, 36 roll off | the same | |
| `passthrough` (18 cases), `inside` (5), `skin`, `impale` (189), `impale_pile` (4) | 0 beads inside at the end, every pair apart within 0.07 s, none settled overlapping, 0 skins undrawable or wrong, 0 impaled or stuck (65 splits) | the same (64 splits) | as at 1 |
| `births` alone, seeds 1-4: births gone wrong / bodies tangled / explosions / merges | 0, 4, 15, 3 / 2, 8, 17, 3 / 1, 2, 2, 0 / 135, 114, 202, 149 | 3, 8, 4, 2 / 12, 5, 3, 0 / 0, 0, 0, 1 / 154, 129, 103, 109 | as at 1 |
| `bench.gd` pile40, mixed40 (seed 20261014): pair-samples inside each other | 17, 29 | 13, 24 | as at 1 |

A lone body's motion at 0.5 is unit 1's halved to the last digit (halving is exact in binary
floating point, and nothing left unscaled enters it): the rebound, settling and wedge rows are
the same game. Two bodies or more diverge from their first contact (the kernel's broad phase pads
each particle's reach by an absolute `PAIR_PAD`, which changes its grid and the order contacts
are solved in), and the random game is chaotic, so those rows compare counts over seeds rather
than frames: births gone wrong total 22 at unit 1 and 17 at 0.5 over the four seeds.

## How it works, briefly

A `Goo2D` is a hollow ring of small circles, beads: particles of the native `GooKernel` (its
world's; lone bodies share one). Once per physics frame the kernel steps every ring together.
First the pair passes push apart bodies that sank into each other and untangle rings threaded
through each other. Then come the forces of the step, from where it starts: a pressure force
along each edge's outward normal proportional to how far the area inside the beads' outline is
from its target, and damping of each bead's motion relative to the ring's mean. Then
`GooTuning.SUBSTEPS` substeps of a position-based (XPBD) solver: each predicts every bead's
motion (gravity, those forces, linear damping), keeps each bead its rest distance from its two
neighbours (the skin) and from the bead after next (bending), as compliant constraints of the
springs' stiffness and damping, pulls the ring toward its rest outline moved rigidly onto it
(shape matching, best-fit rotation), never lets a skin edge stretch past `Goo2D.MAX_STRETCH`,
holds every link (its bead pairs toward their rest lengths, then the two rings' relative
rotation toward the link's, each ring turned rigidly about its centroid by its share; see
"Linking" above, and `native/src/links.rs`), and resolves the contacts: with the static shapes (`GooStatics`; a bead fast enough to cross a thin
wall in one substep is checked along its way) and with every other bead closer than their two
radii (beads 1 or 2 apart along one ring excepted), with the walls' and the goo's friction and
bounce, and caps every bead's speed at `GooTuning.MAX_BEAD_SPEED`. Last, per ring: the rings it touched (`touched`), calm detection and settling, the pinch
scan and splat check (`pinched`), and the skin outline. The world turns the kernel's events into
signals in its `_physics_process`, where the step runs, after code that awaited
`SceneTree.physics_frame` (a lone body's kernel steps at that signal).

The `Skin` child is a `Polygon2D` of the smoothed outline (`Goo2D.skin_pieces()`: the beads
pushed out one bead radius, the push shortened at sharp concave kinks so the points do not
cross, then Chaikin-smoothed), drawn by the goo shader. `Polygon2D` silently draws nothing for a
polygon that crosses itself, so each skin is checked first. A ring folded through itself (its
bead loop crosses itself; a small ring crushed in a pile can stay that way for seconds) is cut
at its crossings into loops that do not, each turned the right way round and given a skin of
its own, drawn as the `Skin`'s sub-polygons (`Polygon2D.polygons`), so the whole body shows,
the folded lobe included. An outline that still cannot be drawn (edges touching without
crossing) is repaired into the simple boundary of what it covers, and if even that failed the
previous polygon would stay. A skin is rebuilt only once a bead moved a quarter of a pixel
from where it was last built. A settled body (its beads at rest, left alone by the solver until
something presses into it) draws its skin until the skin's smoothed velocity has died away and
then leaves it alone until it wakes (`skin_at_rest()`), so a resting pile costs little.

The rest outline is a `GooShape`: a circle for a round body, or a polygon whose bead loop is the
outline inset by one bead radius with a bead on every corner. `GooTuning.tuning_for(shape)` turns
a shape into the dictionary the ring is built from.

`GooWorld2D` listens to its bodies. When two touch and `may_merge()` agrees (by default
`can_merge()`), it starts a
`MergeTransition` (pull together, tint toward the merged colour, frictionless), then, after
`MergeTransition.DURATION` and once the pair is compact (their outlines make one, and the loop
the merged ring would be placed on is at most `MERGE_FIT` times as long around as its rest loop,
`merge_fit()`; checked every `RECHECK_FRAMES`), swaps the pair for one ring rebuilt around both
outlines, keeping their beads' velocities and inflating toward the merged area. A pair still not
compact after `MAX_DURATION` is let go (and merge-locked) rather than forced. The merged ring is
placed on the pair's union with its creases filled (`Goo2D.merge_placement()`,
`MERGE_CLOSE_BEADS`), so no bead sits across a waist from another, and its skin and bending rest
lengths start as those of that loop and ease into its rest shape's over `inflate_time`
(`Goo2D.rest_blend`, the kernel's `rest_blend` ring parameter) as its `target_area` does: a ring
born longer around than its circle, or shaped otherwise (a fused shape), no longer snaps in one
step. When a body reports a pinch or a crush, or `cut_along()` is called, the
world cuts its bead loop along the chord into two rings (`cut()`), round pieces sharing the area
by the loop areas on either side, polygon pieces cut in rest space by `GooShape.cut_ring()`: the
rest outline fitted onto the beads is cut along the chord between the two beads' fitted rest
points, run on to the outline (`GooShape.cut()`; only the chord cuts, not the whole line through
it, so on a concave shape such as a fused pair or a U the other arms stay whole), and each side's
beads get the piece that holds their own fitted rest points. A cut whose chord leaves the outline,
whose sides' beads land in the same piece, or whose piece's bead loop and rest loop differ in area
by over `MAX_PIECE_AREA_MISMATCH` (2.5×) is not made: a ring built with another piece's rest shape
blows up or collapses within a frame. A
body with a tip inside its bead loop (`cut_along()` or `pierce()` with the point inside) is never
left on it: the cut ignores the split lock, wakes a settled body, and if it would leave a piece
too small or too thin, the body is trimmed instead: rebuilt on the larger side alone with its
whole area (`GooShape.trim_ring()` for a polygon), so the tip ends up outside the new ring.
A piece, or a trimmed body, is built on the loop cut from its parent's beads, a bead radius of
them back from the chord (`Goo2D.cut_piece()`, `Goo2D.build_from_loop()`), which can be well
inside its rest loop (a small tip's starts at about half its area); so it starts as a merged
ring does: its `target_area` at that loop's area and its skin and bending rest lengths those of
that loop (`rest_blend` 0), both eased into its rest shape's over `inflate_time`; and beads
across a piece cut thin (a round ring's cap) are first spread a bead diameter apart
(`Goo2D.spread_apart()`), or the self-collision would throw them apart in its first step.

## Signals

- `Goo2D.touched(other: Goo2D)`: a bead of this body touches (within `GooTuning.TOUCH_SLOP`)
  a bead of `other`. It fires once per physics frame and other body for as long as they touch
  (not only when they begin), from the kernel's step (in the world's `_physics_process`), so it
  is outside the physics flush: a handler may add or free physics nodes, and both bodies'
  positions are this frame's. Silent while the body is settled (the other body, if awake, still
  reports the pair), or while either body is merging or being freed. The contacts are the
  solver's own; wall grip (`WALL_GRIP_DAMP`, `bead_gripping()`) comes from the same contacts.
- `Goo2D.pinched(a: int, b: int)`: the body should be split along the chord from bead `a` to
  bead `b` (outside the flush).
- `GooWorld2D.merged(radius, position)` (at least `MergeTransition.DURATION` after the pair
  began merging, later while the pair is not compact; a pair that never gets compact within
  `MergeTransition.MAX_DURATION` does not merge), `split(radius_a, radius_b, position)`,
  `trimmed(radius, position)` (a body with a tip inside it was rebuilt off the tip instead of
  split, the cut would have left a crumb; the body count is unchanged), `count_changed(count)`
  (also after a trim, with the same count, and after `despawn()` and `clear()`).
- `GooWorld2D.body_split(parent_id: int, pieces: Array[Goo2D])`, `bodies_merged(ids:
  PackedInt32Array, body: Goo2D)`, `body_trimmed(old_id: int, body: Goo2D)`: which bodies
  became which, by `Goo2D.id`: the id the split body had and its two pieces, the merged pair's
  two ids and the body made of them, the trimmed body's old id and the body rebuilt off the tip.
  They are for following a body's identity through the world's rules: whatever a game keeps
  per body (a running score, a kind) and must survive a split, a merge or a trim. Each fires
  where its old signal does, right after `count_changed` and before `split`, `merged` or
  `trimmed` (whose shape is unchanged), so a handler of the old signal already finds the game's
  books updated; outside the physics flush. The new bodies are registered (in `bodies()`, with
  their ids); the old ones are out of the tree and the kernel (not in `bodies()`), their `id`
  still readable until they are freed at the end of the frame.
- `GooWorld2D.body_spawned(body: Goo2D)`: every body the world registers, whichever way it
  came: a `spawn()`, each piece of a split, the body a merge made, the body a trim rebuilt, a
  `Goo2D` placed under the world (registered at the end of the frame it entered). For a game
  that does something to every body it gets (a spin, a look, a kind's book-keeping). When it
  fires the body is in the tree, built, tuned (`tuning_for()`), tagged, coloured (a split
  piece already in its parent's look) and registered (its id, in `bodies()`), and nothing else
  about it has been emitted: it comes before the `count_changed` of its registration and
  before `body_split`, `bodies_merged` or `body_trimmed`. Outside the physics flush.

- `Goo2D.resized(old_radius, new_radius)`: `resize()` changed `radius` (the body eases into it).
- `Goo2D.rebuilt(old_points: PackedVector2Array)`: a resize rebuilt the ring in place with another
  bead count, its beads resampled from `old_points` (the bead loop just before, of the old count):
  the same node, `id`, kernel key, tags, colours, skin and children, new bead indices. The kernel
  forgets the ring's pair exclusions (`set_pass_through()`) as for a ring that leaves it.
- `GooWorld2D.body_rebuilt(body: Goo2D)`: after one of the world's bodies emitted `rebuilt` and
  the world re-attached its own grabs to it (at the point they held, under the same handle).
  Whatever holds the body by bead index or by its kernel ring re-attaches here, by a point or by a
  rest-space anchor (`Goo2D.rest_shape`, turned by `ring_rotation()` about `center()`, maps one
  onto the beads). Outside the physics flush.
- `GooWorld2D.bodies_linked(handle: int, a: Goo2D, b: Goo2D)`: `link()` joined `a` and `b`.
  `bodies_unlinked(handle: int, a_id: int, b_id: int)`: the link was released, by `unlink()` or
  by either body leaving the world (a split, a cut, a trim, a merge, `despawn()`, `clear()`;
  emitted as the body goes, before the signals saying what became of it), with the bodies'
  `Goo2D.id`s.

## Limits

- Resizing is rate-limited (`RESIZE_MAX_LOG_RATE`): the rest lengths and target area lead and
  the beads follow, and a ring told to be much bigger at once would push on its neighbours and
  walls as hard as its constraints can. A body growing into a gap narrower than its new size
  stays stable (tested: grown to 200 px across between walls 120 px apart, the fastest bead under
  520 px/s) but grows where it can (up the gap) and stays under its target area. While a size
  eases or a deformation changes, the goo does not split the body by a pinch or a crush
  (`RESIZE_SPLIT_GUARD`); blades, tips and `cut()` still cut it, and its pieces are sized from
  the new `radius`, inflating into it. A re-ring makes the kernel forget the ring's pair
  exclusions (`set_pass_through()`) and its beads' per-bead pass-through; the world's merge
  partners are sent again every frame. At `squash` 0.5 the edges across the axis are twice their
  rest length and the beads leave gaps of 0.4 spacing between them: a small neighbour's bead can
  slip in more easily.

- The goo collides only with itself and with `StaticBody2D` and `TileMapLayer` geometry on
  `LAYER_WALLS`: rigid or character bodies of the physics engine pass through it, and it does not
  push them. Bodies of different kernels (a world's and lone ones, or two worlds) do not collide
  with each other.
- A `TileMapLayer`'s walls are read off its TileSet's polygons per physics layer, so tiles of one
  layer share one material (the physics layer's, or the layer's `MATERIAL_META`): no per-tile
  friction. A tile's custom data, its `texture_origin` and a layer's scene tiles are not looked at.
- A smallest blob rebounds about 15-20 px from a 500 px drop: the solver's contacts are position
  constraints and the ring rebounds on its pressure (when the beads were Rapier bodies, whose
  bounce was solved together with their joints, it rebounded about 40).
- The kernel's library is per platform: linux x86_64 and arm64, windows x86_64 and macOS build
  with `build_native.sh` (releases ship linux x86_64, windows x86_64 and macOS universal); no
  web, Android or iOS build yet.
- Beads are built at runtime and never saved into a scene; a `Goo2D` in a `.tscn` holds only its
  exports. In the editor a placed `Goo2D` shows its rest outline, not the goo:
  the squash, the skin and the bubbles appear when the game runs.
- The goo shader reads the screen texture once per frame; bodies do not refract each other.
- The bubble field follows a body's material by an affine map (measured while its rest outline
  changes): what an affine map cannot follow stays (a squash pulsed fast wobbles the outline
  unevenly, a fast shrink buckles it a little; a few px), and once the outline has been still
  for `FIELD_SETTLE_TIME` the field is kept as it is, so a body's later jiggling (a bounce)
  slides under its bubbles as it always did. A merged or cut body's field follows its inflate,
  then stays as it ends. A bridge's field is fitted to the neck's beads: a bent joint shears
  the neck unevenly, and a neck between a body that grows and one that does not grows evenly in
  the field. `assets/goo/cel.gdshader` draws no bubbles; its division follows like the others'.
- A trim moves the crumb's area to the rest of the body at once: the crumb's side of the body
  vanishes and the rest inflates back to the whole area over `inflate_time`. Only a tip inside a
  body trims it; a pinch, a crush or a direct `cut()` that would leave a crumb is refused (the
  ring asks again later), as is a cut of a loop that crosses itself or of a merging body.
- Links: a link is released, never carried over, when either body splits, is cut, trimmed or
  merged (a game that wants a creature to keep its parts keeps them whole with `may_split()`
  and links the new bodies itself on `body_split`). The bridge skin is a polygon of its own
  drawn under the two skins, with a goo skin whose outline is the bridge: each body's rim still
  shows where it meets the neck, so a pair reads as two drops joined by a neck, not one
  metaball. A link's rest pose has the patches facing; anchors far round a body (or a strength
  near 1 on very unequal bodies) make a joint that starts under strain and eases into it.
- The world knows only the tips it is told about: a blade-like `StaticBody2D` must be fed to
  `cut_at_tips()`, `cut_along()` or `pierce()` every frame (the demo's `Game` does it for its
  blades and wedge).

## Tests

The addon's tests live in the host project's `tests/` (they need its headless runner,
`tests/framework/`). `python3 tools/check.py` runs them.

- `tests/unit/`: one file per addon script, `test_goo_loop.gd`, `test_goo_shape.gd`,
  `test_goo_skin.gd`, `test_goo_tuning.gd`, `test_goo_world_2d.gd` (the pure functions and the
  inner classes), `test_goo2d_skin.gd` (the skin polygons `Goo2D` builds from its beads, a folded ring's included),
  `test_goo2d_two_tone.gd` (a body's two-tone state as values: `division_in_rest()`,
  `dominant_color()`, `color_set()`) and
  `test_goo2d_pinch.gd` (the neck scan and hull depths against their plain all-pairs versions),
  `test_goo_kernel.gd` (the native `GooKernel`: its static math against the GDScript reference
  functions on random loops, the constants it mirrors, a ring joining and leaving its kernel,
  and its solver on rings added straight to a kernel: gravity, a static floor and the grip, the
  stretch limit, swept contacts, the speed cap, pass-through, sleeping, static shapes; links:
  their pairs held at their rest lengths, removed with a ring, their tied beads passing through,
  a rest angle turning the second ring its way), `test_goo_link.gd` (`GooLink`'s patch by
  strength and the bridge polygon: always drawable, touching both outlines, a waist, wider for a
  stronger link). The kernel's `links.rs` has Rust unit tests too (`cargo test --lib` in
  `native/`; `check.py` does not run them).
- `tests/integration/test_goo_links.gd`: links on real bodies (a pair pulled apart comes back, a
  chain of ten whipped about for ten seconds at unit 1 and 0.5, every round and polygon pairing,
  a weak link stretching more, bodies linked apart drawn together, a swept rest angle, never
  merging, released by a despawn, a cut, a merge and `clear()`, a chain hung from a grab, the
  `GooLink2D` fixture `goo_editor_links.tscn`, the bridge).
- The host project's `tools/stability.gd` plays the known failure cases headless and counts
  them (pass-through, bodies spawned inside each other, skins, impalement, `births`: a
  seeded random game watched after every step for explosions, tangled rings and bodies born
  wrong by a split or a merge, and `links`: a seeded random game of linking, unlinking and
  throwing).
- `tests/integration/test_goo2d.gd`: one body at a time (building, resting and sleeping,
  wobble, squeezing through gaps, self-collision, rebuilding, the 40-drop benchmark);
  `test_goo_editor_nodes.gd`: `Goo2D` nodes placed under a `GooWorld2D` in a `.tscn`
  (`tests/integration/scenes/`), with nothing but a `StaticBody2D` floor.
- `tests/integration/test_goo_hooks.gd`: what a subclass and a game build on: a `may_merge()`
  by colour and its `merged_color()`, a body's `color` through a split, `despawn()`,
  `cut_at_tips()`, a body's `tags` (a copy from `spawn()`, copies for split pieces and a trimmed
  body, `merged_tags()`'s deduped union and a world that merges earth and water into mud), a
  `tuning_for()` that stiffens a world's bodies (spawned, cut, merged, placed) and makes a
  landing square squash less, one that tunes by the first tag (spawned, cut, trimmed, merged,
  placed with none), the identity signals (`body_split`, `bodies_merged`, `body_trimmed`: the
  old ids and the new bodies, emitted before the old signals, what a handler sees of the old
  bodies), `body_spawned` for each way a body comes (spawned, a split's pieces, merged, trimmed,
  placed: built, tuned and in the tree, before the other signals), a `may_split()` that keeps bodies whole on a blade, a tip and the wedge (all of
  them, or only the blue ones; a direct `cut()` still cuts), and `gravity_scale` (half gravity
  halves a free fall; set before the kernel is made or at run time; at 0 a body hangs).
- `tests/integration/test_goo_grab.gd`: the grab: `body_at()` under and beside a body, a grab
  point following a dragged point within a bead radius and the body dangling below it, a held
  body never settling, a throw and a plain release, a cut, a merge, `despawn()` and `clear()`
  releasing grabs, several grabs at once (two on one body stretching it), a stranger refused.
- `tests/integration/test_goo_resize.gd`: `resize()` and `set_rest_deform()` on a floor of its own
  and in zero gravity: a resize within one bead count reaching its area, one across counts
  re-ringing in place (node, id, tags, colour, children, `body_rebuilt`), the velocity kept across
  a re-ring, a sweep from the smallest size to the largest and back for a round body, a square and
  a triangle (resting, floating, and at unit 0.5; every frame finite, near its eased target area,
  drawable, no split or merge; at the end as a body spawned at that size), a new target every
  frame, a grabbed body (by its rim and by its centre), a settled body waking, a growing body
  lifting the one on it, one growing in a narrow gap, shrinking to the smallest size without a
  split, a square staying a square and cutting and merging as polygons, merging by the new
  radius, a merging body resized, a piece still inflating resized without a jump, a squash, an
  area pulse, a squash oscillated at 2 Hz for 5 s, a squash during a resize, `ring_rotation()`
  continuous through re-rings and squashes, sizes clamped.
- `tests/integration/test_two_tone_merge.gd`: `two_tone_merges`: `merged_colors()`' rules, a red
  and a blue body merging into a red|blue body (the axis from red's side to blue's, the bigger
  owning more, two-tone already when `body_spawned` is heard), the flash over both colours, the
  parents' tints during the pull, and with the switch off `merged_color()` ruling.
- `tests/integration/test_merge.gd`, `test_split.gd`, `test_shapes.gd`, `test_shape_merge.gd`,
  `test_shape_split.gd`, `test_overlap.gd`, `test_blob_skin.gd`: the rules and the look,
  played out in the demo's arena (they use its floor, walls and wedge as the scenery).
