const DRAW_STRIDE: u64 = 256;
const MAX_INSTANCES: usize = 64;

mod buffers;

use buffers::{upload, DrawU, FrameU, GpuMesh, Targets};

use crate::mesh::{Mesh, Vertex};
use crate::scene::{Frame, Prim};
use glam::Vec4;
use std::collections::HashMap;

pub struct Gpu {
    device: wgpu::Device,
    queue: wgpu::Queue,
    pipeline: wgpu::RenderPipeline,
    frame_bg: wgpu::BindGroup,
    draw_bg: wgpu::BindGroup,
    frame_buf: wgpu::Buffer,
    draw_buf: wgpu::Buffer,
    cube: GpuMesh,
    sphere: GpuMesh,
    meshes: HashMap<i64, GpuMesh>,
    targets: Option<Targets>,
}


impl Gpu {
    pub fn new(cube: &Mesh, sphere: &Mesh) -> Result<Self, String> {
        let instance = wgpu::Instance::new(&wgpu::InstanceDescriptor {
            backends: wgpu::Backends::PRIMARY,
            ..Default::default()
        });
        let adapter = pollster::block_on(instance.request_adapter(&wgpu::RequestAdapterOptions {
            power_preference: wgpu::PowerPreference::HighPerformance,
            compatible_surface: None,
            force_fallback_adapter: false,
        }))
        .ok_or_else(|| "no wgpu adapter".to_string())?;
        let (device, queue) = pollster::block_on(adapter.request_device(
            &wgpu::DeviceDescriptor {
                label: Some("moonsplice-scene3d"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::downlevel_defaults().using_resolution(adapter.limits()),
                memory_hints: wgpu::MemoryHints::Performance,
            },
            None,
        ))
        .map_err(|e| e.to_string())?;

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("moonsplice-scene3d"),
            source: wgpu::ShaderSource::Wgsl(include_str!("shader.wgsl").into()),
        });

        let frame_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("frame"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let draw_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("draw"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: true,
                    min_binding_size: wgpu::BufferSize::new(std::mem::size_of::<DrawU>() as u64),
                },
                count: None,
            }],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("moonsplice-scene3d"),
            bind_group_layouts: &[&frame_layout, &draw_layout],
            push_constant_ranges: &[],
        });

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("moonsplice-scene3d"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                compilation_options: Default::default(),
                buffers: &[wgpu::VertexBufferLayout {
                    array_stride: std::mem::size_of::<Vertex>() as u64,
                    step_mode: wgpu::VertexStepMode::Vertex,
                    attributes: &wgpu::vertex_attr_array![0 => Float32x3, 1 => Float32x3],
                }],
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format: wgpu::TextureFormat::Rgba8Unorm,
                    blend: Some(wgpu::BlendState::PREMULTIPLIED_ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                cull_mode: Some(wgpu::Face::Back),
                ..Default::default()
            },
            depth_stencil: Some(wgpu::DepthStencilState {
                format: wgpu::TextureFormat::Depth32Float,
                depth_write_enabled: true,
                depth_compare: wgpu::CompareFunction::Less,
                stencil: wgpu::StencilState::default(),
                bias: wgpu::DepthBiasState::default(),
            }),
            multisample: wgpu::MultisampleState::default(),
            multiview: None,
            cache: None,
        });

        let frame_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("frame-ub"),
            size: std::mem::size_of::<FrameU>() as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let draw_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("draw-ub"),
            size: DRAW_STRIDE * MAX_INSTANCES as u64,
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let frame_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("frame-bg"),
            layout: &frame_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: frame_buf.as_entire_binding(),
            }],
        });
        let draw_bg = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("draw-bg"),
            layout: &draw_layout,
            entries: &[wgpu::BindGroupEntry {
                binding: 0,
                resource: wgpu::BindingResource::Buffer(wgpu::BufferBinding {
                    buffer: &draw_buf,
                    offset: 0,
                    size: wgpu::BufferSize::new(std::mem::size_of::<DrawU>() as u64),
                }),
            }],
        });

        Ok(Self {
            cube: upload(&device, cube, "cube"),
            sphere: upload(&device, sphere, "sphere"),
            device,
            queue,
            pipeline,
            frame_bg,
            draw_bg,
            frame_buf,
            draw_buf,
            meshes: HashMap::new(),
            targets: None,
        })
    }

    pub fn has_mesh(&self, id: i64) -> bool {
        self.meshes.contains_key(&id)
    }

    pub fn upload_mesh(&mut self, id: i64, mesh: &Mesh) {
        if self.meshes.contains_key(&id) {
            return;
        }
        self.meshes
            .insert(id, upload(&self.device, mesh, &format!("mesh{id}")));
    }


    pub fn render(&mut self, frame: &Frame, w: u32, h: u32, out: &mut [u8]) -> Result<(), String> {
        let vp = frame.view_proj(w as f32 / h.max(1) as f32);
        let fu = FrameU {
            view_proj: vp.to_cols_array_2d(),
            light_dir: Vec4::new(frame.light_dir.x, frame.light_dir.y, frame.light_dir.z, 0.0)
                .to_array(),
            light_color: [
                frame.light_color.x,
                frame.light_color.y,
                frame.light_color.z,
                frame.light_int,
            ],
            ambient: [frame.ambient.x, frame.ambient.y, frame.ambient.z, 1.0],
        };
        self.queue
            .write_buffer(&self.frame_buf, 0, bytemuck::bytes_of(&fu));

        let n = frame.instances.len().min(MAX_INSTANCES);
        let mut staging = vec![0u8; DRAW_STRIDE as usize * n.max(1)];
        for (i, inst) in frame.instances.iter().take(n).enumerate() {
            let du = DrawU {
                model: inst.model().to_cols_array_2d(),
                color: inst.color,
            };
            let off = i * DRAW_STRIDE as usize;
            staging[off..off + std::mem::size_of::<DrawU>()].copy_from_slice(bytemuck::bytes_of(&du));
        }
        self.queue.write_buffer(&self.draw_buf, 0, &staging);

        let padded = self.targets(w, h).padded;
        let color_view = self
            .targets
            .as_ref()
            .unwrap()
            .color
            .create_view(&Default::default());
        let depth_view = self
            .targets
            .as_ref()
            .unwrap()
            .depth
            .create_view(&Default::default());

        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("moonsplice-scene3d"),
            });
        {
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("moonsplice-scene3d"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &color_view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: (frame.clear[0] * frame.clear[3]) as f64,
                            g: (frame.clear[1] * frame.clear[3]) as f64,
                            b: (frame.clear[2] * frame.clear[3]) as f64,
                            a: frame.clear[3] as f64,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                })],
                depth_stencil_attachment: Some(wgpu::RenderPassDepthStencilAttachment {
                    view: &depth_view,
                    depth_ops: Some(wgpu::Operations {
                        load: wgpu::LoadOp::Clear(1.0),
                        store: wgpu::StoreOp::Store,
                    }),
                    stencil_ops: None,
                }),
                occlusion_query_set: None,
                timestamp_writes: None,
            });
            pass.set_pipeline(&self.pipeline);
            pass.set_bind_group(0, &self.frame_bg, &[]);
            for (i, inst) in frame.instances.iter().take(n).enumerate() {
                let gpu_mesh = match inst.prim {
                    Prim::Cube => &self.cube,
                    Prim::Sphere => &self.sphere,
                    Prim::Handle(id) => match self.meshes.get(&id) {
                        Some(m) => m,
                        None => continue,
                    },
                };
                pass.set_bind_group(1, &self.draw_bg, &[(i as u32) * DRAW_STRIDE as u32]);
                pass.set_vertex_buffer(0, gpu_mesh.vb.slice(..));
                pass.set_index_buffer(gpu_mesh.ib.slice(..), wgpu::IndexFormat::Uint32);
                pass.draw_indexed(0..gpu_mesh.count, 0, 0..1);
            }
        }

        {
            let t = self.targets.as_ref().unwrap();
            encoder.copy_texture_to_buffer(
                wgpu::TexelCopyTextureInfo {
                    texture: &t.color,
                    mip_level: 0,
                    origin: wgpu::Origin3d::ZERO,
                    aspect: wgpu::TextureAspect::All,
                },
                wgpu::TexelCopyBufferInfo {
                    buffer: &t.readback,
                    layout: wgpu::TexelCopyBufferLayout {
                        offset: 0,
                        bytes_per_row: Some(padded),
                        rows_per_image: Some(h),
                    },
                },
                wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
            );
        }
        self.queue.submit(Some(encoder.finish()));

        let slice = self.targets.as_ref().unwrap().readback.slice(..);
        slice.map_async(wgpu::MapMode::Read, |_| {});
        self.device.poll(wgpu::Maintain::Wait);
        {
            let data = slice.get_mapped_range();
            let src_bpr = padded as usize;
            let dst_bpr = (w * 4) as usize;
            for y in 0..h as usize {
                let s = y * src_bpr;
                let d = y * dst_bpr;
                out[d..d + dst_bpr].copy_from_slice(&data[s..s + dst_bpr]);
            }
        }
        self.targets.as_ref().unwrap().readback.unmap();
        Ok(())
    }
}
