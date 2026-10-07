//! moonsplice-render: the GPU, for what the CPU scene cannot do.
//!
//! A headless Bevy app owns the device (.robot/docs/engine.robot, phase 3). It is started the first time a
//! frame needs it and kept for the life of the process; a machine with no GPU gets a sentence
//! from the first pass that needed one, not a crash, and a frame that needs no GPU never starts it.
//!
//! What runs here today: `shader_pass`, a comp's own Shadertoy-style GLSL over a frame (the
//! `shadertoy` fx pass). The GLSL is wrapped into a whole fragment shader, translated to WGSL by
//! naga, and drawn as one fullscreen triangle on Bevy's device; pipelines are cached per source.

use std::collections::HashMap;
use std::panic::{catch_unwind, AssertUnwindSafe};
use std::sync::{Mutex, OnceLock};

use bevy::app::PluginsState;
use bevy::prelude::*;
use bevy::render::renderer::{RenderDevice, RenderQueue};
use bevy::render::{RenderApp, RenderPlugin};
use bevy::window::ExitCondition;

mod world;

struct Gpu {
    /// kept alive: it owns the device; `world` draws in it
    app: App,
    worlds: world::Worlds,
    device: RenderDevice,
    queue: RenderQueue,
    sampler: wgpu::Sampler,
    pipelines: HashMap<String, (wgpu::RenderPipeline, wgpu::BindGroupLayout)>,
}

// Bevy's App is not Send; it is only ever touched behind this lock, from one thread at a time.
struct Locked(Result<Gpu, String>);
unsafe impl Send for Locked {}

static GPU: OnceLock<Mutex<Locked>> = OnceLock::new();

fn start() -> Result<Gpu, String> {
    let mut app = App::new();
    let plugins = DefaultPlugins
        .set(WindowPlugin { primary_window: None, exit_condition: ExitCondition::DontExit, ..default() })
        .set(RenderPlugin { synchronous_pipeline_compilation: true, ..default() })
        // glTF paths come from the comp already absolute (resolve.lua); the root is the filesystem's
        .set(bevy::asset::AssetPlugin { file_path: "/".into(), ..default() })
        .disable::<bevy::render::pipelined_rendering::PipelinedRenderingPlugin>()
        .disable::<bevy::log::LogPlugin>();
    // Bevy panics when there is no adapter; that is "no GPU here", said once.
    catch_unwind(AssertUnwindSafe(|| {
        app.add_plugins(plugins);
        while app.plugins_state() == PluginsState::Adding {
            bevy::tasks::tick_global_task_pools_on_main_thread();
        }
        app.finish();
        app.cleanup();
    }))
    .map_err(|_| "no GPU adapter on this machine".to_string())?;
    let rw = app.sub_app(RenderApp).world();
    let device = rw.get_resource::<RenderDevice>().ok_or("no GPU adapter on this machine")?.clone();
    let queue = rw.get_resource::<RenderQueue>().ok_or("no GPU adapter on this machine")?.clone();
    let sampler = device.wgpu_device().create_sampler(&wgpu::SamplerDescriptor {
        label: Some("moonsplice pass"),
        address_mode_u: wgpu::AddressMode::ClampToEdge,
        address_mode_v: wgpu::AddressMode::ClampToEdge,
        mag_filter: wgpu::FilterMode::Linear,
        min_filter: wgpu::FilterMode::Linear,
        ..Default::default()
    });
    Ok(Gpu { app, worlds: world::Worlds::default(), device, queue, sampler, pipelines: HashMap::new() })
}

const VERTEX: &str = r#"
@vertex
fn main(@builtin(vertex_index) i: u32) -> @builtin(position) vec4<f32> {
    let p = vec2<f32>(f32((i << 1u) & 2u), f32(i & 2u));
    return vec4<f32>(p * 2.0 - 1.0, 0.0, 1.0);
}
"#;

/// The comp's `mainImage` inside a whole GLSL 450 fragment shader, with Shadertoy's names.
/// `Texel(` is the name LÖVE gave `texture(`; comps written then still say it.
fn wrap(body: &str) -> String {
    format!(
        "#version 450\n\
         layout(set = 0, binding = 0) uniform texture2D moonsplice_tex;\n\
         layout(set = 0, binding = 1) uniform sampler moonsplice_smp;\n\
         layout(set = 0, binding = 2) uniform MoonspliceParams {{ vec4 moonsplice_rt; }};\n\
         #define iChannel0 sampler2D(moonsplice_tex, moonsplice_smp)\n\
         #define iResolution (moonsplice_rt.xyz)\n\
         #define iTime (moonsplice_rt.w)\n\
         #define Texel texture\n\
         #define texture2D texture\n\
         layout(location = 0) out vec4 moonsplice_out;\n\
         {body}\n\
         void main() {{ vec4 c = vec4(0.0); mainImage(c, gl_FragCoord.xy); moonsplice_out = c; }}\n"
    )
}

fn to_wgsl(glsl: &str) -> Result<String, String> {
    let mut front = naga::front::glsl::Frontend::default();
    let module = front
        .parse(&naga::front::glsl::Options::from(naga::ShaderStage::Fragment), glsl)
        .map_err(|e| format!("the shader does not compile: {}", e.emit_to_string(glsl).trim()))?;
    let info = naga::valid::Validator::new(naga::valid::ValidationFlags::all(), naga::valid::Capabilities::all())
        .validate(&module)
        .map_err(|e| format!("the shader does not validate: {e}"))?;
    naga::back::wgsl::write_string(&module, &info, naga::back::wgsl::WriterFlags::empty())
        .map_err(|e| format!("the shader does not translate: {e}"))
}

fn pipeline<'a>(gpu: &'a mut Gpu, body: &str) -> Result<&'a (wgpu::RenderPipeline, wgpu::BindGroupLayout), String> {
    if !gpu.pipelines.contains_key(body) {
        let dev = gpu.device.wgpu_device();
        let frag = to_wgsl(&wrap(body))?;
        let vs = dev.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("moonsplice fullscreen"),
            source: wgpu::ShaderSource::Wgsl(VERTEX.into()),
        });
        let fs = dev.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("moonsplice shadertoy"),
            source: wgpu::ShaderSource::Wgsl(frag.into()),
        });
        let layout = dev.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("moonsplice pass"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });
        let pl = dev.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("moonsplice pass"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let rp = dev.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("moonsplice shadertoy"),
            layout: Some(&pl),
            vertex: wgpu::VertexState { module: &vs, entry_point: Some("main"), compilation_options: Default::default(), buffers: &[] },
            fragment: Some(wgpu::FragmentState {
                module: &fs,
                entry_point: Some("main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: Default::default(),
            depth_stencil: None,
            multisample: Default::default(),
            multiview_mask: None,
            cache: None,
        });
        gpu.pipelines.insert(body.to_string(), (rp, layout));
    }
    Ok(&gpu.pipelines[body])
}

/// Run a comp's Shadertoy-style GLSL (`mainImage`) over `rgba` (w x h, premultiplied RGBA8, the
/// frame so far as `iChannel0`) in place. `t` is `iTime`. Errors are sentences.
pub fn shader_pass(body: &str, rgba: &mut [u8], w: u32, h: u32, t: f32) -> Result<(), String> {
    if w == 0 || h == 0 || rgba.len() != (w * h * 4) as usize {
        return Err("the pass was handed a frame of the wrong size".into());
    }
    let lock = GPU.get_or_init(|| Mutex::new(Locked(start())));
    let mut guard = lock.lock().map_err(|_| "the GPU is in an unusable state".to_string())?;
    let gpu = guard.0.as_mut().map_err(|e| e.clone())?;
    let (rp, layout) = {
        let (a, b) = pipeline(gpu, body)?;
        (a.clone(), b.clone())
    };
    let dev = gpu.device.wgpu_device();
    let queue = &gpu.queue.0;
    let size = wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 };
    let src = dev.create_texture(&wgpu::TextureDescriptor {
        label: Some("moonsplice pass in"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::TEXTURE_BINDING | wgpu::TextureUsages::COPY_DST,
        view_formats: &[],
    });
    queue.write_texture(
        src.as_image_copy(),
        rgba,
        wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(w * 4), rows_per_image: Some(h) },
        size,
    );
    let dst = dev.create_texture(&wgpu::TextureDescriptor {
        label: Some("moonsplice pass out"),
        size,
        mip_level_count: 1,
        sample_count: 1,
        dimension: wgpu::TextureDimension::D2,
        format: wgpu::TextureFormat::Rgba8Unorm,
        usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
        view_formats: &[],
    });
    let params: [f32; 4] = [w as f32, h as f32, 1.0, t];
    let ubuf = dev.create_buffer(&wgpu::BufferDescriptor {
        label: Some("moonsplice pass params"),
        size: 16,
        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        mapped_at_creation: false,
    });
    queue.write_buffer(&ubuf, 0, &params.iter().flat_map(|v| v.to_le_bytes()).collect::<Vec<_>>());
    let src_view = src.create_view(&Default::default());
    let bind = dev.create_bind_group(&wgpu::BindGroupDescriptor {
        label: Some("moonsplice pass"),
        layout: &layout,
        entries: &[
            wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&src_view) },
            wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&gpu.sampler) },
            wgpu::BindGroupEntry { binding: 2, resource: ubuf.as_entire_binding() },
        ],
    });
    // readback rows are padded to 256 bytes
    let row = w * 4;
    let padded = row.div_ceil(256) * 256;
    let rb = dev.create_buffer(&wgpu::BufferDescriptor {
        label: Some("moonsplice pass readback"),
        size: (padded * h) as u64,
        usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
        mapped_at_creation: false,
    });
    let mut enc = dev.create_command_encoder(&Default::default());
    {
        let view = dst.create_view(&Default::default());
        let mut pass = enc.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("moonsplice shadertoy"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &view,
                depth_slice: None,
                resolve_target: None,
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT), store: wgpu::StoreOp::Store },
            })],
            ..Default::default()
        });
        pass.set_pipeline(&rp);
        pass.set_bind_group(0, &bind, &[]);
        pass.draw(0..3, 0..1);
    }
    enc.copy_texture_to_buffer(
        dst.as_image_copy(),
        wgpu::TexelCopyBufferInfo {
            buffer: &rb,
            layout: wgpu::TexelCopyBufferLayout { offset: 0, bytes_per_row: Some(padded), rows_per_image: Some(h) },
        },
        size,
    );
    queue.submit([enc.finish()]);
    let slice = rb.slice(..);
    slice.map_async(wgpu::MapMode::Read, |_| {});
    dev.poll(wgpu::PollType::wait_indefinitely()).map_err(|e| format!("the GPU did not finish: {e}"))?;
    {
        let data = slice.get_mapped_range();
        for y in 0..h as usize {
            let s = y * padded as usize;
            rgba[y * row as usize..(y + 1) * row as usize].copy_from_slice(&data[s..s + row as usize]);
        }
    }
    rb.unmap();
    Ok(())
}

/// One frame of a 3D world (`s:world`, render/src/world.rs): `doc` is the world at `t` as JSON,
/// `id` names the world node so its entities persist between frames. sRGB RGBA, straight alpha.
pub fn world_frame(id: &str, doc: &str, w: u32, h: u32) -> Result<Vec<u8>, String> {
    let doc: serde_json::Value = serde_json::from_str(doc).map_err(|e| format!("world: {e}"))?;
    let lock = GPU.get_or_init(|| Mutex::new(Locked(start())));
    let mut guard = lock.lock().map_err(|_| "the GPU is in an unusable state".to_string())?;
    let gpu = guard.0.as_mut().map_err(|e| e.clone())?;
    let Gpu { app, worlds, .. } = gpu;
    catch_unwind(AssertUnwindSafe(|| world::frame(app, worlds, id, &doc, w, h)))
        .map_err(|_| "world: Bevy panicked drawing the frame".to_string())?
}
