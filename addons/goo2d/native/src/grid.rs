//! The broad phase of particle-particle contacts: a hashed uniform grid, rebuilt every
//! substep by a counting sort (no allocation once warm). A cell is the largest bead
//! diameter, so a particle's contacts lie in its own cell and the eight around it.

use godot::builtin::Vector2;

#[derive(Default)]
pub struct Grid {
    inv: f32,
    mask: usize,
    /// Per bucket, where its particles start in `items` (one more entry than buckets).
    pub start: Vec<u32>,
    /// Particle indices, bucket by bucket.
    pub items: Vec<u32>,
    /// Each particle's cell.
    pub cells: Vec<(i32, i32)>,
    cursor: Vec<u32>,
}

#[inline]
pub fn hash(cx: i32, cy: i32) -> usize {
    ((cx as u32).wrapping_mul(73_856_093) ^ (cy as u32).wrapping_mul(19_349_663)) as usize
}

impl Grid {
    #[inline]
    pub fn cell_of(&self, p: Vector2) -> (i32, i32) {
        ((p.x * self.inv).floor() as i32, (p.y * self.inv).floor() as i32)
    }

    #[inline]
    pub fn bucket(&self, cx: i32, cy: i32) -> usize {
        hash(cx, cy) & self.mask
    }

    /// Sorts the particles at `pos` into cells of `cell` px.
    pub fn build(&mut self, pos: &[Vector2], cell: f32) {
        let n = pos.len();
        self.inv = 1.0 / cell.max(0.001);
        let table = (2 * n).next_power_of_two().max(64);
        self.mask = table - 1;
        self.start.clear();
        self.start.resize(table + 1, 0);
        self.cells.clear();
        for &p in pos {
            let c = self.cell_of(p);
            self.cells.push(c);
            let b = self.bucket(c.0, c.1);
            self.start[b + 1] += 1;
        }
        for b in 0..table {
            self.start[b + 1] += self.start[b];
        }
        self.cursor.clear();
        self.cursor.extend_from_slice(&self.start[..table]);
        self.items.clear();
        self.items.resize(n, 0);
        for (i, &(cx, cy)) in self.cells.iter().enumerate() {
            let b = hash(cx, cy) & self.mask;
            self.items[self.cursor[b] as usize] = i as u32;
            self.cursor[b] += 1;
        }
    }
}

/// A dense uniform grid over the points' bounding box (explore-frozen): particles
/// counting-sorted by cell, so the three cells of a row next to each other are one
/// contiguous run of `items` (no hashing, no floor call: positions are offset to the
/// box's corner, so truncation is floor).
#[derive(Default)]
pub struct DenseGrid {
    pub inv: f32,
    pub min: Vector2,
    pub nx: i32,
    pub ny: i32,
    /// Per cell, where its particles start in `items` (one more entry than cells).
    pub start: Vec<u32>,
    pub items: Vec<u32>,
    /// Each particle's cell (x, y).
    pub cells: Vec<(i32, i32)>,
    cursor: Vec<u32>,
}

impl DenseGrid {
    #[inline]
    pub fn cell_of(&self, p: Vector2) -> (i32, i32) {
        let x = ((p.x - self.min.x) * self.inv).max(0.0) as i32;
        let y = ((p.y - self.min.y) * self.inv).max(0.0) as i32;
        (x.min(self.nx - 1), y.min(self.ny - 1))
    }

    /// Sorts `pos` into cells of `cell` px over their box grown by `pad`. Returns false
    /// (nothing built) when the box would need more than `max_cells` cells.
    pub fn build(&mut self, pos: &[Vector2], cell: f32, pad: f32, max_cells: usize) -> bool {
        let n = pos.len();
        if n == 0 {
            self.nx = 1;
            self.ny = 1;
            self.start.clear();
            self.start.resize(2, 0);
            self.items.clear();
            self.cells.clear();
            return true;
        }
        let (mut lo, mut hi) = (pos[0], pos[0]);
        for &p in pos {
            lo = Vector2::new(lo.x.min(p.x), lo.y.min(p.y));
            hi = Vector2::new(hi.x.max(p.x), hi.y.max(p.y));
        }
        let cell = cell.max(0.001);
        self.inv = 1.0 / cell;
        self.min = lo - Vector2::new(pad, pad);
        let nx = (((hi.x - self.min.x + pad) * self.inv) as i64 + 1).max(1);
        let ny = (((hi.y - self.min.y + pad) * self.inv) as i64 + 1).max(1);
        if (nx * ny) as usize > max_cells {
            return false;
        }
        self.nx = nx as i32;
        self.ny = ny as i32;
        let total = (nx * ny) as usize;
        self.start.clear();
        self.start.resize(total + 1, 0);
        self.cells.clear();
        for &p in pos {
            let c = self.cell_of(p);
            self.cells.push(c);
            self.start[(c.0 + c.1 * self.nx) as usize + 1] += 1;
        }
        for b in 0..total {
            self.start[b + 1] += self.start[b];
        }
        self.cursor.clear();
        self.cursor.extend_from_slice(&self.start[..total]);
        self.items.clear();
        self.items.resize(n, 0);
        for (i, &(cx, cy)) in self.cells.iter().enumerate() {
            let b = (cx + cy * self.nx) as usize;
            self.items[self.cursor[b] as usize] = i as u32;
            self.cursor[b] += 1;
        }
        true
    }

    /// The run of `items` in row `y` from column x0 to x1 (clamped); empty off the grid.
    #[inline]
    pub fn row(&self, y: i32, x0: i32, x1: i32) -> std::ops::Range<usize> {
        if y < 0 || y >= self.ny {
            return 0..0;
        }
        let (a, b) = (x0.max(0), x1.min(self.nx - 1));
        if a > b {
            return 0..0;
        }
        let base = (y * self.nx) as usize;
        self.start[base + a as usize] as usize..self.start[base + b as usize + 1] as usize
    }
}
