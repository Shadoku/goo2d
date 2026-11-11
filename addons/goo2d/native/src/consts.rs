//! The constants the per-frame code uses. Their source of truth is the GDScript side
//! (named in each comment); `GooKernel.constants()` hands them back so
//! `tests/unit/test_goo_kernel.gd` can check that the two agree.

/// `Goo2D.MAX_PRESSURE_RATIO`
pub const MAX_PRESSURE_RATIO: f64 = 4.0;
/// `Goo2D.MIN_AREA_RATIO`
pub const MIN_AREA_RATIO: f64 = 0.01;
/// `Goo2D.SKIN_SMOOTHING`
pub const SKIN_SMOOTHING: usize = 2;
/// `Goo2D.SKIN_KINK_TURN`
pub const SKIN_KINK_TURN: f64 = 0.2;
/// `Goo2D.SKIN_KINK_REACH`
pub const SKIN_KINK_REACH: i64 = 4;
/// `Goo2D.SKIN_KINK_CLEARANCE`
pub const SKIN_KINK_CLEARANCE: f64 = 0.75;
/// `Goo2D.SKIN_REPAIR_GROW`
pub const SKIN_REPAIR_GROW: f32 = 0.01;
/// `Goo2D.SKIN_MAX_SPLITS`
pub const SKIN_MAX_SPLITS: usize = 8;
/// `Goo2D.GROUP_CHECK_INTERVAL`
pub const GROUP_CHECK_INTERVAL: f64 = 0.25;
/// `Goo2D.MAX_STRETCH`
pub const MAX_STRETCH: f64 = 1.3;
/// `Goo2D.PINCH_SCAN_FRAMES`
pub const PINCH_SCAN_FRAMES: i64 = 2;
/// `Goo2D.PINCH_CONSTRICTION`
pub const PINCH_CONSTRICTION: f64 = 0.3;
/// `GooTuning.SPLIT_HOLD`
pub const SPLIT_HOLD: f64 = 0.08;
/// `GooTuning.SPLAT_HOLD_FRAMES`
pub const SPLAT_HOLD_FRAMES: i64 = 2;
/// `GooTuning.SPLIT_LOCK`
pub const SPLIT_LOCK: f64 = 0.5;
/// `GooWorld2D.INTRUSION_MARGIN_BEADS`
pub const INTRUSION_MARGIN_BEADS: f64 = 0.5;
/// `GooWorld2D.INTRUSION_FREQUENCY`
pub const INTRUSION_FREQUENCY: f64 = 60.0;
/// `GooWorld2D.Untangler.STRENGTH`: the default of the solver's `untangle_strength`
/// (`GooKernel.set_solver()`), and what the static `untangle_push` uses.
pub const UNTANGLE_STRENGTH: f64 = 400.0;
/// `GooWorld2D.Untangler.SEPARATION_SPEED`: the default of the solver's
/// `untangle_separation_speed` (`GooTuning.solver_settings()` scales it by
/// `GooTuning.unit`), and what the static `untangle_push` uses.
pub const UNTANGLE_SEPARATION_SPEED: f64 = 1600.0;
/// `GooWorld2D.Untangler.RELEASE_MARGIN`
pub const UNTANGLE_RELEASE_MARGIN: f64 = 0.5;
/// `GooWorld2D.Untangler.MIN_OVERLAP_RATIO`
pub const UNTANGLE_MIN_OVERLAP_RATIO: f64 = 0.2;
/// `GooSkin.MAX_POINTS`
pub const SHADER_POINTS: usize = 32;
