@tool
extends EditorPlugin
## Registers the Goo2D addon under Project Settings > Plugins. The node types
## need no registration (their class_name does that). The goo no longer depends
## on the project's 2D physics engine (its native kernel moves the beads; see
## README.md, "Requirements"), so the plugin has nothing to check.
