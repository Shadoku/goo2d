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
    /// The goo mesh's cell table, CELL_FLOATS per cell (creature_mesh_goo()).
    pub cells: Vec<f32>,
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
        self.cells.extend(o.cells);
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

// --- The goo skin's mesh (goo_cells_goo.gdshader) -------------------------------------
//
// Every triangle names three cells, the same three on each of its corners, so a fragment
// knows which three cells it lies among and fetches their centres, radii, turns, types and
// seeds from the world's cell table (cell_data(), a texture the world updates each frame):
// from them it works out the power diagram's walls exactly (the honeycomb, a constant
// width in px at any size), which cell it is in, a coordinate fixed in that cell, and the
// types' blend. Vertices are shared within a face or a rim fan (one triple), not across.
//
// Per vertex: COLOR = (cell a, cell b, cell c, distance to the outline in px), the cells'
// indices into the table (global over the world's creatures); a rim fan's third index is
// stored as −(index + 1), telling the shader to blend its types along the two links (a
// projection) instead of by barycentric coordinates. UV = the outward direction (toward
// the nearest point of the outline; the curve's normal on the skin).

/// Floats per cell in the table: (x, y, radius, turn), (type slot, seed 0..1, distance
/// to the outline px, 1 on the outline else 0).
pub const CELL_FLOATS: usize = 8;

/// A cell's seed in 0..1 from its uid (stable while the cell lives).
#[inline]
pub fn cell_seed(uid: u32) -> f32 {
    let h = uid.wrapping_mul(2654435761).wrapping_add(0x9e3779b9).rotate_left(13).wrapping_mul(0x85ebca6b);
    (h >> 8) as f32 / (1u32 << 24) as f32
}

/// Per cell: its distance to the skin (px, at its centre) and the direction toward the
/// skin's nearest point. `skin` is the closed skin polyline.
pub fn outline_distances(b: &Body, skin: &[Vector2]) -> (Vec<f32>, Vec<Vector2>) {
    let n = b.n;
    let mut d = vec![f32::INFINITY; n];
    let mut dir = vec![Vector2::new(0.0, -1.0); n];
    let m = skin.len();
    if m < 3 {
        for c in 0..n {
            d[c] = b.r[c];
        }
        return (d, dir);
    }
    let mut near = vec![usize::MAX; n];
    let seg = |j: usize, p: Vector2| -> (f32, Vector2) {
        let a = skin[j % m];
        let e = skin[(j + 1) % m] - a;
        let l2 = len_sq(e);
        let s = if l2 > 1e-12 { ((p - a).dot(e) / l2).clamp(0.0, 1.0) } else { 0.0 };
        let q = a + e * s;
        ((q - p).length(), q)
    };
    let per = (m / b.outline.len().max(1)).max(1);
    let mut queue: Vec<usize> = Vec::with_capacity(n);
    let mut seen = vec![false; n];
    // The outline cells: their own stretch of the skin and the next ones'.
    for (k, &c) in b.outline.iter().enumerate() {
        let c = c as usize;
        let p = b.pos[c];
        for o in 0..(4 * per) {
            let j = (k * per + m + o - 2 * per) % m;
            let (dist, q) = seg(j, p);
            if dist < d[c] {
                d[c] = dist;
                near[c] = j;
                let v = q - p;
                if v.length() > 1e-6 {
                    dir[c] = v / v.length();
                }
            }
        }
        if !seen[c] {
            seen[c] = true;
            queue.push(c);
        }
    }
    // Inward, breadth first: each cell tries the segments its neighbours found nearest.
    let mut h = 0;
    while h < queue.len() {
        let u = queue[h];
        h += 1;
        for q in b.nb_start[u] as usize..b.nb_start[u + 1] as usize {
            let v = b.nb[q].0 as usize;
            if seen[v] {
                continue;
            }
            seen[v] = true;
            let p = b.pos[v];
            for w in b.nb_start[v] as usize..b.nb_start[v + 1] as usize {
                let x = b.nb[w].0 as usize;
                if near[x] == usize::MAX {
                    continue;
                }
                for o in 0..(2 * per + 1) {
                    let j = (near[x] + m + o - per) % m;
                    let (dist, qp) = seg(j, p);
                    if dist < d[v] {
                        d[v] = dist;
                        near[v] = j;
                        let vv = qp - p;
                        if vv.length() > 1e-6 {
                            dir[v] = vv / vv.length();
                        }
                    }
                }
            }
            queue.push(v);
        }
    }
    for c in 0..n {
        if !d[c].is_finite() {
            d[c] = b.r[c];
        }
    }
    (d, dir)
}

/// The skin curve as a closed polyline: per outline cell four points of its quadratic
/// B-spline (through the outline surface's midpoints, `surf` its control points).
fn skin_curve(surf: &[Vector2], mid_s: &[Vector2]) -> Vec<Vector2> {
    let ol = surf.len();
    let mut skin: Vec<Vector2> = Vec::with_capacity(4 * ol);
    for k in 0..ol {
        let (p0, p1, p2) = (mid_s[(k + ol - 1) % ol], surf[k], mid_s[k]);
        for t in [0.0f32, 0.25, 0.5, 0.75] {
            skin.push(p0 * ((1.0 - t) * (1.0 - t)) + p1 * (2.0 * t * (1.0 - t)) + p2 * (t * t));
        }
    }
    skin
}

/// A creature's skin curve (as the goo mesh draws it), for the tests.
#[allow(dead_code)]
pub fn goo_skin(b: &Body) -> Vec<Vector2> {
    let ol = b.outline.len();
    if ol < 3 {
        return Vec::new();
    }
    let surf: Vec<Vector2> = (0..ol).map(|k| b.pos[b.outline[k] as usize] + outward(b, k) * b.r[b.outline[k] as usize]).collect();
    let mid_s: Vec<Vector2> = (0..ol).map(|k| (surf[k] + surf[(k + 1) % ol]) * 0.5).collect();
    skin_curve(&surf, &mid_s)
}

/// The goo skin's mesh of one creature (see above) and its rows of the cell table.
/// `base` is the creature's first cell's index in the world's table.
pub fn creature_mesh_goo(b: &Body, base: u32, border: bool) -> Mesh {
    let mut m = Mesh::default();
    let n = b.n;
    if n == 0 {
        return m;
    }
    let ol = b.outline.len();
    m.reserve(6 * n + 8 * ol, 3 * (2 * n + 6 * ol));
    // The rim's geometry first: the skin curve, which the distances are measured to.
    let surf: Vec<Vector2> = if ol >= 3 {
        (0..ol).map(|k| {
            let c = b.outline[k] as usize;
            b.pos[c] + outward(b, k) * b.r[c]
        }).collect()
    } else {
        Vec::new()
    };
    let mid_s: Vec<Vector2> = (0..surf.len()).map(|k| (surf[k] + surf[(k + 1) % ol]) * 0.5).collect();
    const TS: [f32; 5] = [0.0, 0.25, 0.5, 0.75, 1.0];
    let skin = skin_curve(&surf, &mid_s);
    let (dist, dir) = outline_distances(b, &skin);
    // The cell table's rows.
    m.cells.reserve(CELL_FLOATS * n);
    for c in 0..n {
        m.cells.extend_from_slice(&[b.pos[c].x, b.pos[c].y, b.r[c], b.th[c], b.typ[c] as f32, cell_seed(b.uid[c]), dist[c], b.boundary[c] as u8 as f32]);
    }
    let gi = |c: usize| (base as usize + c) as f32;
    let attr = |t: [usize; 3], rim: bool, d: f32| -> Color {
        let z = if rim { -gi(t[2]) - 1.0 } else { gi(t[2]) };
        Color::from_rgba(gi(t[0]), gi(t[1]), z, d)
    };
    let vert = |m: &mut Mesh, p: Vector2, a: Color, o: Vector2| -> i32 {
        m.points.push(p);
        m.colors.push(a);
        m.uvs.push(o);
        m.points.len() as i32 - 1
    };
    let avg_dir = |a: Vector2, c: Vector2| -> Vector2 {
        let s = a + c;
        if s.length() > 1e-6 { s / s.length() } else { a }
    };
    let fw: &Faces = &b.faces;
    let nf = fw.faces.len();
    let mut drawn = vec![true; nf];
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
            let mut dd = f32::INFINITY;
            for &c in f {
                dd = dd.min((b.pos[c as usize] - g).length() - b.r[c as usize]);
            }
            if dd > 0.6 * rs / k as f32 {
                drawn[fi] = false;
            }
        }
    }
    // A link is split at its midpoint only on the rim (where the outline fans end).
    let split = |h: u32| -> bool { fw.face_of[fw.twin[h as usize] as usize] == OUTER };
    let mut poly: Vec<i32> = Vec::with_capacity(16);
    for (fi, f) in fw.faces.iter().enumerate() {
        if !drawn[fi] {
            continue;
        }
        let k = f.len();
        let g = centre[fi];
        let hs = &fw.halves[fi];
        if k == 3 {
            let t = [f[0] as usize, f[1] as usize, f[2] as usize];
            poly.clear();
            let mut splits = 0;
            for q in 0..3 {
                let c = t[q];
                poly.push(vert(&mut m, b.pos[c], attr(t, false, dist[c]), dir[c]));
                if split(hs[q]) {
                    let cn = t[(q + 1) % 3];
                    let mid = (b.pos[c] + b.pos[cn]) * 0.5;
                    poly.push(vert(&mut m, mid, attr(t, false, 0.5 * (dist[c] + dist[cn])), avg_dir(dir[c], dir[cn])));
                    splits += 1;
                }
            }
            if splits == 0 {
                m.tri_i(poly[0], poly[1], poly[2]);
            } else {
                // A fan from a corner whose two links are whole, else from the centre.
                let mut whole = usize::MAX;
                let mut at = 0;
                for q in 0..3 {
                    if !split(hs[q]) && !split(hs[(q + 2) % 3]) {
                        whole = at;
                    }
                    at += 1 + split(hs[q]) as usize;
                }
                let pl = poly.len();
                if whole != usize::MAX {
                    let v = poly[whole];
                    for s in 1..pl - 1 {
                        m.tri_i(v, poly[(whole + s) % pl], poly[(whole + s + 1) % pl]);
                    }
                } else {
                    let dg = (dist[t[0]] + dist[t[1]] + dist[t[2]]) / 3.0;
                    let og = avg_dir(avg_dir(dir[t[0]], dir[t[1]]), dir[t[2]]);
                    let gv = vert(&mut m, g, attr(t, false, dg), og);
                    for s in 0..pl {
                        m.tri_i(gv, poly[s], poly[(s + 1) % pl]);
                    }
                }
            }
            if border {
                for q in 0..3 {
                    let (c, cn) = (t[q], t[(q + 1) % 3]);
                    if b.typ[c] != b.typ[cn] {
                        m.lines.push((b.pos[c] + b.pos[cn]) * 0.5);
                        m.lines.push(g);
                    }
                }
            }
            continue;
        }
        // A larger face (a gap the discs nearly cover): a fan from its centre, each
        // triangle naming its two cells and the face's other cell nearest the centre.
        let mut dg = 0.0;
        let mut og = Vector2::ZERO;
        for &c in f {
            dg += dist[c as usize];
            og += dir[c as usize];
        }
        dg /= k as f32;
        let og = if og.length() > 1e-6 { og / og.length() } else { Vector2::new(0.0, -1.0) };
        for q in 0..k {
            let (c, cn) = (f[q] as usize, f[(q + 1) % k] as usize);
            let mut third = c;
            let mut best = f32::INFINITY;
            for &x in f {
                let x = x as usize;
                if x != c && x != cn {
                    let e = (b.pos[x] - g).length() - b.r[x];
                    if e < best {
                        best = e;
                        third = x;
                    }
                }
            }
            let t = [c, cn, third];
            let gv = vert(&mut m, g, attr(t, false, dg), og);
            let cv = vert(&mut m, b.pos[c], attr(t, false, dist[c]), dir[c]);
            let nv = vert(&mut m, b.pos[cn], attr(t, false, dist[cn]), dir[cn]);
            if split(hs[q]) {
                let mid = (b.pos[c] + b.pos[cn]) * 0.5;
                let mv = vert(&mut m, mid, attr(t, false, 0.5 * (dist[c] + dist[cn])), avg_dir(dir[c], dir[cn]));
                m.tri_i(gv, cv, mv);
                m.tri_i(gv, mv, nv);
            } else {
                m.tri_i(gv, cv, nv);
            }
            if border && b.typ[c] != b.typ[cn] {
                m.lines.push((b.pos[c] + b.pos[cn]) * 0.5);
                m.lines.push(g);
            }
        }
    }
    // The rim.
    if ol < 3 {
        for (k, &c) in b.outline.iter().enumerate() {
            let c = c as usize;
            let other = b.outline[(k + 1) % ol] as usize;
            let t = [c, other, other];
            const SIDES: usize = 16;
            let cv = vert(&mut m, b.pos[c], attr(t, true, b.r[c]), Vector2::new(0.0, -1.0));
            let mut ring = [0i32; SIDES];
            for s in 0..SIDES {
                let a = std::f32::consts::TAU * s as f32 / SIDES as f32;
                let o = Vector2::new(a.cos(), a.sin());
                ring[s] = vert(&mut m, b.pos[c] + o * b.r[c], attr(t, true, 0.0), o);
            }
            for s in 0..SIDES {
                m.tri_i(cv, ring[s], ring[(s + 1) % SIDES]);
            }
        }
        return m;
    }
    for k in 0..ol {
        let kp = (k + ol - 1) % ol;
        let kn = (k + 1) % ol;
        let c = b.outline[k] as usize;
        let (cpv, cnv) = (b.outline[kp] as usize, b.outline[kn] as usize);
        let t = [c, cpv, cnv];
        let pc = b.pos[c];
        let (p0, p1, p2) = (mid_s[kp], surf[k], mid_s[k]);
        let bz = |s: f32| p0 * ((1.0 - s) * (1.0 - s)) + p1 * (2.0 * s * (1.0 - s)) + p2 * (s * s);
        // The curve's outward normal: its tangent turned toward the cell's outside.
        let out_k = outward(b, k);
        let normal = |s: f32| -> Vector2 {
            let tg = (p1 - p0) * (2.0 * (1.0 - s)) + (p2 - p1) * (2.0 * s);
            let l = tg.length();
            if l < 1e-6 {
                return out_k;
            }
            let nn = Vector2::new(-tg.y, tg.x) / l;
            if nn.dot(out_k) < 0.0 { -nn } else { nn }
        };
        let cv = vert(&mut m, pc, attr(t, true, dist[c]), dir[c]);
        let mpv = vert(&mut m, (pc + b.pos[cpv]) * 0.5, attr(t, true, 0.5 * (dist[c] + dist[cpv])), avg_dir(dir[c], dir[cpv]));
        let mnv = vert(&mut m, (pc + b.pos[cnv]) * 0.5, attr(t, true, 0.5 * (dist[c] + dist[cnv])), avg_dir(dir[c], dir[cnv]));
        let mut ring = [0i32; 7];
        ring[0] = mpv;
        for (q, &s) in TS.iter().enumerate() {
            ring[q + 1] = vert(&mut m, bz(s), attr(t, true, 0.0), normal(s));
        }
        ring[6] = mnv;
        let pts = [(pc + b.pos[cpv]) * 0.5, p0, bz(0.25), bz(0.5), bz(0.75), p2, (pc + b.pos[cnv]) * 0.5];
        for q in 0..6 {
            if len_sq(pts[q + 1] - pts[q]) < 1e-12 {
                continue;
            }
            m.tri_i(cv, ring[q], ring[q + 1]);
        }
        if border && b.typ[c] != b.typ[cnv] {
            m.lines.push((pc + b.pos[cnv]) * 0.5);
            m.lines.push(p2);
        }
    }
    m
}

/// What the shader works out at `p` among a triangle's three cells (for the tests: keep
/// it in step with goo_cells_goo.gdshader's `cells_at()`): the cell it lies in (0..2) and
/// its distance in px to that cell's nearest wall among the other two (the power
/// diagram's: |p − c|² − r² equal on both sides).
#[allow(dead_code)]
pub fn wall_distance(p: Vector2, c: [Vector2; 3], r: [f32; 3]) -> (usize, f32) {
    let pw = |i: usize| len_sq(p - c[i]) - r[i] * r[i];
    let mut o = 0;
    for i in 1..3 {
        if pw(i) < pw(o) {
            o = i;
        }
    }
    let mut w = f32::INFINITY;
    for i in 0..3 {
        let l = (c[i] - c[o]).length();
        if i == o || l < 1e-4 {
            continue;
        }
        w = w.min((pw(i) - pw(o)) / (2.0 * l));
    }
    (o, w)
}
