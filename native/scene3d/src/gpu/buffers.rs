// What the GPU holds: the uniform blocks, an uploaded mesh, and the render targets with their
// readback buffer, made again when the frame size changes.

use super::Gpu;
use crate::mesh::Mesh;
use wgpu::util::DeviceExt;

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(super) struct FrameU {
    pub(super) view_proj: [[f32; 4]; 4],
    pub(super) light_dir: [f32; 4],
    pub(super) light_color: [f32; 4],
    pub(super) ambient: [f32; 4],
}

#[repr(C)]
#[derive(Clone, Copy, bytemuck::Pod, bytemuck::Zeroable)]
pub(super) struct DrawU {
    pub(super) model: [[f32; 4]; 4],
    pub(super) color: [f32; 4],
}

pub(super) struct GpuMesh {
    pub(super) vb: wgpu::Buffer,
    pub(super) ib: wgpu::Buffer,
    pub(super) count: u32,
}

pub(super) struct Targets {
    pub(super) w: u32,
    pub(super) h: u32,
    pub(super) color: wgpu::Texture,
    pub(super) depth: wgpu::Texture,
    pub(super) readback: wgpu::Buffer,
    pub(super) padded: u32,
}

fn padded_bpr(width: u32) -> u32 {
    let unpadded = width * 4;
    let align = wgpu::COPY_BYTES_PER_ROW_ALIGNMENT;
    unpadded.div_ceil(align) * align
}

pub(super) fn upload(device: &wgpu::Device, mesh: &Mesh, label: &str) -> GpuMesh {
    let vb = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some(label),
        contents: bytemuck::cast_slice(&mesh.vertices),
        usage: wgpu::BufferUsages::VERTEX,
    });
    let ib = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
        label: Some(&(label.to_string() + "_idx")),
        contents: bytemuck::cast_slice(&mesh.indices),
        usage: wgpu::BufferUsages::INDEX,
    });
    GpuMesh {
        vb,
        ib,
        count: mesh.indices.len() as u32,
    }
}

impl Gpu {

    pub(super) fn targets(&mut self, w: u32, h: u32) -> &Targets {
        let recreate = self
            .targets
            .as_ref()
            .map(|t| t.w != w || t.h != h)
            .unwrap_or(true);
        if recreate {
            let padded = padded_bpr(w);
            let color = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("color"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Rgba8Unorm,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::COPY_SRC,
                view_formats: &[],
            });
            let depth = self.device.create_texture(&wgpu::TextureDescriptor {
                label: Some("depth"),
                size: wgpu::Extent3d {
                    width: w,
                    height: h,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: wgpu::TextureFormat::Depth32Float,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
                view_formats: &[],
            });
            let readback = self.device.create_buffer(&wgpu::BufferDescriptor {
                label: Some("readback"),
                size: padded as u64 * h as u64,
                usage: wgpu::BufferUsages::COPY_DST | wgpu::BufferUsages::MAP_READ,
                mapped_at_creation: false,
            });
            self.targets = Some(Targets {
                w,
                h,
                color,
                depth,
                readback,
                padded,
            });
        }
        self.targets.as_ref().unwrap()
    }
}
