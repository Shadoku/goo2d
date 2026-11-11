//! Links between two rings (`GooWorld2D.link()`): the constraint set the kernel solves
//! every substep, and its geometry as pure functions.
//!
//! A link ties a patch of beads on ring A to a patch on ring B, pair by pair, with
//! compliant XPBD distance constraints, and holds a rest angle between the two rings'
//! frames (each ring's best-fit rotation from its rest shape, the one shape matching
//! pulls toward). Both come from one "ideal pose": B's rest shape placed against A's,
//! the two patches facing each other across `gap` px (A's patch's outward normal
//! against B's), then turned by the link's `rest_angle` about the neck's centre. Each
//! pair's rest length is its length in that pose, so a turned rest angle makes the
//! pairs on one side of the neck shorter and those on the other longer, and the
//! angular term pulls the rings' relative rotation toward the pose's: the two agree,
//! so a wide neck and a thread bend alike. Changing `rest_angle` moves both targets at
//! once and is smooth when done every frame (what a game's joint actuator does).
//!
//! The angular term is an XPBD constraint on the relative angle φ = θ_b − θ_a: its
//! correction turns each ring rigidly about its centroid by its share (inverse moment
//! of inertia), which shape matching keeps. Stiffness and damping are per reduced mass
//! (1/s², 1/s, like the grab's), so they read the same at any size.
//!
//! A new link eases from the pose the rings are in to its ideal one over `ease_time`
//! (smoothstep), so bodies linked apart are drawn together rather than snapped.

use crate::geom::*;
use godot::builtin::Vector2;

/// A link's knobs (`GooKernel.add_link()`'s `params`, `set_link_param()`).
#[derive(Clone, Copy, Debug)]
pub struct LinkParams {
    /// Px between the two patches' bead centres in the ideal pose.
    pub gap: f32,
    /// The pairs' stiffness and damping per reduced bead mass (1/s², 1/s).
    pub stiffness: f32,
    pub damping: f32,
    /// The angular term's per reduced moment of inertia (1/s², 1/s); 0: none.
    pub bend_stiffness: f32,
    pub bend_damping: f32,
    /// Radians the ideal pose's B is turned about the neck's centre.
    pub rest_angle: f32,
    /// Seconds a new link takes to ease into its ideal pose.
    pub ease_time: f32,
    /// The shortest a pair's rest length may get (a turned rest angle closes one side).
    pub min_rest: f32,
}

impl Default for LinkParams {
    fn default() -> Self {
        LinkParams {
            gap: 0.0,
            stiffness: 0.0,
            damping: 0.0,
            bend_stiffness: 0.0,
            bend_damping: 0.0,
            rest_angle: 0.0,
            ease_time: 0.0,
            min_rest: 0.0,
        }
    }
}

/// The ideal pose of a link in A's rest frame: the tied beads of A (`a`) and of B
/// (`b`, B's rest shape turned by `psi` and moved against A's patch), and the neck's
/// centre.
#[derive(Clone, Debug, Default)]
pub struct Pose {
    pub a: Vec<Vector2>,
    pub b: Vec<Vector2>,
    pub neck: Vector2,
    /// B's rotation in the pose (its best-fit rotation from its rest shape when A is
    /// at its rest pose): the rings' relative angle at rest_angle 0.
    pub psi: f32,
}

pub struct Link {
    pub id: i64,
    pub ka: i64,
    pub kb: i64,
    /// (bead of A, bead of B) per pair.
    pub pairs: Vec<(usize, usize)>,
    /// Beads of A and of B that do not collide with each other (the tied ones and
    /// their close neighbours): bead i of A and bead j of B pass through each other
    /// when i is in `through_a` and j in `through_b`.
    pub through_a: Vec<usize>,
    pub through_b: Vec<usize>,
    pub pose: Pose,
    pub p: LinkParams,
    /// The pairs' rest lengths at `p.rest_angle` (goal_lengths()).
    pub goal: Vec<f32>,
    /// The pairs' lengths and the relative angle when the link was made.
    pub start: Vec<f32>,
    pub start_angle: f32,
    /// 0 when made, 1 once eased into the ideal pose.
    pub ease: f32,
    /// What the solver holds now: the pairs' rest lengths and the relative angle.
    pub rest: Vec<f32>,
    pub target_angle: f32,
}

impl Link {
    /// The rest lengths and target angle `ease` of the way from the start to the goal.
    pub fn refresh(&mut self) {
        let t = self.ease.clamp(0.0, 1.0);
        let s = t * t * (3.0 - 2.0 * t);
        self.rest.clear();
        for k in 0..self.goal.len() {
            let from = self.start.get(k).copied().unwrap_or(self.goal[k]);
            self.rest.push(from + (self.goal[k] - from) * s);
        }
        let goal_angle = self.pose.psi + self.p.rest_angle;
        self.target_angle = self.start_angle + wrap(goal_angle - self.start_angle) * s;
    }

    /// Recomputes `goal` from the pose and `p.rest_angle` (after it changed).
    pub fn set_goal(&mut self) {
        self.goal = goal_lengths(&self.pose, self.p.rest_angle, self.p.min_rest);
    }
}

/// `x` wrapped into -π..π.
pub fn wrap(x: f32) -> f32 {
    let tau = std::f32::consts::TAU;
    let y = (x + std::f32::consts::PI).rem_euclid(tau);
    y - std::f32::consts::PI
}

/// The outward normal at bead `i` of the closed loop `p` (either winding): the mean of
/// its two edges' outward normals, unit length.
pub fn vertex_normal(p: &[Vector2], i: usize) -> Vector2 {
    let n = p.len();
    if n < 3 {
        return norm(p.get(i).copied().unwrap_or(Vector2::ZERO));
    }
    // (−e.y, e.x) points out of a loop counter-clockwise on screen (signed area < 0).
    let sign = if signed_area(p) < 0.0 { 1.0 } else { -1.0 };
    let edge = |k: usize| {
        let e = p[(k + 1) % n] - p[k];
        norm(Vector2::new(-e.y, e.x)) * sign
    };
    norm(edge((i + n - 1) % n) + edge(i))
}

/// The ideal pose of a link tying beads `pairs` of a ring whose rest shape is `rest_a`
/// to a ring whose rest shape is `rest_b` (both about their centroids), the middle
/// pair's beads `gap` px apart (see the module docs).
pub fn ideal_pose(rest_a: &[Vector2], rest_b: &[Vector2], pairs: &[(usize, usize)], gap: f32) -> Pose {
    if pairs.is_empty() || rest_a.len() < 3 || rest_b.len() < 3 {
        return Pose::default();
    }
    // The middle pair's beads are `gap` apart along the patches' mean normals.
    let (mut na, mut nb) = (Vector2::ZERO, Vector2::ZERO);
    for &(i, j) in pairs {
        na += vertex_normal(rest_a, i % rest_a.len());
        nb += vertex_normal(rest_b, j % rest_b.len());
    }
    let (mid_a, mid_b) = pairs[pairs.len() / 2];
    let pa = rest_a[mid_a % rest_a.len()];
    let pb = rest_b[mid_b % rest_b.len()];
    let na = if len_sq(na) > 1e-12 { norm(na) } else { norm(pa) };
    let nb = if len_sq(nb) > 1e-12 { norm(nb) } else { norm(pb) };
    // B turned so its patch's normal faces A's.
    let psi = wrap((-na.y).atan2(-na.x) - nb.y.atan2(nb.x));
    let cb = pa + na * gap - rotated(pb, psi);
    Pose {
        a: pairs.iter().map(|&(i, _)| rest_a[i % rest_a.len()]).collect(),
        b: pairs.iter().map(|&(_, j)| cb + rotated(rest_b[j % rest_b.len()], psi)).collect(),
        neck: pa + na * (0.5 * gap),
        psi,
    }
}

/// Each pair's length in `pose` with B turned a further `rest_angle` about the neck's
/// centre, at least `min_rest`.
pub fn goal_lengths(pose: &Pose, rest_angle: f32, min_rest: f32) -> Vec<f32> {
    pose.a
        .iter()
        .zip(&pose.b)
        .map(|(&a, &b)| dist(a, pose.neck + rotated(b - pose.neck, rest_angle)).max(min_rest))
        .collect()
}

/// The best-fit rotation of `rest` (about its centroid) onto `pts`, and the centroid of
/// `pts` (shape matching's, solve_ring()).
pub fn frame(rest: &[Vector2], pts: &[Vector2]) -> (f32, Vector2) {
    let c = centroid(pts);
    let (mut cs, mut dt) = (0.0f32, 0.0f32);
    for i in 0..rest.len().min(pts.len()) {
        let (q, p) = (rest[i], pts[i] - c);
        cs += cross(q, p);
        dt += dot(q, p);
    }
    (cs.atan2(dt), c)
}

/// Σ |p − c|² over `pts` (the moment of inertia per unit bead mass about `c`).
pub fn spread(pts: &[Vector2], c: Vector2) -> f32 {
    pts.iter().map(|&p| dist_sq(p, c)).sum()
}

/// Turns `pts` by `angle` about `c`.
pub fn turn(pts: &mut [Vector2], c: Vector2, angle: f32) {
    if angle == 0.0 {
        return;
    }
    let (s, co) = angle.sin_cos();
    for p in pts.iter_mut() {
        let d = *p - c;
        *p = c + Vector2::new(d.x * co - d.y * s, d.x * s + d.y * co);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn circle(n: usize, r: f32) -> Vec<Vector2> {
        (0..n)
            .map(|i| {
                let a = std::f32::consts::TAU * i as f32 / n as f32;
                Vector2::new(a.cos() * r, a.sin() * r)
            })
            .collect()
    }

    #[test]
    fn wrap_stays_in_range() {
        for k in -20..20 {
            let x = k as f32 * 0.7;
            let w = wrap(x);
            assert!(w >= -std::f32::consts::PI - 1e-5 && w <= std::f32::consts::PI + 1e-5);
            assert!(((x - w) / std::f32::consts::TAU - ((x - w) / std::f32::consts::TAU).round()).abs() < 1e-4);
        }
    }

    #[test]
    fn the_ideal_pose_faces_the_patches() {
        let a = circle(16, 40.0);
        let b = circle(12, 30.0);
        // Bead 0 of A points along +x; bead 3 of B along +y.
        let pose = ideal_pose(&a, &b, &[(0, 3)], 10.0);
        assert!((dist(pose.a[0], pose.b[0]) - 10.0).abs() < 1e-3, "the tied beads are the gap apart");
        assert!((pose.b[0].y).abs() < 1e-3 && pose.b[0].x > 40.0, "B's bead sits beyond A's along its normal");
        // B's +y normal turned to face −x: a turn of +90°.
        assert!((pose.psi - std::f32::consts::FRAC_PI_2).abs() < 1e-4, "psi {}", pose.psi);
        assert!(dist(pose.neck, Vector2::new(45.0, 0.0)) < 1e-3);
    }

    #[test]
    fn a_turned_rest_angle_shortens_one_side_and_lengthens_the_other() {
        let a = circle(16, 40.0);
        let b = circle(16, 40.0);
        // Three pairs: A's beads 15, 0, 1 against B's 9, 8, 7 (facing, B's run the other way).
        let pairs = [(15, 9), (0, 8), (1, 7)];
        let pose = ideal_pose(&a, &b, &pairs, 8.0);
        let flat = goal_lengths(&pose, 0.0, 0.0);
        for &l in &flat {
            assert!(l > 7.9, "the facing beads are at least the gap apart: {}", l);
        }
        assert!((flat[0] - flat[2]).abs() < 1e-3, "symmetric at rest angle 0");
        let bent = goal_lengths(&pose, 0.3, 0.0);
        // Bead 1 of A is on the +y side; a positive turn of B about the neck moves its
        // +y side toward A.
        assert!(bent[2] < flat[2] - 1.0, "the +y side shortens: {} -> {}", flat[2], bent[2]);
        assert!(bent[0] > flat[0] + 1.0, "the −y side lengthens: {} -> {}", flat[0], bent[0]);
        let clamped = goal_lengths(&pose, 1.5, 6.0);
        assert!(clamped.iter().all(|&l| l >= 6.0));
    }

    #[test]
    fn frame_measures_a_turn() {
        let rest = circle(12, 30.0);
        let mut pts: Vec<Vector2> = rest.iter().map(|&p| p + Vector2::new(100.0, 50.0)).collect();
        let (angle, c) = frame(&rest, &pts);
        assert!(angle.abs() < 1e-4);
        turn(&mut pts, c, 0.4);
        let (angle, _) = frame(&rest, &pts);
        assert!((angle - 0.4).abs() < 1e-4, "{}", angle);
    }

    #[test]
    fn refresh_eases_from_the_start() {
        let a = circle(16, 40.0);
        let b = circle(16, 40.0);
        let pose = ideal_pose(&a, &b, &[(0, 8)], 8.0);
        let mut link = Link {
            id: 1,
            ka: 1,
            kb: 2,
            pairs: vec![(0, 8)],
            through_a: vec![],
            through_b: vec![],
            pose,
            p: LinkParams { gap: 8.0, ..Default::default() },
            goal: vec![],
            start: vec![50.0],
            start_angle: 0.0,
            ease: 0.0,
            rest: vec![],
            target_angle: 0.0,
        };
        link.set_goal();
        link.refresh();
        assert!((link.rest[0] - 50.0).abs() < 1e-4);
        link.ease = 0.5;
        link.refresh();
        assert!((link.rest[0] - 29.0).abs() < 1e-3, "{}", link.rest[0]);
        link.ease = 1.0;
        link.refresh();
        assert!((link.rest[0] - 8.0).abs() < 1e-3);
        assert!((link.target_angle - link.pose.psi).abs() < 1e-5);
    }
}
