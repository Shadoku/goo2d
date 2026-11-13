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
    /// Triangles: three vertex indices each.
    pub indices: Vec<i32>,
    /// Borders between types: pairs of points.
    pub lines: Vec<Vector2>,
}

impl Mesh {
    /// A vertex: its index.
    #[inline]
    fn vert(&mut self, p: Vector2, u: f32, col: Color, t: f32) -> i32 {
        self.points.push(p);
        self.colors.push(col);
        self.uvs.push(Vector2::new(u, t));
        self.points.len() as i32 - 1
    }

    #[inline]
    fn tri_i(&mut self, a: i32, b: i32, c: i32) {
        self.indices.push(a);
        self.indices.push(b);
        self.indices.push(c);
    }

    /// The triangles' corners, three points each (for tests and measurements).
    pub fn triangles(&self) -> Vec<Vector2> {
        self.indices.iter().map(|&i| self.points[i as usize]).collect()
    }

    pub fn reserve(&mut self, vertices: usize, indices: usize) {
        self.points.reserve(vertices);
        self.colors.reserve(vertices);
        self.uvs.reserve(vertices);
        self.indices.reserve(indices);
    }

    pub fn append(&mut self, o: Mesh) {
        let base = self.points.len() as i32;
        self.points.extend(o.points);
        self.colors.extend(o.colors);
        self.uvs.extend(o.uvs);
        self.indices.extend(o.indices.iter().map(|&i| i + base));
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
    walk_faces(b).faces
}

/// Where a half-edge's face is: an inner face's index, the outer face, or none kept.
const OUTER: i32 = -1;
const NO_FACE: i32 = -2;

/// The planar link graph's faces with their half-edges.
#[derive(Default)]
pub struct Faces {
    /// Inner faces as lists of cells, wound opposite to the outer face.
    pub faces: Vec<Vec<u32>>,
    /// Per face, per cell k: the half-edge (an index into b.nb) from cell k to cell k + 1.
    pub halves: Vec<Vec<u32>>,
    /// Per half-edge: its face (an inner face's index, OUTER or NO_FACE).
    pub face_of: Vec<i32>,
    /// Per half-edge: the same link walked the other way.
    pub twin: Vec<u32>,
}

/// Walks every face of the planar link graph once.
pub fn walk_faces(b: &Body) -> Faces {
    let n = b.n;
    let half = b.nb.len();
    let mut seen = vec![false; half];
    let mut twin = vec![u32::MAX; half];
    let mut faces: Vec<Vec<u32>> = Vec::new();
    let mut halves: Vec<Vec<u32>> = Vec::new();
    let mut areas: Vec<f32> = Vec::new();
    // The half-edge i → j is entry q of i's list; arriving at j from i, the face goes on
    // along the neighbour of j before i in j's (angle sorted) list.
    for i in 0..n {
        for q in b.nb_start[i] as usize..b.nb_start[i + 1] as usize {
            if seen[q] {
                continue;
            }
            let mut face = Vec::new();
            let mut hs = Vec::new();
            let (mut u, mut qq) = (i, q);
            let mut ok = true;
            for _ in 0..(half + 1) {
                if seen[qq] {
                    ok = qq == q;
                    break;
                }
                seen[qq] = true;
                face.push(u as u32);
                hs.push(qq as u32);
                let v = b.nb[qq].0 as usize;
                let (s, e) = (b.nb_start[v] as usize, b.nb_start[v + 1] as usize);
                let Some(back) = (s..e).find(|&x| b.nb[x].0 as usize == u) else {
                    ok = false;
                    break;
                };
                twin[qq] = back as u32;
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
            halves.push(hs);
            areas.push(0.5 * a);
        }
    }
    let mut out = Faces { faces: Vec::new(), halves: Vec::new(), face_of: vec![NO_FACE; half], twin };
    if faces.is_empty() {
        return out;
    }
    // The outer face: the largest; inner faces wind the other way.
    let mut outer = 0;
    for k in 1..faces.len() {
        if areas[k].abs() > areas[outer].abs() {
            outer = k;
        }
    }
    let sign = areas[outer].signum();
    for &h in &halves[outer] {
        out.face_of[h as usize] = OUTER;
    }
    for (k, (f, hs)) in faces.into_iter().zip(halves).enumerate() {
        if k != outer && areas[k].signum() != sign && areas[k] != 0.0 {
            for &h in &hs {
                out.face_of[h as usize] = out.faces.len() as i32;
            }
            out.faces.push(f);
            out.halves.push(hs);
        }
    }
    out
}

/// One creature's mesh.
///
/// A link is split at its midpoint where a triangle on either side ends there: on the rim
/// (the outline cells' fans end at their links' midpoints) and at a face of mixed types
/// (cut into one quad per cell). A face of one type splits only those of its links, so
/// neighbouring triangles always share whole edges (no T-junction, no pinholes) and the
/// inside of a one-type piece is one triangle per face.
pub fn creature_mesh(b: &Body, types: &[TypeParams; TYPES], border: bool) -> Mesh {
    let mut m = Mesh::default();
    let n = b.n;
    if n == 0 {
        return m;
    }
    let ol = b.outline.len();
    m.reserve(n + 8 * ol, 3 * (2 * n + 6 * ol));
    let tv = |c: usize| b.typ[c] as f32 / 16.0;
    // Every triangle corner at a cell's centre is that cell's colour, inside (UV.x 1): one
    // vertex per cell, shared.
    for c in 0..n {
        m.vert(b.pos[c], 1.0, color_of(types, b.typ[c]), tv(c));
    }
    let fw: &Faces = &b.faces;
    let nf = fw.faces.len();
    // Which faces are drawn (a gap the discs nearly cover is filled, a pocket left open),
    // their centres, and which are of mixed types.
    let mut drawn = vec![true; nf];
    let mut mixed = vec![false; nf];
    let mut centre = vec![Vector2::ZERO; nf];
    for (fi, f) in fw.faces.iter().enumerate() {
        let k = f.len();
        let mut g = Vector2::ZERO;
        let mut rs = 0.0;
        for &c in f {
            g += b.pos[c as usize];
            rs += b.r[c as usize];
        }
        g /= k as f32;
        centre[fi] = g;
        if k > 3 {
            let mut d = f32::INFINITY;
            for &c in f {
                d = d.min((b.pos[c as usize] - g).length() - b.r[c as usize]);
            }
            if d > 0.6 * rs / k as f32 {
                drawn[fi] = false;
            }
        }
        let t0 = b.typ[f[0] as usize];
        mixed[fi] = f.iter().any(|&c| b.typ[c as usize] != t0);
    }
    let split = |h: u32| -> bool {
        let g = fw.face_of[fw.twin[h as usize] as usize];
        g == OUTER || (g >= 0 && drawn[g as usize] && mixed[g as usize])
    };
    let mut poly: Vec<i32> = Vec::with_capacity(16);
    for (fi, f) in fw.faces.iter().enumerate() {
        if !drawn[fi] {
            continue;
        }
        let k = f.len();
        let g = centre[fi];
        if !mixed[fi] {
            let col = color_of(types, b.typ[f[0] as usize]);
            let t = tv(f[0] as usize);
            let hs = &fw.halves[fi];
            poly.clear();
            let mut splits = 0;
            let mut whole_corner = usize::MAX;
            for q in 0..k {
                poly.push(f[q] as i32);
                if split(hs[q]) {
                    let mid = (b.pos[f[q] as usize] + b.pos[f[(q + 1) % k] as usize]) * 0.5;
                    poly.push(m.vert(mid, 1.0, col, t));
                    splits += 1;
                }
            }
            if splits == 0 && k == 3 {
                m.tri_i(poly[0], poly[1], poly[2]);
                continue;
            }
            if k == 3 {
                // A corner whose two links are whole: a fan from it (its triangles never
                // degenerate: the split points lie on the opposite link).
                let mut at = 0;
                for q in 0..3 {
                    if !split(hs[q]) && !split(hs[(q + 2) % 3]) {
                        whole_corner = at;
                    }
                    at += 1 + split(hs[q]) as usize;
                }
            }
            let pl = poly.len();
            if whole_corner != usize::MAX {
                let v = poly[whole_corner];
                for s in 1..pl - 1 {
                    let (a, c) = (poly[(whole_corner + s) % pl], poly[(whole_corner + s + 1) % pl]);
                    m.tri_i(v, a, c);
                }
            } else {
                let gi = m.vert(g, 1.0, col, t);
                for s in 0..pl {
                    m.tri_i(gi, poly[s], poly[(s + 1) % pl]);
                }
            }
            continue;
        }
        for q in 0..k {
            let (cp, c, cn) = (f[(q + k - 1) % k] as usize, f[q] as usize, f[(q + 1) % k] as usize);
            let (mp, mn) = ((b.pos[c] + b.pos[cp]) * 0.5, (b.pos[c] + b.pos[cn]) * 0.5);
            let col = color_of(types, b.typ[c]);
            let (gi, mpi, mni) = (m.vert(g, 1.0, col, tv(c)), m.vert(mp, 1.0, col, tv(c)), m.vert(mn, 1.0, col, tv(c)));
            m.tri_i(c as i32, mni, gi);
            m.tri_i(c as i32, gi, mpi);
            if border && b.typ[c] != b.typ[cn] {
                m.lines.push(mn);
                m.lines.push(g);
            }
        }
    }
    // The rim.
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
                let (i0, i1) = (m.vert(p0, 0.0, col, tv(c)), m.vert(p1, 0.0, col, tv(c)));
                m.tri_i(c as i32, i0, i1);
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
        let mut ri = [0i32; 7];
        for q in 0..7 {
            ri[q] = m.vert(ring[q], uv[q], col, tv(c));
        }
        for q in 0..6 {
            if len_sq(ring[q + 1] - ring[q]) < 1e-12 {
                continue;
            }
            m.tri_i(c as i32, ri[q], ri[q + 1]);
        }
        if border && b.typ[c] != b.typ[cnv] {
            m.lines.push(mn);
            m.lines.push(p2);
        }
    }
    m
}
