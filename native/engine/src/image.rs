//! `love.image.newImageData`: a block of pixels the rasterizer can read and write through a
//! pointer.
//!
//! On the direct path an ImageData is never drawn by anything but `scene/` and the native
//! helpers: the frame buffer the rasterizer fills, the planes a video frame is decoded into, an
//! html layer, a decoded PNG. So what the runtime needs from it is a pointer, a size and its
//! dimensions -- and, for a picture on disk, the same pixels LÖVE would have decoded.
//!
//! PNG decodes to the same pixels LÖVE's LodePNG did -- it is lossless, and the conversions match
//! (every colour type expanded to RGBA, 16-bit kept 16-bit, gamma ignored) -- so a golden holding
//! one did not move when LÖVE left. JPEG is lossy and two correct decoders differ in their IDCT
//! and chroma upsampling; it is decoded here by zune-jpeg, and the goldens that hold a JPEG were
//! recaptured once, on the day LÖVE was removed (.robot/docs/engine.robot).

use std::ffi::c_void;

use mlua::{LightUserData, Lua, Table, UserData, UserDataMethods, Value};

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Format {
    Rgba8,
    R8,
    Rgba16,
    Rgba32f,
}

impl Format {
    fn parse(s: &str) -> Option<Format> {
        Some(match s {
            "rgba8" => Format::Rgba8,
            "r8" => Format::R8,
            "rgba16" => Format::Rgba16,
            "rgba32f" => Format::Rgba32f,
            _ => return None,
        })
    }
    fn name(self) -> &'static str {
        match self {
            Format::Rgba8 => "rgba8",
            Format::R8 => "r8",
            Format::Rgba16 => "rgba16",
            Format::Rgba32f => "rgba32f",
        }
    }
    fn bytes_per_pixel(self) -> usize {
        match self {
            Format::Rgba8 => 4,
            Format::R8 => 1,
            Format::Rgba16 => 8,
            Format::Rgba32f => 16,
        }
    }
}

pub struct ImageData {
    w: u32,
    h: u32,
    format: Format,
    bytes: Vec<u8>,
}

impl ImageData {
    fn new(w: u32, h: u32, format: Format) -> ImageData {
        ImageData { w, h, format, bytes: vec![0; w as usize * h as usize * format.bytes_per_pixel()] }
    }
}

impl UserData for ImageData {
    fn add_methods<M: UserDataMethods<Self>>(m: &mut M) {
        // The pointer stays valid for as long as the ImageData lives: the buffer is allocated once
        // and never resized, which is the same promise LÖVE makes.
        m.add_method_mut("getFFIPointer", |_, this, ()| {
            Ok(Value::LightUserData(LightUserData(this.bytes.as_mut_ptr() as *mut c_void)))
        });
        m.add_method("getPointer", |_, this, ()| {
            Ok(Value::LightUserData(LightUserData(this.bytes.as_ptr() as *mut c_void)))
        });
        m.add_method("getSize", |_, this, ()| Ok(this.bytes.len()));
        m.add_method("getDimensions", |_, this, ()| Ok((this.w, this.h)));
        m.add_method("getWidth", |_, this, ()| Ok(this.w));
        m.add_method("getHeight", |_, this, ()| Ok(this.h));
        m.add_method("getFormat", |_, this, ()| Ok(this.format.name()));
        m.add_method("getString", |lua, this, ()| lua.create_string(&this.bytes));
        // A copy that owns its own pixels. Check mode holds two frames at once, and the direct
        // path hands back the same buffer every frame, so a frame kept has to be a copy.
        m.add_method("clone", |_, this, ()| {
            Ok(ImageData { w: this.w, h: this.h, format: this.format, bytes: this.bytes.clone() })
        });
        m.add_method("type", |_, _, ()| Ok("ImageData"));
        m.add_method("typeOf", |_, _, name: String| {
            Ok(matches!(name.as_str(), "ImageData" | "Data" | "Object"))
        });
        // LÖVE frees the buffer early; here it goes when the last reference does. Nothing on the
        // direct path reads an ImageData after releasing it.
        m.add_method("release", |_, _, ()| Ok(true));
        m.add_method("getPixel", |_, this, (x, y): (u32, u32)| {
            if x >= this.w || y >= this.h {
                return Err(mlua::Error::runtime("ImageData:getPixel: out of range"));
            }
            let i = (y as usize * this.w as usize + x as usize) * this.format.bytes_per_pixel();
            let b = &this.bytes;
            Ok(match this.format {
                Format::Rgba8 => (
                    b[i] as f64 / 255.0,
                    b[i + 1] as f64 / 255.0,
                    b[i + 2] as f64 / 255.0,
                    b[i + 3] as f64 / 255.0,
                ),
                Format::R8 => (b[i] as f64 / 255.0, 0.0, 0.0, 1.0),
                Format::Rgba16 => {
                    let c = |k: usize| u16::from_ne_bytes([b[i + 2 * k], b[i + 2 * k + 1]]) as f64 / 65535.0;
                    (c(0), c(1), c(2), c(3))
                }
                Format::Rgba32f => {
                    let c = |k: usize| f32::from_ne_bytes(b[i + 4 * k..i + 4 * k + 4].try_into().unwrap()) as f64;
                    (c(0), c(1), c(2), c(3))
                }
            })
        });
    }
}

/// Why a picture was not decoded: either it is not one, or it is a format this engine does not
/// read yet -- said as "not ported", so nobody mistakes it for a broken file.
enum Refusal {
    NotAnImage(String),
    NotPorted(&'static str),
}

fn decode(bytes: &[u8]) -> Result<ImageData, Refusal> {
    if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        return decode_png(bytes).map_err(Refusal::NotAnImage);
    }
    if bytes.starts_with(&[0xff, 0xd8]) {
        // zune-jpeg, not LÖVE's stb_image: the IDCTs round differently, so a JPEG's pixels moved by
        // a level here and there when LÖVE left, and the goldens that hold one were recaptured.
        return decode_jpeg(bytes).map_err(Refusal::NotAnImage);
    }
    Err(Refusal::NotPorted("an image format other than PNG or JPEG"))
}

/// PNG the way LodePNG hands it to LÖVE: RGBA, 8 bits a channel unless the file has 16, in which
/// case 16 in native byte order; palettes, greys and transparency keys expanded; no gamma.
fn decode_png(bytes: &[u8]) -> Result<ImageData, String> {
    let mut dec = png::Decoder::new(bytes);
    dec.set_transformations(png::Transformations::EXPAND);
    let mut reader = dec.read_info().map_err(|e| format!("could not decode PNG: {e}"))?;
    let mut buf = vec![0; reader.output_buffer_size()];
    let info = reader.next_frame(&mut buf).map_err(|e| format!("could not decode PNG: {e}"))?;
    let (w, h) = (info.width, info.height);
    let n = w as usize * h as usize;
    let sixteen = info.bit_depth == png::BitDepth::Sixteen;
    let channels = info.color_type.samples();
    let bps = if sixteen { 2 } else { 1 };
    let mut img = ImageData::new(w, h, if sixteen { Format::Rgba16 } else { Format::Rgba8 });
    let out = &mut img.bytes;
    for p in 0..n {
        let src = &buf[p * channels * bps..(p + 1) * channels * bps];
        // One sample, as the integer it is (big-endian in the file when 16-bit).
        let s = |k: usize| -> u16 {
            if sixteen {
                u16::from_be_bytes([src[2 * k], src[2 * k + 1]])
            } else {
                src[k] as u16
            }
        };
        let max = if sixteen { 65535 } else { 255 };
        let (r, g, b, a) = match channels {
            1 => (s(0), s(0), s(0), max),
            2 => (s(0), s(0), s(0), s(1)),
            3 => (s(0), s(1), s(2), max),
            _ => (s(0), s(1), s(2), s(3)),
        };
        if sixteen {
            let o = &mut out[p * 8..p * 8 + 8];
            o[0..2].copy_from_slice(&r.to_ne_bytes());
            o[2..4].copy_from_slice(&g.to_ne_bytes());
            o[4..6].copy_from_slice(&b.to_ne_bytes());
            o[6..8].copy_from_slice(&a.to_ne_bytes());
        } else {
            out[p * 4..p * 4 + 4].copy_from_slice(&[r as u8, g as u8, b as u8, a as u8]);
        }
    }
    Ok(img)
}

fn decode_jpeg(bytes: &[u8]) -> Result<ImageData, String> {
    use zune_jpeg::zune_core::colorspace::ColorSpace;
    use zune_jpeg::zune_core::options::DecoderOptions;
    let opts = DecoderOptions::default().jpeg_set_out_colorspace(ColorSpace::RGBA);
    let mut dec = zune_jpeg::JpegDecoder::new_with_options(bytes, opts);
    let px = dec.decode().map_err(|e| format!("could not decode JPEG: {e:?}"))?;
    let (w, h) = dec.dimensions().ok_or("could not decode JPEG: no size")?;
    let mut img = ImageData::new(w as u32, h as u32, Format::Rgba8);
    let n = img.bytes.len();
    img.bytes.copy_from_slice(&px[..n]);
    Ok(img)
}

pub fn install(lua: &Lua, t: &Table) -> mlua::Result<()> {
    // newImageData(w, h [, format [, bytes]])
    t.set(
        "image_new",
        lua.create_function(
            |_, (w, h, format, data): (u32, u32, Option<String>, Option<mlua::String>)| {
                let f = format.as_deref().unwrap_or("rgba8");
                let format = Format::parse(f).ok_or_else(|| {
                    mlua::Error::runtime(format!("love.image.newImageData: format {f:?} is not one this host has"))
                })?;
                let mut img = ImageData::new(w, h, format);
                if let Some(d) = data {
                    let d = d.as_bytes();
                    let n = d.len().min(img.bytes.len());
                    img.bytes[..n].copy_from_slice(&d[..n]);
                }
                Ok(img)
            },
        )?,
    )?;
    // newImageData(filedata): the picture, or (nil, why, not_ported)
    t.set(
        "image_decode",
        lua.create_function(|lua, bytes: mlua::String| match decode(&bytes.as_bytes()) {
            Ok(img) => Ok((Value::UserData(lua.create_userdata(img)?), Value::Nil, false)),
            Err(Refusal::NotAnImage(why)) => Ok((Value::Nil, Value::String(lua.create_string(&why)?), false)),
            Err(Refusal::NotPorted(what)) => Ok((Value::Nil, Value::String(lua.create_string(what)?), true)),
        })?,
    )?;
    Ok(())
}
