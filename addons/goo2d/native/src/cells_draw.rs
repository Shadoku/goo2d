//! GooCells' skins as triangles (docs/cells.md, "Drawing"): one mesh per creature, built
//! from its link graph, so the whole world draws as one triangle array.
//!
//! Inside the outline: every inner face of the planar link graph (the triangles between
//! three linked cells, and the larger gaps a mixed-size packing leaves, when the cells'
//! discs nearly cover them: a real pocket stays open). A face whose cells are all of one
//! type is filled in that type's colour; a face of mixed types is cut into one quad per
//! cell (the cell, the midpoints of its two links, the face's centre), each in its cell's
//! colour, so every type's cells tile one contiguous piece with a straight border, and the
//! borders come out as a line list. Around the outline: per outline cell a fan from the
//! cell's centre to its stretch of the skin, a quadratic B-spline through the midpoints of
//! the outline surface (each boundary cell pushed out by its radius), so the skin is
//! smooth and every drawn point lies within one cell's reach of a centre (no skin drawn
//! over a wall at a concave corner).
//!
//! Vertex colours are the types' colours; UV.x is 1 at the cells' centres and inside, 0 on
//! the skin (a shader darkens an edge band with it); UV.y the type / 16.

use crate::cells::{Body, TypeParams, TYPES};
use crate::geom::{cross, len_sq};
use godot::builtin::{Color, Vector2};

#[derive(Default)]
pub struct Mesh {
    pub points: Vec<Vector2>,
    pub colors: Vec<Color>,
    pub uvs: Vec<Vector2>,
    /// Borders between types: pairs of points.
    pub lines: Vec<Vector2>,
}

impl Mesh {
    #[inline]
    fn tri(&mut self, a: Vector2, b: Vector2, c: Vector2, ua: f32, ub: f32, uc: f32, col: Color, t: f32) {
        self.points.push(a);
        self.points.push(b);
        self.points.push(c);
        self.colors.push(col);
        self.colors.push(col);
        self.colors.push(col);
        self.uvs.push(Vector2::new(ua, t));
        self.uvs.push(Vector2::new(ub, t));
        self.uvs.push(Vector2::new(uc, t));
    }

    pub fn append(&mut self, o: Mesh) {
        self.points.extend(o.points);
        self.colors.extend(o.colors);
        self.uvs.extend(o.uvs);
        self.lines.extend(o.lines);
    }
}

#[inline]
fn color_of(types: &[TypeParams; TYPES], t: u8) -> Color {
    let c = types[t as usize].color;
    Color::from_rgba(c[0], c[1], c[2], c[3])
}

/// The outline's outward direction at outline index k (as Body::outline_surface: the
/// chord between its two outline neighbours turned out; a hairpin, away from the
/// neighbour it doubles back to).
#[inline]
fn outward(b: &Body, k: usize) -> Vector2 {
    let m = b.outline.len();
    let a = b.pos[b.outline[(k + m - 1) % m] as usize];
    let c = b.outline[k] as usize;
    let e = b.pos[b.outline[(k + 1) % m] as usize];
    let t = e - a;
    let l = t.length();
    if l > 0.25 * b.r[c] {
        return Vector2::new(-t.y, t.x) / l;
    }
    let d = b.pos[c] - a;
    let dl = d.length();
    if dl > 1e-6 { d / dl } else { Vector2::new(0.0, -1.0) }
}

/// Faces of the planar link graph (lists of cells), the outer face left out.
pub fn inner_faces(b: &Body) -> Vec<Vec<u32>> {
    let n = b.n;
    let half = b.nb.len();
    let mut seen = vec![false; half];
    let mut faces: Vec<Vec<u32>> = Vec::new();
    let mut areas: Vec<f32> = Vec::new();
    // The half-edge i → j is entry q of i's list; arriving at j from i, the face goes on
    // along the neighbour of j before i in j's (angle sorted) list.
    for i in 0..n {
        for q in b.nb_start[i] as usize..b.nb_start[i + 1] as usize {
            if seen[q] {
                continue;
            }
            let mut face = Vec::new();
            let (mut u, mut qq) = (i, q);
            let mut ok = true;
            for _ in 0..(half + 1) {
                if seen[qq] {
                    ok = qq == q;
                    break;
                }
                seen[qq] = true;
                face.push(u as u32);
                let v = b.nb[qq].0 as usize;
                let (s, e) = (b.nb_start[v] as usize, b.nb_start[v + 1] as usize);
                let Some(back) = (s..e).find(|&x| b.nb[x].0 as usize == u) else {
                    ok = false;
                    break;
                };
                let nq = if back == s { e - 1 } else { back - 1 };
                u = v;
                qq = nq;
            }
            if !ok || face.len() < 3 {
                continue;
            }
            let mut a = 0.0f32;
            for k in 0..face.len() {
                a += cross(b.pos[face[k] as usize], b.pos[face[(k + 1) % face.len()] as usize]);
            }
            faces.push(face);
            areas.push(0.5 * a);
        }
    }
    if faces.is_empty() {
        return faces;
    }
    // The outer face: the largest; inner faces wind the other way.
    let mut outer = 0;
    for k in 1..faces.len() {
        if areas[k].abs() > areas[outer].abs() {
            outer = k;
        }
    }
    let sign = areas[outer].signum();
    let mut out = Vec::with_capacity(faces.len());
    for (k, f) in faces.into_iter().enumerate() {
        if k != outer && areas[k].signum() != sign && areas[k] != 0.0 {
            out.push(f);
        }
    }
    out
}

/// One creature's mesh.
pub fn creature_mesh(b: &Body, types: &[TypeParams; TYPES], border: bool) -> Mesh {
    let mut m = Mesh::default();
    let n = b.n;
    if n == 0 {
        return m;
    }
    let tv = |c: usize| b.typ[c] as f32 / 16.0;
    // Inner faces.
    for f in inner_faces(b) {
        let k = f.len();
        let mut g = Vector2::ZERO;
        let mut rs = 0.0;
        for &c in &f {
            g += b.pos[c as usize];
            rs += b.r[c as usize];
        }
        g /= k as f32;
        if k > 3 {
            // A gap the discs nearly cover is filled; a pocket is left open.
            let mut d = f32::INFINITY;
            for &c in &f {
                d = d.min((b.pos[c as usize] - g).length() - b.r[c as usize]);
            }
            if d > 0.6 * rs / k as f32 {
                continue;
            }
        }
        let t0 = b.typ[f[0] as usize];
        if f.iter().all(|&c| b.typ[c as usize] == t0) {
            let col = color_of(types, t0);
            if k == 3 {
                m.tri(b.pos[f[0] as usize], b.pos[f[1] as usize], b.pos[f[2] as usize], 1.0, 1.0, 1.0, col, tv(f[0] as usize));
            } else {
                for q in 0..k {
                    m.tri(g, b.pos[f[q] as usize], b.pos[f[(q + 1) % k] as usize], 1.0, 1.0, 1.0, col, tv(f[0] as usize));
                }
            }
            continue;
        }
        for q in 0..k {
            let (cp, c, cn) = (f[(q + k - 1) % k] as usize, f[q] as usize, f[(q + 1) % k] as usize);
            let (pc, mp, mn) = (b.pos[c], (b.pos[c] + b.pos[cp]) * 0.5, (b.pos[c] + b.pos[cn]) * 0.5);
            let col = color_of(types, b.typ[c]);
            m.tri(pc, mn, g, 1.0, 1.0, 1.0, col, tv(c));
            m.tri(pc, g, mp, 1.0, 1.0, 1.0, col, tv(c));
            if border && b.typ[c] != b.typ[cn] {
                m.lines.push(mn);
                m.lines.push(g);
            }
        }
    }
    // The rim.
    let ol = b.outline.len();
    if ol < 3 {
        // One or two cells: discs.
        for &c in &b.outline {
            let c = c as usize;
            let col = color_of(types, b.typ[c]);
            const SIDES: usize = 16;
            for s in 0..SIDES {
                let a0 = std::f32::consts::TAU * s as f32 / SIDES as f32;
                let a1 = std::f32::consts::TAU * (s + 1) as f32 / SIDES as f32;
                let p0 = b.pos[c] + Vector2::new(a0.cos(), a0.sin()) * b.r[c];
                let p1 = b.pos[c] + Vector2::new(a1.cos(), a1.sin()) * b.r[c];
                m.tri(b.pos[c], p0, p1, 1.0, 0.0, 0.0, col, tv(c));
            }
        }
        return m;
    }
    let surf: Vec<Vector2> = (0..ol).map(|k| {
        let c = b.outline[k] as usize;
        b.pos[c] + outward(b, k) * b.r[c]
    }).collect();
    let mid_s: Vec<Vector2> = (0..ol).map(|k| (surf[k] + surf[(k + 1) % ol]) * 0.5).collect();
    for k in 0..ol {
        let kp = (k + ol - 1) % ol;
        let kn = (k + 1) % ol;
        let c = b.outline[k] as usize;
        let (cpv, cnv) = (b.outline[kp] as usize, b.outline[kn] as usize);
        let pc = b.pos[c];
        let mp = (pc + b.pos[cpv]) * 0.5;
        let mn = (pc + b.pos[cnv]) * 0.5;
        let (p0, p1, p2) = (mid_s[kp], surf[k], mid_s[k]);
        let bz = |t: f32| p0 * ((1.0 - t) * (1.0 - t)) + p1 * (2.0 * t * (1.0 - t)) + p2 * (t * t);
        let ring = [mp, p0, bz(0.25), bz(0.5), bz(0.75), p2, mn];
        let uv = [1.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0];
        let col = color_of(types, b.typ[c]);
        for q in 0..6 {
            if len_sq(ring[q + 1] - ring[q]) < 1e-12 {
                continue;
            }
            m.tri(pc, ring[q], ring[q + 1], 1.0, uv[q], uv[q + 1], col, tv(c));
        }
        if border && b.typ[c] != b.typ[cnv] {
            m.lines.push(mn);
            m.lines.push(p2);
        }
    }
    m
}
