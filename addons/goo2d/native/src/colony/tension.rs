//! Surface tension along a creature's surface (milestone 3 of the colony plan,
//! docs/colony-tension.md): the creature pulls itself inward a little, as a cluster of
//! bubbles does, rounding off and drawing neighbouring cells into each other until their
//! pressure balances it.
//!
//! The surface is where the exposure pass (colony/exposure.rs) says the cells face water:
//! - every skin edge of a ring whose two beads both face the water (the outside, a crevice,
//!   or a pocket, which pulls with `pockets` of it);
//! - the hops of the outline's loops between cells: a run's last bead to the first bead of
//!   the run that continues the outline on the cell it meets (a junction between two
//!   cells, or a ring meeting a core: the core's virtual bead). A hop pulls in full up to
//!   `hop` × the two beads' radii summed and fades to nothing at `hop_max` × them: the
//!   outline's loops sometimes continue across a crevice or a bay, and tension across
//!   water would be a rubber band drawing its far sides together from a distance.
//!
//! Every such edge pulls its two ends toward each other with the edge's tension T_e: +T_e u
//! on its first end and −T_e u on its second (u the unit vector between them). On a point
//! of a smooth stretch that sums to T (u_next − u_prev), the tension times the outline's
//! turn there: inward on a convex stretch, outward out of a notch between two cells (which
//! is what zips a wall wider). The forces come in equal and opposite pairs along the line
//! joining their points, so they add no net force and no torque to a free creature,
//! whatever each edge's tension is; so every adjustment below is made per edge, never per
//! point (a per-point clamp would break that).
//!
//! - T_e = strength × the creature's scale × the mean of its ends' surface factors (1
//!   outside, `pockets` facing a pocket) × the mean of its ends' cells' type factors ×
//!   min(1, L / `min_edge`) (an edge shorter than `min_edge` pulls in proportion: its
//!   transverse stiffness, T / L, stays below T / min_edge, and two points that meet do not
//!   pull along a direction that flips every substep) × the hop's fade.
//! - It acts every substep, from the positions the substep starts at, as an impulse (force
//!   × the substep) on the velocities before the prediction: explicit, at the substep's
//!   step, where T h² / (m min_edge) stays far below 1 for any strength a creature wants.
//! - Edges between two points of one core are left out (forces inside a rigid body cancel);
//!   a hop's end on a core pushes the core: the force on its centre and its moment about
//!   the centre on the core's turn, so angular momentum (orbital and the cores' spin) is
//!   conserved too.
//! - The edges are built from the last exposure pass, once per pass. A manual promote or
//!   demote bumps the topology: the tension waits for the next pass, which it asks for.

use super::exposure::LoopPt;
use super::*;

/// The surface tension's settings, colony-wide.
#[derive(Clone, Copy, Debug)]
pub struct Tension {
    /// The tension each surface edge pulls with (a force: mass × px/s²; GooColonySim
    /// scales its default by GooTuning.unit). 0: off, and nothing of it runs.
    pub strength: f32,
    /// Skin facing a pocket pulls with this factor of it (0: pockets keep their size).
    pub pockets: f32,
    /// An edge shorter than this (px) pulls in proportion to its length.
    pub min_edge: f32,
    /// A hop between cells pulls in full up to `hop` × its two beads' radii summed, and
    /// fades linearly to nothing at `hop_max` × them.
    pub hop: f32,
    pub hop_max: f32,
    /// Per cell type: a factor on the tension of the edges at its cells' points (an edge
    /// takes the mean of its two ends'): 0 slack, above 1 taut.
    pub types: [f32; MAX_TYPES],
}

impl Default for Tension {
    fn default() -> Self {
        Tension { strength: 0.0, pockets: 0.0, min_edge: 0.5, hop: 2.5, hop_max: 3.5, types: [1.0; MAX_TYPES] }
    }
}

impl Tension {
    pub fn on(&self) -> bool {
        self.strength > 0.0
    }
}

/// One edge the tension pulls along: its two ends (a bead or a core's virtual bead), their
/// surface codes (1 outside, 2 pocket), and whether it is a hop between cells.
#[derive(Clone, Copy, Debug)]
pub(super) struct TEdge {
    a: LoopPt,
    b: LoopPt,
    sa: u8,
    sb: u8,
    hop: bool,
}

impl Creature {
    /// The edges, from the last exposure pass (see the module's head).
    fn build_tension_edges(&mut self) {
        let mut edges = std::mem::take(&mut self.tension_edges);
        edges.clear();
        let bead = |i: usize| LoopPt { core: false, index: i as u32, local: 0 };
        for ring in &self.rings {
            for k in 0..ring.n {
                let (i, j) = (ring.start + k, ring.start + (k + 1) % ring.n);
                let (si, sj) = (self.surface[i], self.surface[j]);
                if si != 0 && sj != 0 {
                    edges.push(TEdge { a: bead(i), b: bead(j), sa: si, sb: sj, hop: false });
                }
            }
        }
        for l in &self.loops {
            let code = if l.kind == LoopKind::Outside { 1 } else { 2 };
            let n = l.pts.len();
            if n < 2 {
                continue;
            }
            for k in 0..n {
                let (p, q) = (l.pts[k], l.pts[(k + 1) % n]);
                match (p.core, q.core) {
                    (true, true) if p.index == q.index => continue,
                    (false, false) => {
                        let (i, j) = (p.index as usize, q.index as usize);
                        let ri = self.bead_ring[i] as usize;
                        if ri == self.bead_ring[j] as usize {
                            let ring = &self.rings[ri];
                            if j == ring.start + (i - ring.start + 1) % ring.n {
                                // A skin edge, counted above.
                                continue;
                            }
                        }
                    }
                    _ => {}
                }
                let sp = if p.core { code } else { self.surface[p.index as usize].max(1) };
                let sq = if q.core { code } else { self.surface[q.index as usize].max(1) };
                edges.push(TEdge { a: p, b: q, sa: sp, sb: sq, hop: true });
            }
        }
        self.tension_edges = edges;
        self.tension_built = self.exp_version;
    }

    #[inline]
    fn tension_end(&self, p: LoopPt) -> (Vector2, f32, usize) {
        if p.core {
            let k = p.index as usize;
            let cell = self.ccell[k] as usize;
            let t = &self.cells[cell].t;
            (self.core_point(k, p.local as usize), t.bead_radius * self.cr[k] / t.radius.max(1e-6), cell)
        } else {
            let i = p.index as usize;
            (self.pos[i], self.r[i], self.rings[self.bead_ring[i] as usize].cell)
        }
    }

    /// The tension's impulses for this substep (see the module's head), from the positions
    /// now, into the beads' and cores' velocities.
    pub(super) fn apply_tension(&mut self, ts: &Tension) {
        let scale = ts.strength * self.tension_scale;
        if scale <= 0.0 || !self.exp_valid || self.loops_topology != self.topology || self.surface.len() != self.pos.len() {
            return;
        }
        if self.tension_built != self.exp_version {
            self.build_tension_edges();
        }
        let h = self.h;
        let edges = std::mem::take(&mut self.tension_edges);
        let mut fx = std::mem::take(&mut self.tension_f);
        let mut px = std::mem::take(&mut self.tension_x);
        fx.clear();
        px.clear();
        let surf = |code: u8| if code == 2 { ts.pockets } else { 1.0 };
        let inv_min = 1.0 / ts.min_edge.max(1e-6);
        for e in &edges {
            let (xa, ra, ca) = self.tension_end(e.a);
            let (xb, rb, cb) = self.tension_end(e.b);
            let d = xb - xa;
            let l2 = len_sq(d);
            let mut f = Vector2::ZERO;
            if l2 > 1e-12 {
                let length = l2.sqrt();
                let ta = ts.types[(self.cells[ca].ctype as usize).min(MAX_TYPES - 1)];
                let tb = ts.types[(self.cells[cb].ctype as usize).min(MAX_TYPES - 1)];
                let mut t = scale * 0.25 * (surf(e.sa) + surf(e.sb)) * (ta + tb) * (length * inv_min).min(1.0);
                if e.hop {
                    let reach = ra + rb;
                    let (full, none) = (ts.hop * reach, ts.hop_max * reach);
                    if length >= none {
                        t = 0.0;
                    } else if length > full {
                        t *= (none - length) / (none - full).max(1e-6);
                    }
                }
                f = d * (t / length);
            }
            px.push(xa);
            px.push(xb);
            fx.push(f);
            fx.push(-f);
            if f == Vector2::ZERO {
                continue;
            }
            for (p, x, g) in [(e.a, xa, f), (e.b, xb, -f)] {
                if p.core {
                    let k = p.index as usize;
                    self.cvel[k] += g * (self.cw[k] * h);
                    self.comega[k] += cross(x - self.cpos[k], g) * (self.cwrot[k] * h);
                } else {
                    let i = p.index as usize;
                    self.vel[i] += g * (self.w[i] * h);
                }
            }
        }
        self.tension_edges = edges;
        self.tension_f = fx;
        self.tension_x = px;
    }
}
