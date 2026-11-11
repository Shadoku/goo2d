# Goo2D

Soft, wet, jiggly 2D goo bodies for Godot 4.7: blobs and polygon shapes that squash, bounce,
settle, merge when they touch, split when they are pinched or cut, and are drawn as
translucent goo. The beads are moved by the addon's own native kernel (a Rust GDExtension).

This repository is the addon's home. The addon is `addons/goo2d/`; everything else is its
demo, examples, tests and tools.

- [`addons/goo2d/README.md`](addons/goo2d/README.md): the addon's map (requirements, quick
  start, where each system lives, tuning knobs, limits).
- [`examples/README.md`](examples/README.md): four small scenes that each show one part of it.
- `scenes/main.tscn`: the demo (launch blobs into an arena with a wedge and two blades).

## Use it in a game

Copy `addons/goo2d/` whole into the game's `addons/`, libraries included (`bin/` holds linux
x86_64, windows x86_64 and macOS), and enable the plugin in Project Settings. Add a
`VENDORED.md` beside it naming this repository's commit. Do not edit the copy: change the
addon here first, then copy it again.

The game needs Godot 4.7. It does not need Rust.

## Develop

```
python3 tools/check.py        # build the kernel, import, validate, tests, smoke, render (Xvfb)
godot --path .                # run the demo
godot --path . --editor       # open the editor
godot --path . examples/tower/tower.tscn
```

Godot is located via `$GODOT`, then `godot` on PATH, then `~/.cache/godot/<version>/godot`.
`bash tools/install_godot.sh` downloads the version pinned in `.godot-version`. With cargo
installed, `check.py` rebuilds this machine's kernel library first; without it, the committed
library is used.

See `CLAUDE.md` for the test-driven workflow, the layout and the conventions.
