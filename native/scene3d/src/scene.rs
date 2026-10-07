use glam::{EulerRot, Mat4, Vec3};

#[derive(Clone, Copy)]
pub enum Prim {
    Cube,
    Sphere,
    Handle(i64),
}

#[derive(Clone, Copy)]
pub struct Instance {
    pub prim: Prim,
    pub x: f32,
    pub y: f32,
    pub z: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub roll: f32,
    pub sx: f32,
    pub sy: f32,
    pub sz: f32,
    pub color: [f32; 4],
}

pub struct Frame {
    pub eye: Vec3,
    pub look: Vec3,
    pub up: Vec3,
    pub fov: f32,
    pub near: f32,
    pub far: f32,
    pub yaw: f32,
    pub pitch: f32,
    pub roll: f32,
    pub light_dir: Vec3,
    pub light_color: Vec3,
    pub light_int: f32,
    pub ambient: Vec3,
    pub clear: [f32; 4],
    pub instances: Vec<Instance>,
}

impl Default for Frame {
    fn default() -> Self {
        Self {
            eye: Vec3::new(0.0, 0.35, 3.2),
            look: Vec3::ZERO,
            up: Vec3::Y,
            fov: 0.7,
            near: 0.05,
            far: 80.0,
            yaw: 0.0,
            pitch: 0.0,
            roll: 0.0,
            light_dir: Vec3::new(0.4, -1.0, 0.25),
            light_color: Vec3::ONE,
            light_int: 1.05,
            ambient: Vec3::new(0.16, 0.17, 0.20),
            clear: [0.0, 0.0, 0.0, 0.0],
            instances: Vec::new(),
        }
    }
}

impl Frame {
    pub fn view_proj(&self, aspect: f32) -> Mat4 {
        let rot = glam::Mat3::from_euler(EulerRot::YXZ, self.yaw, self.pitch, self.roll);
        let offset = rot * (self.eye - self.look);
        let eye = self.look + offset;
        let up = if self.up.length_squared() < 1e-8 {
            Vec3::Y
        } else {
            self.up
        };
        let view = Mat4::look_at_rh(eye, self.look, up);
        let proj = Mat4::perspective_rh(self.fov.max(0.05), aspect.max(0.01), self.near.max(0.001), self.far.max(self.near + 0.1));
        proj * view
    }
}

impl Instance {
    pub fn model(&self) -> Mat4 {
        Mat4::from_translation(Vec3::new(self.x, self.y, self.z))
            * Mat4::from_euler(EulerRot::YXZ, self.yaw, self.pitch, self.roll)
            * Mat4::from_scale(Vec3::new(self.sx, self.sy, self.sz))
    }
}

struct Reader<'a> {
    d: &'a [f32],
    i: usize,
}

impl<'a> Reader<'a> {
    fn next(&mut self) -> Option<f32> {
        let v = self.d.get(self.i).copied();
        self.i += 1;
        v
    }
    fn take<const N: usize>(&mut self) -> Option<[f32; N]> {
        let mut out = [0f32; N];
        for slot in out.iter_mut() {
            *slot = self.next()?;
        }
        Some(out)
    }
}

pub fn parse(cmds: &[f32]) -> Option<Frame> {
    let mut rd = Reader { d: cmds, i: 0 };
    let mut frame = Frame::default();
    while let Some(op) = rd.next() {
        match op as u32 {
            0 => {
                let [ex, ey, ez, lx, ly, lz, ux, uy, uz, fov, near, far, yaw, pitch, roll] =
                    rd.take::<15>()?;
                frame.eye = Vec3::new(ex, ey, ez);
                frame.look = Vec3::new(lx, ly, lz);
                frame.up = Vec3::new(ux, uy, uz);
                frame.fov = fov;
                frame.near = near;
                frame.far = far;
                frame.yaw = yaw;
                frame.pitch = pitch;
                frame.roll = roll;
            }
            1 => {
                let [dx, dy, dz, r, g, b, intensity] = rd.take::<7>()?;
                frame.light_dir = Vec3::new(dx, dy, dz);
                frame.light_color = Vec3::new(r, g, b);
                frame.light_int = intensity;
            }
            2 => {
                let [r, g, b] = rd.take::<3>()?;
                frame.ambient = Vec3::new(r, g, b);
            }
            3 => {
                frame.clear = rd.take::<4>()?;
            }
            4 | 6 => {
                let [x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a] = rd.take::<13>()?;
                frame.instances.push(Instance {
                    prim: if op as u32 == 6 {
                        Prim::Sphere
                    } else {
                        Prim::Cube
                    },
                    x,
                    y,
                    z,
                    yaw,
                    pitch,
                    roll,
                    sx,
                    sy,
                    sz,
                    color: [r, g, b, a],
                });
            }
            5 => {
                let [handle, x, y, z, yaw, pitch, roll, sx, sy, sz, r, g, b, a] = rd.take::<14>()?;
                frame.instances.push(Instance {
                    prim: Prim::Handle(handle as i64),
                    x,
                    y,
                    z,
                    yaw,
                    pitch,
                    roll,
                    sx,
                    sy,
                    sz,
                    color: [r, g, b, a],
                });
            }
            _ => return None,
        }
    }
    Some(frame)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_cube_stream() {
        let cmds = [
            4.0, 0.0, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0, 1.0, 1.0, 1.0, 0.2, 0.4, 1.0,
        ];
        let f = parse(&cmds).unwrap();
        assert_eq!(f.instances.len(), 1);
        assert!(matches!(f.instances[0].prim, Prim::Cube));
    }
}
