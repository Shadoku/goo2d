//! Elasticity lab (ignored tests that print numbers; not part of the suite).
#![cfg(test)]
use crate::cells::*;
use crate::geom::{cross, dot};
use godot::builtin::{Transform2D, Vector2};

const DT: f32 = 1.0 / 60.0;

pub fn game() -> Cells {
    let mut cl = Cells::default();
    let o = &mut cl.opt;
    o.substeps = 6;
    o.stretch_hz = 60.0;
    o.bend_hz = 40.0;
    o.bend_mode = BEND_SHAPE;
    o.shape_k = 0.3;
    o.self_mode = SELF_FAR;
    o.margin = 3.0;
    o.max_speed = 3000.0;
    o.drag.normal = 0.1;
    o.drag.linear_normal = 60.0;
    o.drag.tangent = 0.005;
    o.drag.linear_tangent = 3.0;
    cl
}

pub fn wall_rect(cl: &mut Cells, x: f32, y: f32, w: f32, h: f32) {
    let pts = vec![Vector2::new(0.0, 0.0), Vector2::new(w, 0.0), Vector2::new(w, h), Vector2::new(0.0, h)];
    let id = 1000 + cl.statics.len() as i64;
    cl.add_static_shape(id, Transform2D::from_cols(Vector2::new(1.0, 0.0), Vector2::new(0.0, 1.0), Vector2::new(x, y)), pts, 0.0, 0.0, false);
}

pub fn extent(b: &Body, axis: Vector2) -> f32 {
    let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
    for i in 0..b.n {
        let u = dot(b.pos[i], axis);
        lo = lo.min(u - b.r[i]);
        hi = hi.max(u + b.r[i]);
    }
    hi - lo
}

/// Area of the outline polygon (cell centres).
pub fn area(b: &Body) -> f32 {
    let m = b.outline.len();
    let mut a = 0.0;
    for k in 0..m {
        let p = b.pos[b.outline[k] as usize];
        let q = b.pos[b.outline[(k + 1) % m] as usize];
        a += cross(p, q);
    }
    (a * 0.5).abs()
}

/// Bend: angle between the front third's line and the back third's (by design x).
pub fn bend(b: &Body) -> f32 {
    let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
    for i in 0..b.n {
        lo = lo.min(b.rest_local[i].x);
        hi = hi.max(b.rest_local[i].x);
    }
    let s = hi - lo;
    let mut c = [Vector2::ZERO; 3];
    let mut m = [0.0f32; 3];
    for i in 0..b.n {
        let t = ((b.rest_local[i].x - lo) / s * 3.0).floor().clamp(0.0, 2.0) as usize;
        c[t] += b.pos[i];
        m[t] += 1.0;
    }
    for k in 0..3 {
        c[k] /= m[k];
    }
    let a = c[1] - c[0];
    let bb = c[2] - c[1];
    cross(a, bb).atan2(dot(a, bb))
}

/// The deepest cell behind its rigid fit's place along `dir`, and the RMS deviation.
pub fn dent(b: &Body, dir: Vector2) -> (f32, f32) {
    let c = b.center();
    let t = b.turn_against_rest();
    let (co, si) = (t.cos(), t.sin());
    let mut d = 0.0f32;
    let mut e = 0.0f32;
    for i in 0..b.n {
        let q = b.rest_local[i];
        let g = c + Vector2::new(co * q.x - si * q.y, si * q.x + co * q.y);
        d = d.max(dot(g - b.pos[i], dir));
        e += (g - b.pos[i]).length_squared();
    }
    (d, (e / b.n as f32).sqrt())
}

fn blob_at(cl: &mut Cells, at: Vector2, rings: i32, r: f32, t: u8) -> usize {
    let d = hex_design(rings, r, at);
    cl.add_creature(&d, &vec![r; d.len()], &vec![t; d.len()])
}

fn worm_at(cl: &mut Cells, at: Vector2, long: i32, wide: i32, r: f32) -> usize {
    let d = worm_design(long, wide, r, at);
    cl.add_creature(&d, &vec![r; d.len()], &vec![0; d.len()])
}

type Cfg = Box<dyn Fn(&mut Cells)>;

/// LAB="e,ksoft,beta,stretch,damp;..." or the default sweep.
fn cfgs() -> Vec<(String, Cfg)> {
    let spec = std::env::var("LAB").unwrap_or_else(|_| "0,0.03,0.5,0,0;1,0.03,0.5,0,0;1,0.03,0.5,0,20;1,0.01,0.5,0,20;1,0.03,0.8,0,20;1,0.03,0.5,0.05,20;0.5,0.03,0.5,0,20".to_string());
    let mut v: Vec<(String, Cfg)> = Vec::new();
    for part in spec.split(';') {
        let x: Vec<f32> = part.split(',').map(|t| t.trim().parse().unwrap()).collect();
        let name = format!("e{} lim{:?}", x[0], &x[6.min(x.len())..]);
        v.push((name, Box::new(move |c: &mut Cells| {
            c.opt.elastic = x[0];
            c.opt.el_soft = x[1];
            c.opt.el_damp = x[4];
            c.opt.el_area = x.get(5).copied().unwrap_or(ELASTIC_AREA);
            c.opt.el_limit = x.get(6).copied().unwrap_or(ELASTIC_LIMIT);
        })));
    }
    v
}

fn soundness(cl: &Cells) -> String {
    let h = cl.health();
    format!("cross {:.1} inside {} self {:.1} wall {:.1} bad {}", h[0], h[1], h[2], h[6], h[7])
}

#[test]
#[ignore]
fn lab_blob_pressed() {
    let x = Vector2::new(1.0, 0.0);
    for (name, f) in cfgs() {
        let mut cl = game();
        f(&mut cl);
        wall_rect(&mut cl, 100.0, -200.0, 50.0, 400.0);
        let c = blob_at(&mut cl, Vector2::new(40.0, 0.0), 3, 7.0, 0);
        let a0 = area(&cl.bodies[c]);
        let mut out = String::new();
        let mut peak = 0.0f32;
        for &acc in &[300.0f32, 1000.0, 3000.0] {
            cl.bodies[c].push = Vector2::new(acc, 0.0);
            for _ in 0..120 {
                cl.step(DT);
            }
            let b = &cl.bodies[c];
            let (d, e) = dent(b, x);
            peak = d;
            out += &format!(" a{}: dent {:5.2} rms {:4.2} area {:+5.1}%", acc, d, e, (area(b) / a0 - 1.0) * 100.0);
        }
        cl.bodies[c].push = Vector2::ZERO;
        let mut rec = -1.0;
        for k in 0..300 {
            cl.step(DT);
            let d = dent(&cl.bodies[c], x).0;
            if rec < 0.0 && d < (0.05 * peak).max(0.3) {
                rec = (k + 1) as f32 * DT;
            }
        }
        println!("{:28} {} rec {:.2}s", name, out, rec);
    }
}

#[test]
#[ignore]
fn lab_worm_hit() {
    for (name, f) in cfgs() {
        let mut cl = game();
        f(&mut cl);
        let w = worm_at(&mut cl, Vector2::ZERO, 24, 5, 7.0);
        // A heavy hammer: a 7-cell blob of 7 px, mass ×8 (as a crate), at 300 px/s.
        let d = hex_design(1, 7.0, Vector2::new(0.0, -80.0));
        let h = cl.add_creature_ex(&d, &vec![7.0; d.len()], &vec![1; d.len()], &[], &vec![8.0; d.len()]);
        for i in 0..cl.bodies[h].n {
            cl.bodies[h].vel[i] = Vector2::new(0.0, 300.0);
        }
        let mut peak = 0.0f32;
        let mut t_peak = 0.0;
        let mut straight = -1.0;
        let mut sgn = 0.0f32;
        let mut over = 0.0f32;
        for k in 0..240 {
            cl.step(DT);
            let sb = bend(&cl.bodies[w]);
            if sgn == 0.0 && sb.abs() > 0.05 { sgn = sb.signum(); }
            if sgn != 0.0 { over = over.max(-sb * sgn); }
            let bd = sb.abs();
            if bd > peak {
                peak = bd;
                t_peak = k as f32 * DT;
            }
            if peak > 0.02 && straight < 0.0 && bd < 0.05 * peak && k as f32 * DT > t_peak {
                straight = k as f32 * DT;
            }
        }
        let hl = cl.health();
        println!("{:28} worm bend peak {:6.2}° at {:.2}s straight(5%) {:.2}s overshoot {:.2}° v {:.1} shapeerr {:.3} strain {:.3}", name, peak.to_degrees(), t_peak, straight, over.to_degrees(), cl.bodies[w].velocity().y, hl[4], hl[3]);
    }
}

/// Bend sign changes after the peak (ringing).
#[test]
#[ignore]
fn lab_crash() {
    for (name, f) in cfgs() {
        let mut cl = game();
        f(&mut cl);
        let a = blob_at(&mut cl, Vector2::new(-60.0, 0.0), 3, 7.0, 0);
        let b = blob_at(&mut cl, Vector2::new(60.0, 0.0), 3, 7.0, 0);
        for i in 0..cl.bodies[a].n {
            cl.bodies[a].vel[i] = Vector2::new(600.0, 0.0);
            cl.bodies[b].vel[i] = Vector2::new(-600.0, 0.0);
        }
        let a0 = area(&cl.bodies[a]);
        let (mut peak, mut amin, mut worst) = (0.0f32, 1.0f32, String::new());
        let mut inside_max = 0.0f32;
        for _ in 0..120 {
            cl.step(DT);
            peak = peak.max(dent(&cl.bodies[a], Vector2::new(1.0, 0.0)).0);
            amin = amin.min(area(&cl.bodies[a]) / a0);
            let h = cl.health();
            if h[1] > inside_max {
                inside_max = h[1];
                worst = soundness(&cl);
            }
        }
        println!("{:28} crash 600+600: dent {:5.2} area min {:+.1}% end dent {:.2} inside max {} {}", name, peak, (amin - 1.0) * 100.0, dent(&cl.bodies[a], Vector2::new(1.0, 0.0)).0, inside_max, worst);
    }
}

#[test]
#[ignore]
fn lab_worm_nose() {
    for (name, f) in cfgs() {
        let mut cl = game();
        f(&mut cl);
        wall_rect(&mut cl, 250.0, -300.0, 50.0, 600.0);
        let w = worm_at(&mut cl, Vector2::ZERO, 24, 5, 7.0);
        for i in 0..cl.bodies[w].n {
            cl.bodies[w].vel[i] = Vector2::new(600.0, 30.0);
        }
        let mut peak = 0.0f32;
        let mut sh = 0.0f32;
        for _ in 0..120 {
            cl.step(DT);
            peak = peak.max(bend(&cl.bodies[w]).abs());
            sh = sh.max(cl.bodies[w].shape_error());
        }
        println!("{:28} worm nose 600: bend peak {:5.1}° shape err max {:.3} end bend {:.1}° {}", name, peak.to_degrees(), sh, bend(&cl.bodies[w]).abs().to_degrees(), soundness(&cl));
    }
}

/// A blob (37 cells, 7 px) pushed at 600 px/s² into a gap of the given width ratio.
#[test]
#[ignore]
fn lab_gap() {
    for (name, f) in cfgs() {
        let mut out = String::new();
        for &(ratio, push) in &[(0.9f32, 1000.0f32), (0.8, 1000.0), (0.8, 3000.0), (0.6, 3000.0)] {
            let mut cl = game();
            f(&mut cl);
            let c = blob_at(&mut cl, Vector2::ZERO, 3, 7.0, 0);
            let wdt = extent(&cl.bodies[c], Vector2::new(0.0, 1.0));
            let g = wdt * ratio;
            wall_rect(&mut cl, 100.0, -400.0, 30.0, 400.0 - g * 0.5);
            wall_rect(&mut cl, 100.0, g * 0.5, 30.0, 400.0);
            cl.bodies[c].push = Vector2::new(push, 0.0);
            let mut through = -1.0;
            for k in 0..600 {
                cl.step(DT);
                if through < 0.0 && cl.bodies[c].pos.iter().all(|p| p.x > 140.0) {
                    through = (k + 1) as f32 * DT;
                }
            }
            out += &format!(" {:.1}@{}: {:.2}s", ratio, push, through);
            let h = cl.health();
            out += &format!(" (in {} self {:.1} err {:.2})", h[1], h[2], cl.bodies[c].shape_error());
        }
        println!("{:28} gap {}", name, out);
    }
}

/// The worm swimming 10 s by the pose wave and the drive: shape error, speed.
#[test]
#[ignore]
fn lab_swim() {
    for (name, f) in cfgs() {
        let mut cl = game();
        f(&mut cl);
        let w = worm_at(&mut cl, Vector2::ZERO, 24, 5, 7.0);
        let b = &mut cl.bodies[w];
        let len = 24.0 * 14.0;
        b.wave = Wave { mode: WAVE_POSE, amp: 0.3 / (std::f32::consts::TAU / len), k: std::f32::consts::TAU / len, omega: std::f32::consts::TAU, axis: Vector2::new(1.0, 0.0), half_width: 30.0, bias: 0.0, envelope: 0.6, phase: 0.0, age: 0.0 };
        b.swim = Swim { acc: 55.0, pulse: 0.3, axis: Vector2::new(1.0, 0.0) };
        let mut x0 = 0.0;
        let mut errmax = 0.0f32;
        for k in 0..600 {
            cl.step(DT);
            if k == 120 {
                x0 = cl.bodies[w].center().x;
            }
            errmax = errmax.max(cl.bodies[w].shape_error());
        }
        let v = (cl.bodies[w].center().x - x0) / 8.0;
        cl.bodies[w].wave.mode = WAVE_OFF;
        cl.bodies[w].swim.acc = 0.0;
        for _ in 0..60 { cl.step(DT); }
        println!("{:28} swim: {:.1} px/s, shape err max {:.3} after stop {:.4} {}", name, v, errmax, cl.bodies[w].shape_error(), soundness(&cl));
    }
}

fn spin_toward(err: f32, max_spin: f32, acc: f32, dt: f32) -> f32 {
    let mut s = err.signum() * max_spin.min((2.0 * acc * err.abs()).sqrt());
    if dt > 0.0 {
        let lim = err.abs() / dt;
        s = s.clamp(-lim, lim);
    }
    s
}

/// Half turns of the ship (10 × 5), the worm (24 × 5), the boss worm (24 × 5 of 14 px)
/// and a blob (37): LAB2="e,lead;..." (elastic soft 0.003, area 0.3).
#[test]
#[ignore]
fn lab_turn() {
    let spec = std::env::var("LAB2").unwrap_or_else(|_| "0,0;0.6,0;0.6,0.5;0.6,1".to_string());
    for part in spec.split(';') {
        let x: Vec<f32> = part.split(',').map(|t| t.trim().parse().unwrap()).collect();
        for &(name, long, wide, r, rings) in &[("ship", 10, 5, 7.0f32, 0), ("worm", 24, 5, 7.0, 0), ("boss", 24, 5, 14.0, 0), ("blob37", 0, 0, 7.0, 3)] {
            for &(angle, swim) in &[(std::f32::consts::PI, 0.0f32), (std::f32::consts::PI, 1.0), (std::f32::consts::FRAC_PI_2, 1.0)] {
                let mut cl = game();
                cl.opt.elastic = x[0];
                cl.opt.el_limit = x.get(2).copied().unwrap_or(ELASTIC_LIMIT);
                cl.opt.el_damp = x.get(5).copied().unwrap_or(0.0);

                let c = if rings > 0 { blob_at(&mut cl, Vector2::ZERO, rings, r, 0) } else { worm_at(&mut cl, Vector2::ZERO, long, wide, r) };
                let size = { let b = &cl.bodies[c]; extent(b, Vector2::new(1.0, 0.0)) };
                let tt = 0.25 + ((size - 84.0) / (690.0 - 84.0)).clamp(0.0, 1.0) * 0.75;
                let pace = tt + 0.09;
                let max_spin = 4.77 / pace;
                let acc = max_spin / (0.05 * pace);
                // Swimming: the drive at about 2.4 body lengths a second for the ship... a modest 300 px/s² push forward.
                if swim > 0.0 {
                    cl.bodies[c].swim = Swim { acc: 400.0 * swim, pulse: 0.0, axis: Vector2::new(1.0, 0.0) };
                    for _ in 0..90 { cl.step(DT); }
                }
                let b = &mut cl.bodies[c];
                b.servo = SpinServo { on: true, target: 0.0, max_acc: acc, lead: x[1], ..Default::default() };
                let start = b.turn_against_rest();
                let mut cont = start;
                let c0 = b.center();
                let v0 = b.velocity();
                let goal = start + angle;
                let (mut t_face, mut over, mut bmax, mut dev) = (-1.0f32, 0.0f32, 0.0f32, 0.0f32);
                let mut head_first = 0.0f32;
                let mut late = 0.0f32;
                let mut smax = 0.0f32;
                let mut whip = 0.0f32;
                for k in 0..150 {
                    let b = &mut cl.bodies[c];
                    let tr = b.turn_against_rest();
                    cont += { let mut d = tr - cont; while d > std::f32::consts::PI { d -= std::f32::consts::TAU; } while d < -std::f32::consts::PI { d += std::f32::consts::TAU; } d };
                    let err = goal - cont;
                    b.servo.target = spin_toward(err, max_spin, 0.8 * acc, DT);
                    cl.step(DT);
                    let b = &cl.bodies[c];
                    let tr = b.turn_against_rest();
                    let mut d = tr - cont; while d > std::f32::consts::PI { d -= std::f32::consts::TAU; } while d < -std::f32::consts::PI { d += std::f32::consts::TAU; }
                    let e2 = goal - (cont + d);
                    if k == 149 { late = e2; }
                    if t_face < 0.0 && e2.abs() < 5f32.to_radians() { t_face = (k + 1) as f32 * DT; }
                    if t_face >= 0.0 { over = over.max(-e2 * angle.signum()); }
                    let bd = bend(b);
                    bmax = bmax.max(bd.abs());
                    whip = whip.min(bd * angle.signum());
                    smax = smax.max(cl.health()[3]);
                    if k < 10 { head_first = head_first.max(bd * angle.signum()); }
                    // The centre's path off the straight line it was on.
                    let p = b.center() - c0;
                    let vn = if v0.length() > 1.0 { v0.normalized() } else { Vector2::new(1.0, 0.0) };
                    dev = dev.max(cross(vn, p).abs());
                }
                let lu = cl.bodies[c].servo.lead_used;
                println!("e{} lead{} {:6} {:3.0}° swim{} T{:.2}: face {:.2}s over {:4.1}° end err {:5.2}° bend max {:5.1}° whip {:5.1}° early {:+5.1}° path off {:5.1}px strain {:.3} lead_used {:.2} {}", x[0], x[1], name, angle.to_degrees(), swim, tt, t_face, over.to_degrees(), late.to_degrees(), bmax.to_degrees(), whip.to_degrees(), head_first.to_degrees(), dev, smax, lu, soundness(&cl));
            }
        }
    }
}

/// Where the worst strain is in a worm's servo turn at elasticity 0.65.
#[test]
#[ignore]
fn lab_turn_strain() {
    for &(e, passes) in &[(0.0f32, 1usize), (0.65, 2)] {
        let mut cl = game();
        cl.opt.elastic = e;
        let c = worm_at(&mut cl, Vector2::ZERO, 24, 5, 7.0);
        let b = &mut cl.bodies[c];
        b.servo = SpinServo { on: true, target: 7.2, max_acc: 217.0, ..Default::default() };
        let mut worst = (0.0f32, 0usize, 0usize, 0usize);
        for k in 0..30 {
            cl.step(DT);
            let b = &cl.bodies[c];
            for l in &b.links {
                let s = (b.pos[l.j as usize] - b.pos[l.i as usize]).length() / l.rest - 1.0;
                if s.abs() > worst.0.abs() {
                    worst = (s, l.i as usize, l.j as usize, k);
                }
            }
        }
        let b = &cl.bodies[c];
        let mut hist = [0usize; 6];
        for l in &b.links {
            let s = ((b.pos[l.j as usize] - b.pos[l.i as usize]).length() / l.rest - 1.0).abs();
            let k = if s < 0.01 { 0 } else if s < 0.03 { 1 } else if s < 0.1 { 2 } else if s < 0.3 { 3 } else if s < 0.6 { 4 } else { 5 };
            hist[k] += 1;
        }
        println!("passes {} e{} worst strain {:.3} link {}-{} (rest {:?} {:?}, boundary {} {}) frame {}; spinning at end: strain histogram <1%,<3%,<10%,<30%,<60%,more {:?}; rest of that link {:.2} design {:.2}", passes, e, worst.0, worst.1, worst.2, b.rest_local[worst.1], b.rest_local[worst.2], b.boundary[worst.1], b.boundary[worst.2], worst.3, hist, b.links.iter().find(|l| l.i as usize == worst.1 && l.j as usize == worst.2).map(|l| l.rest).unwrap_or(0.0), b.links.iter().find(|l| l.i as usize == worst.1 && l.j as usize == worst.2).map(|l| l.d_design).unwrap_or(0.0));
    }
}

#[test]
#[ignore]
fn lab_turn_series() {
    let mut cl = game();
    cl.opt.elastic = 0.65;
    cl.opt.el_limit = 0.06;
    let c = worm_at(&mut cl, Vector2::ZERO, 24, 5, 7.0);
    cl.opt.el_damp = std::env::var("DAMP").map(|s| s.parse().unwrap()).unwrap_or(0.0);
    let lead: f32 = std::env::var("LEAD").map(|s| s.parse().unwrap()).unwrap_or(1.0);
    cl.bodies[c].servo = SpinServo { on: true, target: 0.0, max_acc: 217.0, lead, ..Default::default() };
    let goal = std::f32::consts::PI;
    let mut cont = 0.0f32;
    for k in 0..60 {
        let b = &mut cl.bodies[c];
        let tr = if std::env::var("HEAD").is_ok() { head_turn(b) } else { b.turn_against_rest() };
        let mut d = tr - cont;
        while d > std::f32::consts::PI { d -= std::f32::consts::TAU; }
        while d < -std::f32::consts::PI { d += std::f32::consts::TAU; }
        cont += d;
        b.servo.target = spin_toward(goal - cont, 7.2, 0.8 * 217.0, DT);
        if std::env::var("FREE").is_ok() && k >= 28 { b.servo.on = false; b.servo.target = 0.0; if k == 28 { let c0 = b.center(); let v0 = b.velocity(); let w = b.spin(); for i in 0..b.n { let p = b.pos[i] - c0; b.vel[i] -= Vector2::new(-p.y, p.x) * w; let _ = v0; } } }
        cl.step(DT);
        let b = &cl.bodies[c];
        if k % 2 == 0 {
            println!("t {:.3} turn {:6.1}° spin {:5.2} target {:5.2} bend {:6.1}°", (k + 1) as f32 * DT, cont.to_degrees(), b.spin(), b.servo.target, bend(b).to_degrees());
        }
    }
}

/// The best-fit turn of the front half (design x above the middle) against the design.
pub fn head_turn(b: &Body) -> f32 {
    let (mut lo, mut hi) = (f32::INFINITY, f32::NEG_INFINITY);
    for i in 0..b.n { lo = lo.min(b.rest_local[i].x); hi = hi.max(b.rest_local[i].x); }
    let mid = 0.5 * (lo + hi);
    let (mut c, mut q0, mut m) = (Vector2::ZERO, Vector2::ZERO, 0.0f32);
    for i in 0..b.n { if b.rest_local[i].x > mid { c += b.pos[i]; q0 += b.rest_local[i]; m += 1.0; } }
    c /= m; q0 /= m;
    let (mut sc, mut ss) = (0.0f32, 0.0f32);
    for i in 0..b.n { if b.rest_local[i].x > mid { let p = b.pos[i] - c; let q = b.rest_local[i] - q0; sc += dot(q, p); ss += cross(q, p); } }
    ss.atan2(sc)
}
