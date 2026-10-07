//! `t:drop`: rigid bodies falling onto a ground, baked once at compile on rapier2d.
//!
//! Box2D came with LÖVE; this replaces it. The simulation runs once, at a fixed step, and the
//! sampled centres and angles become ordinary timeline segments in `core/runtime/physics_bake.lua`, so
//! rendering stays a pure function of t. `enhanced-determinism` makes the bake the same on every
//! platform, which is what lets a drop sit in a golden.
//!
//! Units: the comp is in pixels, the solver is tuned for metres, so everything is divided by
//! `METER` going in and multiplied coming out -- the same 64 px/m LÖVE's Box2D used.

use mlua::{Lua, Table};
use rapier2d::prelude::*;

const METER: f32 = 64.0;

pub fn install(lua: &Lua, t: &Table) -> mlua::Result<()> {
    t.set("physics_drop", lua.create_function(|lua, spec: Table| drop(lua, spec))?)?;
    install_live(lua, t)?;
    Ok(())
}

fn num(t: &Table, k: &str, default: f32) -> f32 {
    t.get::<Option<f32>>(k).ok().flatten().unwrap_or(default)
}

/// spec: { comp_w, comp_h, gravity, ground_y, ground_w, walls, friction, ground_friction,
///         density, restitution, spin, duration, samples, bodies = { {cx, cy, w, h}, ... } }
/// returns { {x = {..}, y = {..}, r = {..}}, ... }: body centres in pixels and angles in radians,
/// one entry per sample.
fn drop(lua: &Lua, spec: Table) -> mlua::Result<Table> {
    let (cw, ch) = (num(&spec, "comp_w", 1280.0), num(&spec, "comp_h", 720.0));
    let samples = num(&spec, "samples", 2.0).max(2.0) as usize;
    let dur = num(&spec, "duration", 1.0);
    let friction = num(&spec, "friction", 0.45);

    let mut world = PhysicsWorld::new();
    world.gravity = Vector::new(0.0, num(&spec, "gravity", 980.0) / METER);
    let phys_dt = 1.0 / 240.0;
    world.integration_parameters.dt = phys_dt;

    let fixed = |world: &mut PhysicsWorld, x: f32, y: f32, w: f32, h: f32, f: f32| {
        let b = world.bodies.insert(RigidBodyBuilder::fixed().translation(Vector::new(x / METER, y / METER)));
        let c = ColliderBuilder::cuboid(w / 2.0 / METER, h / 2.0 / METER).friction(f);
        world.colliders.insert_with_parent(c, b, &mut world.bodies);
    };
    let gw = num(&spec, "ground_w", cw) + 80.0;
    fixed(&mut world, cw / 2.0, num(&spec, "ground_y", ch - 48.0), gw, 24.0, num(&spec, "ground_friction", 0.55));
    if spec.get::<Option<bool>>("walls")?.unwrap_or(true) {
        fixed(&mut world, 12.0, ch / 2.0, 24.0, ch, friction);
        fixed(&mut world, cw - 12.0, ch / 2.0, 24.0, ch, friction);
    }

    let spin = num(&spec, "spin", 0.0);
    let mut handles = Vec::new();
    for (i, b) in spec.get::<Table>("bodies")?.sequence_values::<Table>().enumerate() {
        let b = b?;
        let (cx, cy, w, h) = (num(&b, "cx", 0.0), num(&b, "cy", 0.0), num(&b, "w", 40.0), num(&b, "h", 40.0));
        let mut rb = RigidBodyBuilder::dynamic().translation(Vector::new(cx / METER, cy / METER));
        if spin != 0.0 {
            // alternate directions, as the Box2D bake did (Lua indices start at 1)
            rb = rb.angvel(if (i + 1) % 2 == 0 { spin } else { -spin });
        }
        let h_ = world.bodies.insert(rb);
        let c = ColliderBuilder::cuboid((w * 0.92).max(8.0) / 2.0 / METER, (h * 0.78).max(8.0) / 2.0 / METER)
            .density(num(&spec, "density", 1.0))
            .restitution(num(&spec, "restitution", 0.18))
            .friction(friction)
            // Box2D's mixing: restitution takes the larger; friction the root of the product,
            // which for coefficients this close together the average matches to a hair.
            .restitution_combine_rule(CoefficientCombineRule::Max)
            .friction_combine_rule(CoefficientCombineRule::Average);
        world.colliders.insert_with_parent(c, h_, &mut world.bodies);
        handles.push(h_);
    }

    let mut xs = vec![Vec::with_capacity(samples); handles.len()];
    let mut ys = xs.clone();
    let mut rs = xs.clone();
    let dt = dur / (samples - 1) as f32;
    let mut acc = 0.0f32;
    for s in 0..samples {
        if s > 0 {
            acc += dt;
            while acc >= phys_dt {
                world.step();
                acc -= phys_dt;
            }
        }
        for (i, h) in handles.iter().enumerate() {
            let rb = &world.bodies[*h];
            let p = rb.translation();
            xs[i].push(p.x * METER);
            ys[i].push(p.y * METER);
            rs[i].push(rb.rotation().angle());
        }
    }

    let out = lua.create_table()?;
    for i in 0..handles.len() {
        let one = lua.create_table()?;
        one.set("x", xs[i].clone())?;
        one.set("y", ys[i].clone())?;
        one.set("r", rs[i].clone())?;
        out.set(i + 1, one)?;
    }
    Ok(out)
}

// --------------------------------------------------------------------------- live worlds
//
// `E.physics_world{gravity = 980}`: a world a game steps itself, inside its fold over the input
// log (core/moonsplice/game.lua). Fixed steps and `enhanced-determinism` make a replay of the
// same log land on the same bits, which is what lets a game seek, render and sit in a golden.
// Pixels in and out, y down; ids are 1-based, in the order bodies were made.

use mlua::{UserData, UserDataMethods};
use std::sync::mpsc::{channel, Receiver};

pub struct LiveWorld {
    w: PhysicsWorld,
    bodies: Vec<Option<(RigidBodyHandle, ColliderHandle)>>,
    events: ChannelEventCollector,
    rx_collide: Receiver<CollisionEvent>,
    _rx_force: Receiver<ContactForceEvent>,
    began: Vec<(u32, u32)>,
}

fn live_world(spec: Option<Table>) -> mlua::Result<LiveWorld> {
    let g = spec.as_ref().map(|s| num(s, "gravity", 980.0)).unwrap_or(980.0);
    let gx = spec.as_ref().map(|s| num(s, "gravity_x", 0.0)).unwrap_or(0.0);
    let mut w = PhysicsWorld::new();
    w.gravity = Vector::new(gx / METER, g / METER);
    let (tx_c, rx_c) = channel();
    let (tx_f, rx_f) = channel();
    let (tx_t, _rx_t) = channel();
    Ok(LiveWorld {
        w,
        bodies: Vec::new(),
        events: ChannelEventCollector::new(tx_c, tx_f, tx_t),
        rx_collide: rx_c,
        _rx_force: rx_f,
        began: Vec::new(),
    })
}

impl LiveWorld {
    fn add(&mut self, spec: &Table, shape: SharedShape) -> mlua::Result<u32> {
        let (x, y) = (num(spec, "x", 0.0), num(spec, "y", 0.0));
        let kind: String = spec.get::<Option<String>>("kind")?.unwrap_or_else(|| "dynamic".into());
        let rb = match kind.as_str() {
            "static" => RigidBodyBuilder::fixed(),
            "kinematic" => RigidBodyBuilder::kinematic_position_based(),
            "dynamic" => RigidBodyBuilder::dynamic(),
            other => return Err(mlua::Error::runtime(format!("physics: kind is dynamic, static or kinematic, not {other}"))),
        }
        .translation(Vector::new(x / METER, y / METER))
        .rotation(num(spec, "angle", 0.0))
        .linear_damping(num(spec, "damping", 0.0))
        .angular_damping(num(spec, "angular_damping", 0.0))
        .ccd_enabled(spec.get::<Option<bool>>("bullet")?.unwrap_or(false))
        .lock_rotations_if(spec.get::<Option<bool>>("fixed_rotation")?.unwrap_or(false));
        let id = self.bodies.len() as u32 + 1;
        let rb = rb.user_data(id as u128);
        let h = self.w.bodies.insert(rb);
        let c = ColliderBuilder::new(shape)
            .density(num(spec, "density", 1.0))
            .friction(num(spec, "friction", 0.5))
            .restitution(num(spec, "restitution", 0.0))
            .sensor(spec.get::<Option<bool>>("sensor")?.unwrap_or(false))
            .active_events(ActiveEvents::COLLISION_EVENTS)
            .user_data(id as u128);
        let ch = self.w.colliders.insert_with_parent(c, h, &mut self.w.bodies);
        self.bodies.push(Some((h, ch)));
        Ok(id)
    }

    fn body(&self, id: u32) -> mlua::Result<RigidBodyHandle> {
        self.bodies
            .get((id as usize).wrapping_sub(1))
            .and_then(|b| b.map(|(h, _)| h))
            .ok_or_else(|| mlua::Error::runtime(format!("physics: no body {id}")))
    }

    fn step(&mut self, dt: f32) {
        self.w.integration_parameters.dt = dt;
        self.w.step_with_events(&(), &self.events);
        self.began.clear();
        while let Ok(e) = self.rx_collide.try_recv() {
            if let CollisionEvent::Started(a, b, _) = e {
                let id = |c| self.w.colliders.get(c).map(|c| c.user_data as u32).unwrap_or(0);
                self.began.push((id(a), id(b)));
            }
        }
    }
}

trait LockIf {
    fn lock_rotations_if(self, on: bool) -> Self;
}
impl LockIf for RigidBodyBuilder {
    fn lock_rotations_if(self, on: bool) -> Self {
        if on { self.lock_rotations() } else { self }
    }
}

impl UserData for LiveWorld {
    fn add_methods<M: UserDataMethods<Self>>(m: &mut M) {
        m.add_method_mut("box", |_, w, spec: Table| {
            let (bw, bh) = (num(&spec, "w", 32.0), num(&spec, "h", 32.0));
            w.add(&spec, SharedShape::cuboid(bw / 2.0 / METER, bh / 2.0 / METER))
        });
        m.add_method_mut("ball", |_, w, spec: Table| {
            let r = num(&spec, "r", 16.0);
            w.add(&spec, SharedShape::ball(r / METER))
        });
        m.add_method_mut("step", |_, w, dt: Option<f32>| {
            w.step(dt.unwrap_or(1.0 / 60.0));
            Ok(())
        });
        m.add_method("get", |_, w, id: u32| {
            let b = &w.w.bodies[w.body(id)?];
            let (p, v) = (b.translation(), b.linvel());
            Ok((p.x * METER, p.y * METER, b.rotation().angle(), v.x * METER, v.y * METER, b.angvel()))
        });
        m.add_method_mut("set", |_, w, (id, s): (u32, Table)| {
            let h = w.body(id)?;
            let b = &mut w.w.bodies[h];
            let p = b.translation();
            if s.contains_key("x")? || s.contains_key("y")? {
                let (x, y) = (num(&s, "x", p.x * METER), num(&s, "y", p.y * METER));
                b.set_translation(Vector::new(x / METER, y / METER), true);
            }
            if s.contains_key("angle")? {
                b.set_rotation(Rotation::new(num(&s, "angle", 0.0)), true);
            }
            if s.contains_key("vx")? || s.contains_key("vy")? {
                let v = b.linvel();
                b.set_linvel(Vector::new(num(&s, "vx", v.x * METER) / METER, num(&s, "vy", v.y * METER) / METER), true);
            }
            if s.contains_key("spin")? {
                b.set_angvel(num(&s, "spin", 0.0), true);
            }
            Ok(())
        });
        m.add_method_mut("impulse", |_, w, (id, ix, iy): (u32, f32, f32)| {
            let h = w.body(id)?;
            w.w.bodies[h].apply_impulse(Vector::new(ix / METER, iy / METER), true);
            Ok(())
        });
        m.add_method_mut("torque", |_, w, (id, t): (u32, f32)| {
            let h = w.body(id)?;
            w.w.bodies[h].apply_torque_impulse(t, true);
            Ok(())
        });
        m.add_method_mut("remove", |_, w, id: u32| {
            let h = w.body(id)?;
            let wr = &mut w.w;
            wr.bodies.remove(h, &mut wr.islands, &mut wr.colliders, &mut wr.impulse_joints, &mut wr.multibody_joints, &mut wr.soft_bodies, true);
            w.bodies[id as usize - 1] = None;
            Ok(())
        });
        // contacts that began during the last step, as { {a, b}, ... }
        m.add_method("contacts", |lua, w, ()| {
            let out = lua.create_table()?;
            for (i, (a, b)) in w.began.iter().enumerate() {
                out.set(i + 1, lua.create_sequence_from([*a, *b])?)?;
            }
            Ok(out)
        });
        m.add_method("count", |_, w, ()| Ok(w.bodies.iter().filter(|b| b.is_some()).count()));
    }
}

pub fn install_live(lua: &Lua, t: &Table) -> mlua::Result<()> {
    t.set("physics_world", lua.create_function(|_, spec: Option<Table>| live_world(spec))?)?;
    Ok(())
}
