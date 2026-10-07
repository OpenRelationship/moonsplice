//! CPython's `random.Random` as far as TabICL's ensemble uses it: MT19937 seeded from an int,
//! `_randbelow` by rejection on `getrandbits`, `shuffle`, `choice`. The feature and class
//! shuffles must be the very permutations Python draws, or the ensemble is a different one.

pub struct PyRandom {
    mt: [u32; 624],
    i: usize,
}

impl PyRandom {
    /// random.Random(seed) for a non-negative seed below 2^32 (init_by_array on its 32-bit words)
    pub fn new(seed: u32) -> Self {
        let mut r = PyRandom { mt: [0; 624], i: 624 };
        r.init_genrand(19650218);
        let key = [seed];
        let n = 624usize;
        let (mut i, mut j) = (1usize, 0usize);
        let mut k = n.max(key.len());
        while k > 0 {
            let prev = r.mt[i - 1] ^ (r.mt[i - 1] >> 30);
            r.mt[i] = (r.mt[i] ^ prev.wrapping_mul(1664525)).wrapping_add(key[j]).wrapping_add(j as u32);
            i += 1;
            j += 1;
            if i >= n {
                r.mt[0] = r.mt[n - 1];
                i = 1;
            }
            if j >= key.len() {
                j = 0;
            }
            k -= 1;
        }
        k = n - 1;
        while k > 0 {
            let prev = r.mt[i - 1] ^ (r.mt[i - 1] >> 30);
            r.mt[i] = (r.mt[i] ^ prev.wrapping_mul(1566083941)).wrapping_sub(i as u32);
            i += 1;
            if i >= n {
                r.mt[0] = r.mt[n - 1];
                i = 1;
            }
            k -= 1;
        }
        r.mt[0] = 0x8000_0000;
        r.i = 624;
        r
    }

    fn init_genrand(&mut self, s: u32) {
        self.mt[0] = s;
        for i in 1..624 {
            self.mt[i] = 1812433253u32.wrapping_mul(self.mt[i - 1] ^ (self.mt[i - 1] >> 30)).wrapping_add(i as u32);
        }
        self.i = 624;
    }

    fn next_u32(&mut self) -> u32 {
        if self.i >= 624 {
            for k in 0..624 {
                let y = (self.mt[k] & 0x8000_0000) | (self.mt[(k + 1) % 624] & 0x7fff_ffff);
                let mut v = self.mt[(k + 397) % 624] ^ (y >> 1);
                if y & 1 != 0 {
                    v ^= 0x9908_b0df;
                }
                self.mt[k] = v;
            }
            self.i = 0;
        }
        let mut y = self.mt[self.i];
        self.i += 1;
        y ^= y >> 11;
        y ^= (y << 7) & 0x9d2c_5680;
        y ^= (y << 15) & 0xefc6_0000;
        y ^ (y >> 18)
    }

    fn getrandbits(&mut self, k: u32) -> u64 {
        if k == 0 {
            return 0;
        }
        if k <= 32 {
            return (self.next_u32() >> (32 - k)) as u64;
        }
        // little-endian 32-bit words, the last one truncated (k < 64 is all TabICL needs)
        let lo = self.next_u32() as u64;
        let hi = (self.next_u32() >> (64 - k)) as u64;
        lo | (hi << 32)
    }

    pub fn randbelow(&mut self, n: usize) -> usize {
        if n == 0 {
            return 0;
        }
        let k = usize::BITS - n.leading_zeros();
        loop {
            let r = self.getrandbits(k) as usize;
            if r < n {
                return r;
            }
        }
    }

    pub fn shuffle<T>(&mut self, x: &mut [T]) {
        for i in (1..x.len()).rev() {
            let j = self.randbelow(i + 1);
            x.swap(i, j);
        }
    }

    pub fn choice<T: Clone>(&mut self, seq: &[T]) -> T {
        seq[self.randbelow(seq.len())].clone()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn matches_cpython() {
        // python3 -c "import random; r=random.Random(0); print([r.getrandbits(32) for _ in range(3)])"
        let mut r = PyRandom::new(0);
        assert_eq!([r.next_u32(), r.next_u32(), r.next_u32()], [3626764237, 1654615998, 3255389356]);
        // python3 -c "import random; r=random.Random(0); x=list(range(10)); r.shuffle(x); print(x)"
        let mut r = PyRandom::new(0);
        let mut x: Vec<usize> = (0..10).collect();
        r.shuffle(&mut x);
        assert_eq!(x, vec![7, 8, 1, 5, 3, 4, 2, 0, 9, 6]);
    }
}
