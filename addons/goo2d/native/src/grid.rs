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
