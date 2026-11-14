//! The handle-driven pose (`Opt::pose_solve`, off by default; the fluid game's
//! docs/pose-solve-plan.md, milestones 2 and 3): the pose wave positions only a creature's
//! handle cells (its spine), and pose_solve.rs's as-rigid-as-possible solve places every
//! other cell, so wings, fins and spikes keep their shape instead of bending as part of one
//! ribbon. Its outputs are the ribbon's (`bent`, `bent_turn`, the radius muscles, the links'
//! design lengths and angles), so everything downstream is unchanged.
//!
//! Handles (pick_pose_handles()): the creature's cells of a type flagged `pose_handle`, when
//! there are at least two and they span at least a third of its extent along the wave's axis
//! (centres); else an automatic centreline, the cells whose centre lies within their own
//! diameter of the axis through the design centroid; else, when that gives fewer than two
//! stations along the axis, the single-file chain of cells nearest that axis (one per
//! stretch of a mean cell diameter along it, head to tail). Fewer than two handles at
//! distinct stations: none, and the ribbon poses the creature. Picked again whenever its
//! topology version, the types' flags (`Opt::pose_version`), its cell or link count or the
//! wave's axis change. A split's part picks from its own cells about its own design
//! centroid (recentred at the split) along the wave's axis it inherits.
//!
//! The wave over the handles: the ribbon's centreline (64 samples, integrated from the
//! design centroid's station) spans the handles' extent along the axis, and its envelope
//! runs over that extent; the phase stays k·u from the design centroid (the swim drive's
//! pulse reads the same phase). Each handle's target is the ribbon's own mapping: the
//! centreline point at its distance along the axis plus its offset across the axis along
//! the centreline's normal. The curvature clamp is the ribbon's (half the length at the
//! inner side) by the half width of the body attached sideways to the spine, worked out per
//! topology: a cell counts at the station of its nearest handle through the link graph
//! (breadth first, ties to the handle listed first), and only if its offset across the axis
//! from that handle is at least its offset along it; handles count at their own station.
//! A thick body keeps its limit, a fin swept back sets none.
//!
//! The solve: PoseSolver (fixed handles, the rotation seed on), POSE_ITERATIONS local/global
//! iterations a frame, warm-started from the creature's last pose and turns. `bent` is the
//! solved pose, `bent_turn` its turns, a cell's radius muscle the mean of its links' posed
//! over design lengths (strain_scales()) clamped to 0.6..1.5 as the ribbon's.
//!
//! State (PoseState, per creature): the handles and the clamp (per topology), the solver
//! (rebuilt with the handles), the warm start (reset to the design and zero turns when the
//! solver is rebuilt, when the wave starts again or stops, and in a new body: a split's
//! parts and a body that lost a cell start from their design). A merge changes the topology
//! of the creature merged into, so its pose starts again from the merged design. The warm
//! start is in Cells::state_hash() while it runs. No allocation per frame.
//!
//! When the solver cannot be built (fewer than two handles, a cell no link path joins to a
//! handle) or a solve refuses, the ribbon poses the creature that frame (`fallbacks` counts
//! the frames).

use crate::cells::{perp, wrap, Body, Opt};
use crate::geom::dot;
use crate::pose_solve::{PoseError, PoseSolver};
use godot::builtin::Vector2;

/// Local/global iterations a frame (the rotation seed does the bulk of the work).
pub const POSE_ITERATIONS: usize = 3;
/// Samples along the centreline (the ribbon's count).
const G: usize = 64;

/// How a creature's handles were chosen.
pub const HANDLES_NONE: u8 = 0;
pub const HANDLES_TYPED: u8 = 1;
pub const HANDLES_CENTRELINE: u8 = 2;
pub const HANDLES_CHAIN: u8 = 3;

/// What a creature keeps for the handle-driven pose.
#[derive(Clone, Default, Debug)]
pub struct PoseState {
    /// What the handles were picked for: (topology version, Opt::pose_version, the axis's
    /// bits, cells, links); None: never picked.
    pub key: Option<(u32, u32, u32, u32, usize, usize)>,
    pub handles: Vec<u32>,
    pub source: u8,
    pub solver: Option<PoseSolver>,
    /// Why the solver could not be built (None: built, or no handles).
    pub error: Option<PoseError>,
    /// The handles' extent along the axis (centres) and the clamp per sample over it.
    pub umin: f32,
    pub umax: f32,
    pub kmax: Vec<f32>,
    /// The warm start: last frame's solved pose and turns (design frame), valid while warm.
    pub pose: Vec<Vector2>,
    pub turns: Vec<f32>,
    pub warm: bool,
    /// The wave's age at the last solve (a smaller age: the wave started again).
    pub last_age: f32,
    /// Scratch.
    pub targets: Vec<Vector2>,
    pub scales: Vec<f32>,
    /// Frames posed by the ribbon although the option was on, frames solved, handle picks.
    pub fallbacks: u32,
    pub solves: u32,
    pub picks: u32,
}

impl Body {
    /// The design centroid (rest_local by mass).
    fn design_centroid(&self) -> Vector2 {
        let (mut s, mut m) = (Vector2::ZERO, 0.0f32);
        for i in 0..self.n.min(self.rest_local.len()) {
            s += self.rest_local[i] * self.mass[i];
            m += self.mass[i];
        }
        if m > 0.0 {
            s / m
        } else {
            Vector2::ZERO
        }
    }

    /// The handle-driven pose's handles about `axis` (design frame) and how they were chosen
    /// (HANDLES_*); empty with HANDLES_NONE when no rule gives two at distinct stations.
    pub fn pick_pose_handles(&self, opt: &Opt, axis: Vector2) -> (Vec<u32>, u8) {
        let n = self.n;
        if n < 2 || self.rest_local.len() != n {
            return (Vec::new(), HANDLES_NONE);
        }
        let ax = if axis.length_squared() > 1e-12 { axis.normalized() } else { Vector2::new(1.0, 0.0) };
        let across = perp(ax);
        let c = self.design_centroid();
        let vc = dot(c, across);
        let u = |i: usize| dot(self.rest_local[i], ax);
        let v = |i: usize| dot(self.rest_local[i], across);
        let extent = |h: &[u32]| -> f32 {
            let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
            for &i in h {
                lo = lo.min(u(i as usize));
                hi = hi.max(u(i as usize));
            }
            if hi >= lo {
                hi - lo
            } else {
                0.0
            }
        };
        // Two stations: the handles' centres spread along the axis by more than a quarter of
        // their smallest radius.
        let spread = |h: &[u32]| -> bool {
            h.len() >= 2 && extent(h) > 0.25 * h.iter().map(|&i| self.r0[i as usize]).fold(f32::INFINITY, f32::min)
        };
        let all: Vec<u32> = (0..n as u32).collect();
        let whole = extent(&all);
        let typed: Vec<u32> = (0..n as u32).filter(|&i| opt.types[self.typ[i as usize] as usize].pose_handle).collect();
        if spread(&typed) && extent(&typed) >= whole / 3.0 {
            return (typed, HANDLES_TYPED);
        }
        let line: Vec<u32> = (0..n as u32).filter(|&i| (v(i as usize) - vc).abs() <= 2.0 * self.r0[i as usize]).collect();
        if spread(&line) {
            return (line, HANDLES_CENTRELINE);
        }
        // The single-file chain nearest the axis: one cell per stretch of a mean diameter.
        let ulo = (0..n).map(u).fold(f32::INFINITY, f32::min);
        let width = 2.0 * self.r0.iter().sum::<f32>() / n as f32;
        let mut best: Vec<(i64, u32)> = Vec::new();
        for i in 0..n {
            let b = ((u(i) - ulo) / width.max(1e-3)).floor() as i64;
            match best.iter_mut().find(|e| e.0 == b) {
                Some(e) => {
                    if (v(i) - vc).abs() < (v(e.1 as usize) - vc).abs() {
                        e.1 = i as u32;
                    }
                }
                None => best.push((b, i as u32)),
            }
        }
        best.sort_unstable();
        let chain: Vec<u32> = best.iter().map(|e| e.1).collect();
        if spread(&chain) {
            return (chain, HANDLES_CHAIN);
        }
        (Vec::new(), HANDLES_NONE)
    }

    /// The length a wave's wavelength is measured in: with the handle-driven pose on, the
    /// handles' extent along `axis` edge to edge (their centres' plus the end cells' radii);
    /// otherwise, or with no handles, every cell's (the design's length).
    pub fn pose_length(&self, opt: &Opt, axis: Vector2) -> f32 {
        let n = self.n.min(self.rest_local.len());
        if n == 0 {
            return 0.0;
        }
        let ax = if axis.length_squared() > 1e-12 { axis.normalized() } else { Vector2::new(1.0, 0.0) };
        let cells: Vec<u32> = if opt.pose_solve {
            let (h, _) = self.pick_pose_handles(opt, ax);
            if h.len() >= 2 {
                h
            } else {
                (0..n as u32).collect()
            }
        } else {
            (0..n as u32).collect()
        };
        let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
        for &i in &cells {
            let u = dot(self.rest_local[i as usize], ax);
            lo = lo.min(u - self.r0[i as usize]);
            hi = hi.max(u + self.r0[i as usize]);
        }
        (hi - lo).max(0.0)
    }

    /// Picks the handles, works out the clamp and builds the solver when what they depend on
    /// changed (a no-op otherwise).
    fn pose_refresh(&mut self, opt: &Opt, axis: Vector2) {
        let n = self.n;
        let key = (self.topo_version, opt.pose_version, axis.x.to_bits(), axis.y.to_bits(), n, self.links.len());
        if self.pose_st.key == Some(key) {
            return;
        }
        let (handles, source) = self.pick_pose_handles(opt, axis);
        let st = &mut self.pose_st;
        st.key = Some(key);
        st.picks = st.picks.wrapping_add(1);
        st.source = source;
        st.solver = None;
        st.error = None;
        st.warm = false;
        st.handles = handles;
        if st.handles.len() < 2 {
            return;
        }
        let across = perp(axis);
        let u = |p: Vector2| dot(p, axis);
        let (mut umin, mut umax) = (f32::INFINITY, f32::NEG_INFINITY);
        for &h in &st.handles {
            umin = umin.min(u(self.rest_local[h as usize]));
            umax = umax.max(u(self.rest_local[h as usize]));
        }
        st.umin = umin;
        st.umax = umax;
        let span = (umax - umin).max(1e-3);
        let du = span / (G - 1) as f32;
        // Each cell's nearest handle through the links (breadth first from every handle).
        let mut near = vec![u32::MAX; n];
        let mut queue: Vec<u32> = Vec::with_capacity(n);
        for &h in &st.handles {
            near[h as usize] = h;
            queue.push(h);
        }
        let mut head = 0;
        while head < queue.len() {
            let i = queue[head] as usize;
            head += 1;
            for q in self.nb_start[i]..self.nb_start[i + 1] {
                let j = self.nb[q as usize].0 as usize;
                if near[j] == u32::MAX {
                    near[j] = near[i];
                    queue.push(j as u32);
                }
            }
        }
        // The half width attached sideways at each handle's station.
        let mut hw = [1e-3f32; G];
        let mut rmax = 0.0f32;
        for i in 0..n {
            let h = near[i];
            if h == u32::MAX {
                continue;
            }
            let (p, q) = (self.rest_local[i], self.rest_local[h as usize]);
            let side = (dot(p, across) - dot(q, across)).abs();
            let along = (u(p) - u(q)).abs();
            if h as usize != i && side < along {
                continue;
            }
            let g = (((u(q) - umin) / du).round() as usize).min(G - 1);
            hw[g] = hw[g].max(dot(p, across).abs() + self.r0[i]);
            rmax = rmax.max(self.r0[i]);
        }
        let reach = (rmax * 2.0 / du).ceil() as usize;
        st.kmax.clear();
        for g in 0..G {
            let lo = g.saturating_sub(reach);
            let hi = (g + reach).min(G - 1);
            let w = hw[lo..=hi].iter().cloned().fold(1e-3, f32::max);
            st.kmax.push(0.5 / w);
        }
        let links: Vec<(u32, u32)> = self.links.iter().map(|l| (l.i, l.j)).collect();
        let weights = vec![1.0f32; links.len()];
        match PoseSolver::build(&self.rest_local, &links, &weights, &st.handles, axis, self.topo_version as u64) {
            Ok(s) => st.solver = Some(s),
            Err(e) => st.error = Some(e),
        }
        st.pose = self.rest_local.clone();
        st.turns = vec![0.0; n];
        st.targets = vec![Vector2::ZERO; st.handles.len()];
        st.scales = vec![1.0; n];
    }

    /// WAVE_POSE with the handle-driven pose: the handles on the wave's centreline, the rest
    /// solved. False (nothing written): the ribbon poses it this frame.
    pub(crate) fn pose_wave_solved(&mut self, opt: &Opt) -> bool {
        let n = self.n;
        if n == 0 || self.rest_local.len() != n {
            return false;
        }
        let wv = self.wave;
        self.pose_refresh(opt, wv.axis);
        if self.pose_st.solver.is_none() {
            self.pose_st.fallbacks = self.pose_st.fallbacks.wrapping_add(1);
            self.pose_st.warm = false;
            return false;
        }
        let across = perp(wv.axis);
        let st = &mut self.pose_st;
        if !st.warm || wv.age < st.last_age || st.pose.len() != n {
            st.pose.clear();
            st.pose.extend_from_slice(&self.rest_local);
            st.turns.clear();
            st.turns.resize(n, 0.0);
        }
        // The ribbon's centreline over the handles' extent.
        let (umin, umax) = (st.umin, st.umax);
        let span = (umax - umin).max(1e-3);
        let du = span / (G - 1) as f32;
        let ramp = (wv.age / 0.5).min(1.0);
        let mut psi = [0.0f32; G];
        let mut cx = [0.0f32; G];
        let mut cy = [0.0f32; G];
        let mut kap = [0.0f32; G];
        for g in 0..G {
            let u = umin + du * g as f32;
            let tail = (umax - u) / span;
            let env = (1.0 - wv.envelope) + wv.envelope * tail;
            kap[g] = (ramp * (wv.bias + wv.amp * wv.k * env * (wv.k * u + wv.phase).sin())).clamp(-st.kmax[g], st.kmax[g]);
        }
        let g0 = ((-umin / du).round() as isize).clamp(0, G as isize - 1) as usize;
        cx[g0] = umin + du * g0 as f32;
        for g in (g0 + 1)..G {
            psi[g] = psi[g - 1] + 0.5 * (kap[g] + kap[g - 1]) * du;
            let a = 0.5 * (psi[g] + psi[g - 1]);
            cx[g] = cx[g - 1] + a.cos() * du;
            cy[g] = cy[g - 1] + a.sin() * du;
        }
        for g in (0..g0).rev() {
            psi[g] = psi[g + 1] - 0.5 * (kap[g] + kap[g + 1]) * du;
            let a = 0.5 * (psi[g] + psi[g + 1]);
            cx[g] = cx[g + 1] - a.cos() * du;
            cy[g] = cy[g + 1] - a.sin() * du;
        }
        for (k, &h) in st.handles.iter().enumerate() {
            let p = self.rest_local[h as usize];
            let (u, v) = (dot(p, wv.axis), dot(p, across));
            let t = ((u - umin) / du).clamp(0.0, (G - 1) as f32);
            let g = (t.floor() as usize).min(G - 2);
            let f = t - g as f32;
            let ps = psi[g] + (psi[g + 1] - psi[g]) * f;
            let x = cx[g] + (cx[g + 1] - cx[g]) * f;
            let y = cy[g] + (cy[g + 1] - cy[g]) * f;
            let (c, s) = (ps.cos(), ps.sin());
            st.targets[k] = wv.axis * (x - v * s) + across * (y + v * c);
        }
        let PoseState { solver, targets, pose, turns, scales, .. } = st;
        let sv = solver.as_mut().expect("built above");
        if sv.solve(targets, pose, turns, POSE_ITERATIONS).is_err() {
            st.fallbacks = st.fallbacks.wrapping_add(1);
            st.warm = false;
            return false;
        }
        sv.strain_scales(pose, scales);
        st.warm = true;
        st.last_age = wv.age;
        st.solves = st.solves.wrapping_add(1);
        self.bent.clear();
        self.bent.extend_from_slice(&self.pose_st.pose);
        self.bent_turn.clear();
        self.bent_turn.extend_from_slice(&self.pose_st.turns);
        for i in 0..n {
            self.muscle[i] = self.pose_st.scales[i].clamp(0.6, 1.5);
        }
        let bent = &self.bent;
        let turn = &self.bent_turn;
        for l in self.links.iter_mut() {
            let (i, j) = (l.i as usize, l.j as usize);
            let rd = self.rest_local[j] - self.rest_local[i];
            let bd = bent[j] - bent[i];
            let rl = rd.length().max(1e-6);
            l.d_design = l.d_base * bd.length() / rl;
            let dang = wrap(bd.y.atan2(bd.x) - rd.y.atan2(rd.x));
            l.ai_design = l.ai_base + dang - turn[i];
            l.aj_design = l.aj_base + dang - turn[j];
        }
        true
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::cells::tests::crash_world;
    use crate::cells::{worm_design, Cells, Wave, BEND_SHAPE, SELF_FAR, WAVE_OFF, WAVE_POSE};
    use std::f32::consts::TAU;
    use std::time::Instant;

    const DT: f32 = 1.0 / 60.0;
    const R: f32 = 7.0;

    /// GooCellWorld2D's stiffnesses (the kernel tests' game_like()).
    fn game_like() -> Cells {
        let mut cl = Cells::default();
        cl.opt.bend_mode = BEND_SHAPE;
        cl.opt.stretch_hz = 60.0;
        cl.opt.bend_hz = 40.0;
        cl.opt.self_mode = SELF_FAR;
        cl
    }

    fn wave(slope: f32, wavelength: f32, hz: f32, envelope: f32, bias: f32) -> Wave {
        Wave { mode: WAVE_POSE, amp: slope, k: TAU / wavelength, omega: TAU * hz, axis: Vector2::new(1.0, 0.0), half_width: 0.0, bias, envelope, phase: 0.0, age: 0.0 }
    }

    /// A 24 × 5 hex worm of 7 px cells, its middle row of type 1 (flagged when `flag`).
    fn worm(cl: &mut Cells, long: i32, at: Vector2, flag: bool) -> usize {
        let d = worm_design(long, 5, R, at);
        let t: Vec<u8> = d.iter().map(|p| ((p.y - at.y).abs() < 1.0) as u8).collect();
        cl.opt.types[1].pose_handle = flag;
        cl.add_creature(&d, &vec![R; d.len()], &t)
    }

    /// Links from each cell to its nearest handle (breadth first; u32::MAX: none).
    fn hops(b: &Body, handles: &[u32]) -> Vec<u32> {
        let mut d = vec![u32::MAX; b.n];
        let mut q: Vec<usize> = Vec::new();
        for &h in handles {
            d[h as usize] = 0;
            q.push(h as usize);
        }
        let mut head = 0;
        while head < q.len() {
            let i = q[head];
            head += 1;
            for k in b.nb_start[i]..b.nb_start[i + 1] {
                let j = b.nb[k as usize].0 as usize;
                if d[j] == u32::MAX {
                    d[j] = d[i] + 1;
                    q.push(j);
                }
            }
        }
        d
    }

    fn goal_strain(b: &Body, i: usize, j: usize) -> f32 {
        (b.bent[j] - b.bent[i]).length() / (b.rest_local[j] - b.rest_local[i]).length().max(1e-6) - 1.0
    }

    fn live_strain(b: &Body, i: usize, j: usize, d0: f32) -> f32 {
        (b.pos[j] - b.pos[i]).length() / d0.max(1e-6) - 1.0
    }

    /// The option off: the types' flags change nothing, and the step is the ribbon's.
    #[test]
    fn the_option_off_is_the_ribbon() {
        let run = |flag: bool, solve: bool| {
            let mut cl = crash_world(1);
            for b in cl.bodies.iter_mut() {
                b.wave = Wave { mode: WAVE_POSE, amp: 0.4, k: 0.03, omega: 6.0, axis: Vector2::new(1.0, 0.0), half_width: 20.0, bias: 0.002, envelope: 0.5, phase: 0.0, age: 1.0 };
            }
            cl.opt.types[0].pose_handle = flag;
            cl.opt.pose_solve = solve;
            for _ in 0..90 {
                cl.step(DT);
            }
            let posed = cl.bodies.iter().filter(|b| b.pose_st.solves > 0).count();
            (cl.state_hash(), posed)
        };
        let base = run(false, false);
        assert_eq!(base, run(true, false), "the flags do nothing with the option off");
        assert_eq!(base.1, 0);
        let on = run(false, true);
        assert_ne!(on.0, base.0, "the option on changes the pose");
        assert_eq!(on.1, 6, "every creature solved");
    }

    /// [px/s along +x, px/s across] of a worm (middle row flagged) over 4 s after 2 s.
    fn worm_speed(solve: bool, slope: f32, drive: f32) -> (f32, f32, u32) {
        let mut cl = game_like();
        cl.opt.pose_solve = solve;
        let c = worm(&mut cl, 24, Vector2::ZERO, true);
        let length = 24.0 * 2.0 * R;
        cl.bodies[c].wave = wave(slope, length, 1.0, 0.6, 0.0);
        cl.bodies[c].swim = crate::cells::Swim { acc: drive, pulse: 0.3, axis: Vector2::new(1.0, 0.0) };
        for _ in 0..120 {
            cl.step(DT);
        }
        let c0 = cl.bodies[c].center();
        for _ in 0..240 {
            cl.step(DT);
        }
        let d = (cl.bodies[c].center() - c0) / 4.0;
        (d.x, d.y, cl.bodies[c].pose_st.fallbacks)
    }

    /// Proof 2: the worm swims by the pose wave alone, and by the drive with the game's gentle
    /// wave, as fast with the handle-driven pose as with the ribbon (within 10 %). The full
    /// stroke (slope 1, past the curvature clamp at the tail) is printed: a little faster.
    #[test]
    fn a_worm_swims_as_fast_with_the_pose_solve() {
        for (slope, drive) in [(1.0, 0.0), (0.6, 0.0), (0.3, 0.0), (0.3, 110.0)] {
            let ribbon = worm_speed(false, slope, drive);
            let solved = worm_speed(true, slope, drive);
            println!(
                "worm 24 × 5, slope {} at 1 Hz, drive {} px/s²: ribbon {:.1} px/s (across {:.1}), pose solve {:.1} px/s (across {:.1}), {:.1} % of it, fallbacks {}",
                slope,
                drive,
                ribbon.0,
                ribbon.1,
                solved.0,
                solved.1,
                100.0 * solved.0 / ribbon.0,
                solved.2
            );
            assert!(ribbon.0 > 10.0, "it swims: {:?}", ribbon);
            assert!(solved.0 > 0.9 * ribbon.0, "ribbon {:?} solved {:?}", ribbon, solved);
            if slope < 1.0 {
                assert!(solved.0 < 1.1 * ribbon.0, "ribbon {:?} solved {:?}", ribbon, solved);
            }
            assert!(solved.1.abs() < 0.1 * solved.0, "no crabbing: {:?}", solved);
            assert_eq!(solved.2, 0, "never the ribbon");
        }
    }

    // --- Designs with protrusions (proof 3) ---

    include!("cells_pose_designs.rs");

    /// The game's types for these designs: (elasticity factor, pose_handle) per slot.
    fn game_types(cl: &mut Cells, kinds: &[(f32, bool)]) {
        for (t, &(e, h)) in kinds.iter().enumerate() {
            cl.opt.types[t].elastic = e;
            cl.opt.types[t].pose_handle = h;
            cl.opt.types[t].thrust = 0.0;
        }
    }

    fn spawn(cl: &mut Cells, cells: &[(f32, f32, f32, u8)], at: Vector2) -> usize {
        let c: Vec<Vector2> = cells.iter().map(|q| at + Vector2::new(q.0, q.1)).collect();
        let r: Vec<f32> = cells.iter().map(|q| q.2).collect();
        let t: Vec<u8> = cells.iter().map(|q| q.3).collect();
        cl.add_creature(&c, &r, &t)
    }

    #[derive(Debug, Default, Clone, Copy)]
    struct Burst {
        /// Worst goal-pose link strain: links touching a protrusion cell, links of the body.
        goal_prot: f32,
        goal_body: f32,
        /// Protrusion cells' radius scales (lowest, highest).
        rad_lo: f32,
        rad_hi: f32,
        /// Worst live link strain over the protrusion's links.
        live_prot: f32,
        /// Lengths a second along +x.
        speed: f32,
        handles: usize,
        protrusion: usize,
        length: f32,
    }

    /// A design at the burst wave (slope 0.55, 1.7 Hz, wavelength 1.4 × the pose length,
    /// envelope 1), swum by the drive in the game's elastic world, measured over two cycles
    /// after 1 s. `wavelength` overrides the pose length's (px).
    fn burst(cells: &[(f32, f32, f32, u8)], kinds: &[(f32, bool)], solve: bool, wavelength: Option<f32>) -> Burst {
        let mut cl = game_like();
        cl.opt.elastic = 0.65;
        cl.opt.pose_solve = solve;
        game_types(&mut cl, kinds);
        let c = spawn(&mut cl, cells, Vector2::ZERO);
        let axis = Vector2::new(1.0, 0.0);
        let length = cl.bodies[c].pose_length(&cl.opt, axis);
        let mut wopt = cl.opt.clone();
        wopt.pose_solve = true;
        let (handles, _) = cl.bodies[c].pick_pose_handles(&wopt, axis);
        let hop = hops(&cl.bodies[c], &handles);
        let prot: Vec<bool> = hop.iter().map(|&h| h > 2).collect();
        let lam = wavelength.unwrap_or(1.4 * length);
        cl.bodies[c].wave = wave(0.55, lam, 1.7, 1.0, 0.0);
        cl.bodies[c].swim = crate::cells::Swim { acc: 300.0, pulse: 0.3, axis };
        for _ in 0..60 {
            cl.step(DT);
        }
        let mut out = Burst { rad_lo: f32::INFINITY, rad_hi: f32::NEG_INFINITY, handles: handles.len(), protrusion: prot.iter().filter(|&&p| p).count(), length, ..Default::default() };
        let c0 = cl.bodies[c].center();
        let frames = (2.0 / 1.7 / DT).ceil() as usize;
        for _ in 0..frames {
            cl.step(DT);
            let b = &cl.bodies[c];
            for l in &b.links {
                let (i, j) = (l.i as usize, l.j as usize);
                let g = goal_strain(b, i, j).abs();
                if prot[i] || prot[j] {
                    out.goal_prot = out.goal_prot.max(g);
                    out.live_prot = out.live_prot.max(live_strain(b, i, j, l.d_base).abs());
                } else {
                    out.goal_body = out.goal_body.max(g);
                }
            }
            for i in 0..b.n {
                if prot[i] {
                    out.rad_lo = out.rad_lo.min(b.muscle[i]);
                    out.rad_hi = out.rad_hi.max(b.muscle[i]);
                }
            }
            if solve {
                assert!(b.pose_st.warm, "solved every frame");
            }
        }
        let b = &cl.bodies[c];
        let span = cells.iter().map(|q| q.0 + q.2).fold(f32::MIN, f32::max) - cells.iter().map(|q| q.0 - q.2).fold(f32::MAX, f32::min);
        out.speed = (b.center() - c0).x / (frames as f32 * DT) / span;
        out
    }

    fn report(name: &str, ribbon: &Burst, solved: &Burst, same: &Burst) {
        println!(
            "{}: {} handles, {} protrusion cells; pose length {:.0} px (design {:.0} px)\n  ribbon (1.4 × the design length): goal strain protrusions {:.1} % body {:.1} %, radius {:.2}..{:.2}, live protrusion strain {:.1} %, {:.2} lengths/s\n  ribbon (the solve's wavelength): goal strain protrusions {:.1} % body {:.1} %, radius {:.2}..{:.2}, live protrusion strain {:.1} %, {:.2} lengths/s\n  pose solve: goal strain protrusions {:.1} % body {:.1} %, radius {:.3}..{:.3}, live protrusion strain {:.1} %, {:.2} lengths/s",
            name,
            solved.handles,
            solved.protrusion,
            solved.length,
            ribbon.length,
            100.0 * ribbon.goal_prot,
            100.0 * ribbon.goal_body,
            ribbon.rad_lo,
            ribbon.rad_hi,
            100.0 * ribbon.live_prot,
            ribbon.speed,
            100.0 * same.goal_prot,
            100.0 * same.goal_body,
            same.rad_lo,
            same.rad_hi,
            100.0 * same.live_prot,
            same.speed,
            100.0 * solved.goal_prot,
            100.0 * solved.goal_body,
            solved.rad_lo,
            solved.rad_hi,
            100.0 * solved.live_prot,
            solved.speed
        );
    }

    /// Proof 3: fins and wings keep their shape under the handle-driven pose at a burst; the
    /// ribbon strains them (asserted, so the test shows the difference).
    #[test]
    fn protrusions_keep_their_shape_at_a_burst() {
        // thruster_ship_edit: body, thruster, spike, spine, bone (the flagged core).
        let ship = [(1.0, false), (0.0, false), (1.0, false), (0.5, true), (0.05, true)];
        // manta: body, spine (flagged), thruster, spike.
        let manta = [(1.0, false), (0.5, true), (0.0, false), (1.0, false)];
        for (name, cells, kinds, live_bound) in [("thruster_ship_edit", &SHIP_EDIT[..], &ship[..], 0.25f32), ("manta", &MANTA[..], &manta[..], 0.25f32)] {
            let ribbon = burst(cells, kinds, false, None);
            let solved = burst(cells, kinds, true, None);
            let same = burst(cells, kinds, false, Some(1.4 * solved.length));
            report(name, &ribbon, &solved, &same);
            assert!(solved.goal_prot < 0.05, "{}: protrusions' goal strain {}", name, solved.goal_prot);
            assert!(solved.rad_lo >= 0.95 && solved.rad_hi <= 1.05, "{}: radius {}..{}", name, solved.rad_lo, solved.rad_hi);
            assert!(solved.live_prot < live_bound, "{}: live protrusion strain {}", name, solved.live_prot);
            assert!(ribbon.goal_prot > 0.2 && same.goal_prot > 0.2, "{}: the ribbon strains them: {} / {}", name, ribbon.goal_prot, same.goal_prot);
            assert!(ribbon.rad_lo < 0.8 || ribbon.rad_hi > 1.2, "{}: the ribbon's radii swing", name);
            assert!(ribbon.live_prot > 2.0 * solved.live_prot, "{}: the ribbon flexes them live", name);
            // The body: no worse than the ribbon's by more than a point (thruster_ship_edit's
            // worst body link joins a free cell to a bone cell on the body's edge, which the wave
            // places as the ribbon would, at the full envelope the handles' extent gives it).
            assert!(solved.goal_body <= same.goal_body + 0.01, "{}: body goal strain {} against the ribbon's {}", name, solved.goal_body, same.goal_body);
        }
    }

    /// Proof 4: threaded equals serial with the option on: creatures colliding while they
    /// swim by the wave, worms with flagged spines, a handle cell removed and a cell added
    /// mid-run (handles picked again), a creature merged in a join.
    #[test]
    fn threaded_equals_serial_with_the_pose_solve() {
        let run = |threads: usize| {
            let mut cl = crash_world(threads);
            cl.opt.pose_solve = true;
            cl.opt.drag.enabled = true;
            for b in cl.bodies.iter_mut() {
                b.wave = Wave { mode: WAVE_POSE, amp: 0.5, k: 0.03, omega: 6.0, axis: Vector2::new(1.0, 0.0), half_width: 0.0, bias: 0.002, envelope: 0.6, phase: 0.0, age: 0.0 };
            }
            let w = worm(&mut cl, 16, Vector2::new(200.0, -300.0), true);
            let v = worm(&mut cl, 12, Vector2::new(200.0, -240.0), true);
            for &c in &[w, v] {
                cl.bodies[c].wave = wave(0.6, 220.0, 1.5, 0.6, 0.0);
                cl.bodies[c].swim = crate::cells::Swim { acc: 200.0, pulse: 0.3, axis: Vector2::new(1.0, 0.0) };
            }
            let mut picks = 0;
            let mut joined = 0;
            for f in 0..150 {
                cl.step(DT);
                if f == 50 {
                    // A handle of the worm (its middle row's 5th cell) removed.
                    let h = cl.bodies[w].pose_st.handles[4] as usize;
                    cl.remove_cell(w, h);
                    cl.add_cell(0, cl.bodies[0].pos[0] + Vector2::new(-14.0, 0.0), 7.0, 0);
                }
                if f == 30 || f == 100 {
                    let caps = cl.find_captures(20.0, false);
                    joined += cl.join(&caps);
                }
                for b in cl.bodies.iter().filter(|b| b.alive) {
                    if b.pose_st.warm {
                        assert!(b.pose_st.handles.len() >= 2, "never fewer than two handles");
                    }
                }
            }
            for b in cl.bodies.iter().filter(|b| b.alive) {
                picks += b.pose_st.picks;
            }
            assert_eq!(cl.bodies[w].pose_st.handles.len(), 15, "the worm picked its handles again");
            assert!(joined > 0, "creatures merged");
            (cl.state_hash(), cl.events.len(), picks, joined)
        };
        let a = run(1);
        println!("pose solve threaded: hash {:x}, {} events, {} handle picks, {} links joined", a.0, a.1, a.2, a.3);
        assert_eq!(a, run(4));
        assert_eq!(a, run(0));
        assert_eq!(a, run(1), "a replay");
    }

    /// The worst goal-pose link strain over all of a creature's links.
    fn worst_goal(b: &Body) -> f32 {
        b.links.iter().map(|l| goal_strain(b, l.i as usize, l.j as usize).abs()).fold(0.0, f32::max)
    }

    /// Proof 6: flagged cells are the handles; with none flagged (or too few, or bunched) the
    /// centreline; the chain when the centreline has one station; nothing below two.
    #[test]
    fn handle_choice() {
        let opt = Opt::default();
        let mut flagged = opt.clone();
        flagged.types[1].pose_handle = true;
        let ax = Vector2::new(1.0, 0.0);
        // The worm with its middle row flagged: exactly that row.
        let mut cl = Cells::default();
        let c = worm(&mut cl, 24, Vector2::ZERO, true);
        let b = &cl.bodies[c];
        let (h, src) = b.pick_pose_handles(&flagged, ax);
        let row: Vec<u32> = (0..b.n as u32).filter(|&i| b.typ[i as usize] == 1).collect();
        assert_eq!((h.clone(), src), (row.clone(), HANDLES_TYPED));
        // No flag: the centreline, cells within their own diameter of the axis (three rows).
        let (h, src) = b.pick_pose_handles(&opt, ax);
        assert_eq!(src, HANDLES_CENTRELINE);
        assert_eq!(h.len(), 72);
        assert!(h.iter().all(|&i| b.rest_local[i as usize].y.abs() <= 2.0 * R));
        // Two flagged cells bunched at one end (under a third of the length): the centreline.
        let mut few = Cells::default();
        let d = worm_design(24, 5, R, Vector2::ZERO);
        let t: Vec<u8> = (0..d.len()).map(|i| (i == 48 || i == 49) as u8).collect();
        let c2 = few.add_creature(&d, &vec![R; d.len()], &t);
        assert_eq!(few.bodies[c2].pick_pose_handles(&flagged, ax).1, HANDLES_CENTRELINE);
        // Across the axis, a worm 2 long and 5 wide turned a quarter: its centreline has one
        // station... a column of cells across the axis gives the chain.
        let col: Vec<Vector2> = (0..5).map(|k| Vector2::new(0.0, 2.0 * R * k as f32)).chain((0..5).map(|k| Vector2::new(2.0 * R, 2.0 * R * k as f32))).collect();
        let mut cl3 = Cells::default();
        let c3 = cl3.add_creature(&col, &vec![R; col.len()], &vec![0; col.len()]);
        let (h3, src3) = cl3.bodies[c3].pick_pose_handles(&opt, ax);
        println!("a 2 × 5 block across the axis: handles {:?} by rule {}", h3, src3);
        assert!(h3.len() >= 2);
        // One cell, and two cells side by side across the axis: none; two along it: both.
        let mut tiny = Cells::default();
        let one = tiny.add_creature(&[Vector2::ZERO], &[R], &[0]);
        let pair_across = tiny.add_creature(&[Vector2::new(0.0, 300.0), Vector2::new(0.0, 314.0)], &[R, R], &[0, 0]);
        let pair_along = tiny.add_creature(&[Vector2::new(0.0, 600.0), Vector2::new(14.0, 600.0)], &[R, R], &[0, 0]);
        assert_eq!(tiny.bodies[one].pick_pose_handles(&opt, ax), (vec![], HANDLES_NONE));
        assert_eq!(tiny.bodies[pair_across].pick_pose_handles(&opt, ax), (vec![], HANDLES_NONE));
        assert_eq!(tiny.bodies[pair_along].pick_pose_handles(&opt, ax).0.len(), 2);
        // They swim by the wave without a panic: the ribbon for the first two (counted), the
        // solve (no free cell) for the third.
        tiny.opt.pose_solve = true;
        for c in [one, pair_across, pair_along] {
            tiny.bodies[c].wave = wave(0.5, 100.0, 1.0, 0.6, 0.0);
        }
        for _ in 0..60 {
            tiny.step(DT);
        }
        let s = |c: usize| (tiny.bodies[c].pose_st.solves, tiny.bodies[c].pose_st.fallbacks);
        println!("one cell (solves, fallbacks) {:?}, two across {:?}, two along {:?}", s(one), s(pair_across), s(pair_along));
        assert_eq!(s(one), (0, 60));
        assert_eq!(s(pair_across), (0, 60));
        assert_eq!(s(pair_along), (60, 0));
        assert_eq!(tiny.health()[7], 0.0, "finite");
    }

    /// Proof 6: a plain 10 × 5 hex ship (no flagged type) poses by its centreline, its goal
    /// strain no larger than the ribbon's.
    #[test]
    fn a_ship_without_a_spine_poses_by_its_centreline() {
        let run = |solve: bool| {
            let mut cl = game_like();
            cl.opt.pose_solve = solve;
            let d = worm_design(10, 5, R, Vector2::ZERO);
            let c = cl.add_creature(&d, &vec![R; d.len()], &vec![0; d.len()]);
            let len = cl.bodies[c].pose_length(&cl.opt, Vector2::new(1.0, 0.0));
            cl.bodies[c].wave = wave(0.55, 1.4 * len, 1.7, 1.0, 0.0);
            let mut worst = 0.0f32;
            let mut mus = (f32::INFINITY, f32::NEG_INFINITY);
            for f in 0..130 {
                cl.step(DT);
                if f >= 60 {
                    let b = &cl.bodies[c];
                    worst = worst.max(worst_goal(b));
                    for &m in &b.muscle {
                        mus = (mus.0.min(m), mus.1.max(m));
                    }
                }
            }
            (worst, mus, cl.bodies[c].pose_st.source, len, cl.health()[7])
        };
        let ribbon = run(false);
        let solved = run(true);
        println!(
            "10 × 5 ship, burst: ribbon goal strain {:.1} % (radius {:.2}..{:.2}, wavelength 1.4 × {:.0} px); centreline pose solve {:.1} % (radius {:.2}..{:.2}, 1.4 × {:.0} px)",
            100.0 * ribbon.0,
            ribbon.1 .0,
            ribbon.1 .1,
            ribbon.3,
            100.0 * solved.0,
            solved.1 .0,
            solved.1 .1,
            solved.3
        );
        assert_eq!(solved.2, HANDLES_CENTRELINE);
        assert!(solved.0 <= ribbon.0 + 1e-3, "solve {} ribbon {}", solved.0, ribbon.0);
        assert_eq!(solved.4, 0.0);
    }

    /// Proof 6: a worm that loses a spine cell mid-swim keeps swimming (handles picked
    /// again); a split gives each part its own handles.
    #[test]
    fn a_lost_handle_and_a_split() {
        let mut cl = game_like();
        cl.opt.pose_solve = true;
        let c = worm(&mut cl, 24, Vector2::ZERO, true);
        cl.bodies[c].wave = wave(0.3, 336.0, 1.0, 0.6, 0.0);
        cl.bodies[c].swim = crate::cells::Swim { acc: 110.0, pulse: 0.3, axis: Vector2::new(1.0, 0.0) };
        let speed = |cl: &mut Cells| {
            let c0 = cl.bodies[c].center();
            for _ in 0..180 {
                cl.step(DT);
            }
            (cl.bodies[c].center() - c0).x / 3.0
        };
        speed(&mut cl);
        let before = speed(&mut cl);
        let h = cl.bodies[c].pose_st.handles[12] as usize;
        let uid = cl.bodies[c].uid[h];
        cl.remove_cell(c, h);
        let after = speed(&mut cl);
        let b = &cl.bodies[c];
        println!("worm losing a spine cell: {:.1} px/s before, {:.1} after; handles {} picked again, fallbacks {}", before, after, b.pose_st.handles.len(), b.pose_st.fallbacks);
        assert!((after - before).abs() < 0.2 * before, "{} -> {}", before, after);
        assert_eq!(b.pose_st.handles.len(), 23);
        assert!(b.pose_st.handles.iter().all(|&i| b.uid[i as usize] != uid));
        assert_eq!(b.pose_st.fallbacks, 0);
        // Cut through: a column of five cells taken out halves it.
        let parts_before = cl.bodies.len();
        loop {
            let b = &cl.bodies[c];
            let x0 = b.rest_local.iter().map(|p| p.x).fold(f32::INFINITY, f32::min);
            let x1 = b.rest_local.iter().map(|p| p.x).fold(f32::NEG_INFINITY, f32::max);
            let mid = 0.5 * (x0 + x1);
            if cl.bodies.len() > parts_before {
                break;
            }
            let k = (0..b.n).min_by(|&i, &j| (b.rest_local[i].x - mid).abs().partial_cmp(&(b.rest_local[j].x - mid).abs()).unwrap()).unwrap();
            cl.remove_cell(c, k);
        }
        let p = cl.bodies.len() - 1;
        for _ in 0..60 {
            cl.step(DT);
        }
        for part in [c, p] {
            let b = &cl.bodies[part];
            println!("part {}: {} cells, {} handles by rule {}, solves {}, fallbacks {}", part, b.n, b.pose_st.handles.len(), b.pose_st.source, b.pose_st.solves, b.pose_st.fallbacks);
            assert_eq!(b.pose_st.source, HANDLES_TYPED);
            assert!(b.pose_st.handles.len() >= 2);
            assert!(b.pose_st.handles.iter().all(|&i| b.typ[i as usize] == 1));
            assert_eq!(b.pose_st.solves, 60);
        }
        assert_eq!(cl.health()[7], 0.0);
    }

    /// Proof 7: the wave starting eases in (no jump in the goal pose), stopping gives the
    /// design back exactly, and starting again starts from the design.
    #[test]
    fn starting_and_stopping_the_wave() {
        // The ribbon's shape error 3 s after the same wave stopped, for comparison.
        let ribbon_after = {
            let mut cl = game_like();
            let c = worm(&mut cl, 24, Vector2::ZERO, true);
            cl.bodies[c].wave = wave(0.6, 336.0, 1.0, 0.6, 0.0);
            for _ in 0..120 {
                cl.step(DT);
            }
            cl.bodies[c].wave.mode = WAVE_OFF;
            cl.bodies[c].design_pose_back();
            for _ in 0..180 {
                cl.step(DT);
            }
            cl.bodies[c].shape_error()
        };
        let mut cl = game_like();
        cl.opt.pose_solve = true;
        let c = worm(&mut cl, 24, Vector2::ZERO, true);
        let gap = |b: &Body| b.bent.iter().zip(&b.rest_local).map(|(p, q)| (*p - *q).length()).fold(0.0, f32::max);
        let mut first = 0.0f32;
        let mut step_max = 0.0f32;
        let mut peak = 0.0f32;
        for round in 0..2 {
            cl.bodies[c].wave = wave(0.6, 336.0, 1.0, 0.6, 0.0);
            let mut last: Vec<Vector2> = cl.bodies[c].rest_local.clone();
            for f in 0..120 {
                cl.step(DT);
                let b = &cl.bodies[c];
                if f == 0 {
                    first = gap(b);
                }
                step_max = step_max.max(b.bent.iter().zip(&last).map(|(p, q)| (*p - *q).length()).fold(0.0, f32::max));
                peak = peak.max(gap(b));
                last = b.bent.clone();
            }
            println!("round {}: the goal pose {:.2} px off the design at the first frame, at most {:.2} px a frame, {:.1} px at most", round, first, step_max, peak);
            // The wave moves the pose by about 2π f × its reach a frame (10.5 % of it at 1 Hz):
            // no frame moves it more than half as much again, the first included.
            let travel = TAU * 1.0 * peak * DT;
            assert!(first < 0.05 * peak && first < travel, "no jump at the start: {} of {}", first, peak);
            assert!(step_max < 1.5 * travel, "no jump: {} a frame of {}", step_max, peak);
            // Stopped (set_wave(WAVE_OFF)): the design's lengths, angles and radii exactly.
            cl.bodies[c].wave.mode = WAVE_OFF;
            cl.bodies[c].design_pose_back();
            for _ in 0..180 {
                cl.step(DT);
            }
            let b = &cl.bodies[c];
            assert!(b.links.iter().all(|l| l.d_design == l.d_base && l.ai_design == l.ai_base && l.aj_design == l.aj_base));
            assert!(b.muscle.iter().all(|&m| m == 1.0));
            assert!(!b.pose_st.warm);
            println!("  stopped: shape error {:.4} 3 s later (the ribbon's {:.4})", b.shape_error(), ribbon_after);
            assert!(b.shape_error() < 0.02 && b.shape_error() < 1.5 * ribbon_after + 0.002, "back to the design: {}", b.shape_error());
        }
    }

    /// Proof 8: the cost, 30 creatures × 150 cells (30 × 5 worms, middle row flagged)
    /// swimming by the pose wave, the ribbon against the handle-driven pose, serial and on
    /// 4 threads (ms a frame: the mean over 120 frames after 30, the quickest of three).
    #[test]
    fn cost_printed() {
        let run = |solve: bool, threads: usize| {
            let mut cl = game_like();
            cl.set_threads(threads);
            cl.opt.pose_solve = solve;
            for k in 0..30 {
                let at = Vector2::new((k % 5) as f32 * 600.0, (k / 5) as f32 * 120.0);
                let c = worm(&mut cl, 30, at, true);
                cl.bodies[c].wave = wave(0.45, 1.4 * 420.0, 1.4, 1.0, 0.0);
                cl.bodies[c].swim = crate::cells::Swim { acc: 150.0, pulse: 0.3, axis: Vector2::new(1.0, 0.0) };
            }
            for _ in 0..30 {
                cl.step(DT);
            }
            // The quickest of three runs of 120 frames (the machine's noise is all upward).
            let mut best = (f64::INFINITY, f64::INFINITY);
            for _ in 0..3 {
                let t = Instant::now();
                let mut prep = 0u64;
                for _ in 0..120 {
                    cl.step(DT);
                    prep += cl.stats.prep_us;
                }
                let ms = t.elapsed().as_secs_f64() * 1000.0 / 120.0;
                if ms < best.0 {
                    best = (ms, prep as f64 / 1000.0 / 120.0);
                }
            }
            best
        };
        for threads in [1, 4] {
            let off = run(false, threads);
            let on = run(true, threads);
            println!(
                "30 × 150 cells swimming by the pose wave, {} thread(s): ribbon {:.2} ms a frame (prepare {:.2}), pose solve {:.2} ms (prepare {:.2}): +{:.2} ms",
                threads,
                off.0,
                off.1,
                on.0,
                on.1,
                on.0 - off.0
            );
        }
    }
}
