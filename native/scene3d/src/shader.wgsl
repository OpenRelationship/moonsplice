struct Frame {
    view_proj: mat4x4<f32>,
    light_dir: vec4<f32>,
    light_color: vec4<f32>,
    ambient: vec4<f32>,
}

struct Draw {
    model: mat4x4<f32>,
    color: vec4<f32>,
}

@group(0) @binding(0) var<uniform> frame: Frame;
@group(1) @binding(0) var<uniform> draw: Draw;

struct VsOut {
    @builtin(position) pos: vec4<f32>,
    @location(0) nrm: vec3<f32>,
    @location(1) color: vec4<f32>,
}

@vertex
fn vs_main(@location(0) pos: vec3<f32>, @location(1) nrm: vec3<f32>) -> VsOut {
    var o: VsOut;
    o.pos = frame.view_proj * draw.model * vec4(pos, 1.0);
    o.nrm = normalize((draw.model * vec4(nrm, 0.0)).xyz);
    o.color = draw.color;
    return o;
}

@fragment
fn fs_main(i: VsOut) -> @location(0) vec4<f32> {
    let n = normalize(i.nrm);
    let l = normalize(-frame.light_dir.xyz);
    let ndl = max(dot(n, l), 0.0);
    let lit = frame.ambient.xyz + frame.light_color.xyz * frame.light_color.w * ndl;
    let a = i.color.a;
    return vec4(i.color.rgb * lit * a, a);
}
