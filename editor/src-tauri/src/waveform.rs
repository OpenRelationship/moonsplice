//! What a sound looks like.
//!
//! A timeline with seventy sounds on it and no waveforms is seventy identical grey bars: you can
//! see that there is narration at four minutes and not whether it is a sentence or a breath. The
//! shape is the only thing that makes a sound lane readable, and it is the one thing the outline
//! cannot carry — the outline has no paths in it, on purpose.
//!
//! So this reads the file itself, through ffmpeg, which the app already requires. One pass, mono,
//! 8 kHz, signed 16-bit, and the loudest sample in each bucket. That is enough to draw with and
//! small enough to keep: 512 buckets is 512 bytes, whatever the sound is.
//!
//! Three things make it usable rather than merely correct. It is cached in memory by file and
//! modification time, so scrolling a long edit reads nothing twice. It is computed off the
//! window's thread. And it is bounded — a handful at a time — because seventy ffmpeg processes
//! starting at once is a worse answer than seventy lanes filling in over a second.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::{Arc, Condvar, Mutex};

/// How many buckets a sound is drawn with. A lane is at most a few thousand pixels wide and a
/// waveform is drawn symmetrically about its middle, so more than this is detail nobody sees.
pub const BUCKETS: usize = 512;

/// The most sounds being read at once. Higher is not faster: each one is an ffmpeg process
/// reading a file, and past the cores on the machine they take the time from each other.
const AT_ONCE: usize = 4;

/// One sound's shape: the loudest sample in each of `BUCKETS` equal slices, 0..=255.
pub type Peaks = Vec<u8>;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
struct Stamp {
    /// Modification time in whole seconds, and the size. Between them they catch every edit
    /// anybody makes to a sound file outside the app, which is the case this has to survive:
    /// the project is a directory and something else may have written to it.
    secs: i64,
    len: u64,
}

fn stamp(path: &Path) -> Option<Stamp> {
    let meta = std::fs::metadata(path).ok()?;
    let secs = meta
        .modified()
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map(|d| d.as_secs() as i64)
        .unwrap_or(0);
    Some(Stamp {
        secs,
        len: meta.len(),
    })
}

#[derive(Default)]
struct Inner {
    /// What has been read, by file and stamp.
    have: HashMap<(PathBuf, Stamp), Arc<Peaks>>,
    /// What is being read right now, so two lanes asking for one sound read it once.
    busy: Vec<(PathBuf, Stamp)>,
    /// Files that could not be read, so a broken one is not retried on every scroll.
    lost: HashMap<(PathBuf, Stamp), String>,
}

/// The shapes of every sound the app has looked at.
#[derive(Default)]
pub struct Waveforms {
    inner: Mutex<Inner>,
    /// Woken when a read finishes, so a waiter can see whether its own is done.
    done: Condvar,
}

impl Waveforms {
    pub fn new() -> Waveforms {
        Waveforms::default()
    }

    /// The shape of one sound, reading it if this is the first time anybody asked.
    ///
    /// It blocks — the caller is a command on a worker thread, not the window — but only for the
    /// one file, and never for a file somebody else is already reading: that one is waited on.
    pub fn of(&self, path: &Path) -> Result<Arc<Peaks>, String> {
        let stamp = stamp(path).ok_or_else(|| "that sound is not there any more".to_string())?;
        let key = (path.to_path_buf(), stamp);

        let mut inner = self.inner.lock().unwrap();
        loop {
            if let Some(found) = inner.have.get(&key) {
                return Ok(found.clone());
            }
            if let Some(why) = inner.lost.get(&key) {
                return Err(why.clone());
            }
            if !inner.busy.iter().any(|b| *b == key) {
                break;
            }
            // Somebody else is reading this very file. Wait for them rather than reading it again.
            inner = self.done.wait(inner).unwrap();
        }
        // And wait for a turn, so a long edit does not start seventy processes at once.
        while inner.busy.len() >= AT_ONCE {
            inner = self.done.wait(inner).unwrap();
            if let Some(found) = inner.have.get(&key) {
                return Ok(found.clone());
            }
        }
        inner.busy.push(key.clone());
        drop(inner);

        let read = read_peaks(path, BUCKETS);

        let mut inner = self.inner.lock().unwrap();
        inner.busy.retain(|b| *b != key);
        let out = match read {
            Ok(peaks) => {
                let peaks = Arc::new(peaks);
                inner.have.insert(key, peaks.clone());
                Ok(peaks)
            }
            Err(why) => {
                inner.lost.insert(key, why.clone());
                Err(why)
            }
        };
        drop(inner);
        self.done.notify_all();
        out
    }

    /// What is already known, without reading anything. For the side that would rather draw a
    /// flat bar now than wait.
    pub fn ready(&self, path: &Path) -> Option<Arc<Peaks>> {
        let stamp = stamp(path)?;
        let inner = self.inner.lock().unwrap();
        inner.have.get(&(path.to_path_buf(), stamp)).cloned()
    }

    /// How many sounds are held. For the test that says the cache is one.
    pub fn held(&self) -> usize {
        self.inner.lock().unwrap().have.len()
    }
}

/// One pass of ffmpeg, and the loudest sample in each bucket.
///
/// Mono and 8 kHz because a shape is not a sound: at eight thousand samples a second a bucket of
/// a ten minute file still holds a hundred samples, which is plenty to find a peak in, and the
/// decode is a tenth of the work of doing it properly.
pub fn read_peaks(path: &Path, buckets: usize) -> Result<Peaks, String> {
    if buckets == 0 {
        return Ok(Vec::new());
    }
    let out = Command::new("ffmpeg")
        .args(["-v", "error", "-nostdin", "-i"])
        .arg(path)
        .args(["-map", "a:0", "-ac", "1", "-ar", "8000", "-f", "s16le", "-"])
        .stdin(Stdio::null())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("ffmpeg could not be run: {e}"))?;
    if !out.status.success() {
        let said = String::from_utf8_lossy(&out.stderr);
        let first = said.lines().next().unwrap_or("it would not decode");
        return Err(first.to_string());
    }
    Ok(peaks_of(&out.stdout, buckets))
}

/// The loudest sample in each of `buckets` equal slices of signed 16-bit mono, as 0..=255.
///
/// Its own function so the arithmetic is testable without a decoder: the off-by-one that matters
/// here is the last bucket, which must reach the end of the sound rather than stopping a sample
/// short of it and drawing a notch that is not there.
pub fn peaks_of(pcm: &[u8], buckets: usize) -> Peaks {
    let samples = pcm.len() / 2;
    if samples == 0 || buckets == 0 {
        return vec![0; buckets];
    }
    let mut out = Vec::with_capacity(buckets);
    for i in 0..buckets {
        let from = samples * i / buckets;
        let to = (samples * (i + 1) / buckets).max(from + 1).min(samples);
        let mut loudest = 0i32;
        for s in from..to {
            let v = i16::from_le_bytes([pcm[s * 2], pcm[s * 2 + 1]]) as i32;
            // -32768 has no positive twin; clamping it to 32767 costs nothing anybody can see.
            let v = v.unsigned_abs().min(32767) as i32;
            if v > loudest {
                loudest = v;
            }
        }
        out.push((loudest * 255 / 32767) as u8);
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    /// `n` samples of a sine at `amp`, as the bytes ffmpeg would hand over.
    fn tone(n: usize, amp: i16) -> Vec<u8> {
        (0..n)
            .flat_map(|i| {
                let v = (amp as f64 * (i as f64 * 0.1).sin()) as i16;
                v.to_le_bytes()
            })
            .collect()
    }

    #[test]
    fn a_loud_sound_reads_loud_and_a_quiet_one_quiet() {
        let loud = peaks_of(&tone(8000, 30000), 16);
        let quiet = peaks_of(&tone(8000, 3000), 16);
        assert_eq!(loud.len(), 16);
        assert!(loud.iter().all(|p| *p > 200), "{loud:?}");
        assert!(quiet.iter().all(|p| *p < 40), "{quiet:?}");
    }

    #[test]
    fn silence_is_flat_and_nothing_at_all_is_still_the_right_length() {
        assert_eq!(peaks_of(&vec![0u8; 2000], 8), vec![0; 8]);
        assert_eq!(peaks_of(&[], 8), vec![0; 8]);
        assert_eq!(peaks_of(&tone(100, 30000), 0).len(), 0);
    }

    /// The bucket arithmetic, which is the only place this can be quietly wrong: every sample has
    /// to land in exactly one bucket, and the last bucket has to reach the last sample.
    #[test]
    fn every_sample_lands_in_exactly_one_bucket() {
        for samples in [1usize, 7, 512, 513, 5000] {
            for buckets in [1usize, 8, 512] {
                let mut covered = vec![0u32; samples];
                for i in 0..buckets {
                    let from = samples * i / buckets;
                    let to = (samples * (i + 1) / buckets).max(from + 1).min(samples);
                    for s in from..to {
                        covered[s] += 1;
                    }
                }
                assert!(
                    covered.iter().all(|c| *c >= 1),
                    "{samples} samples in {buckets} buckets left a gap"
                );
            }
        }
    }

    /// A sound that is louder in the middle than at its ends draws that way -- which is the only
    /// property anybody actually looks at a waveform for.
    #[test]
    fn a_shape_is_a_shape() {
        let mut pcm = tone(1600, 2000);
        pcm.extend(tone(1600, 30000));
        pcm.extend(tone(1600, 2000));
        let peaks = peaks_of(&pcm, 9);
        assert!(peaks[4] > peaks[0] * 4, "{peaks:?}");
        assert!(peaks[4] > peaks[8] * 4, "{peaks:?}");
    }

    #[test]
    fn a_sound_that_is_not_there_says_so_once() {
        let shapes = Waveforms::new();
        let missing = std::env::temp_dir().join("moonsplice-no-such-sound.wav");
        let _ = std::fs::remove_file(&missing);
        assert!(shapes.of(&missing).is_err());
        assert_eq!(shapes.held(), 0);
        assert!(shapes.ready(&missing).is_none());
    }

    /// The real thing, against a real file: the piano roll the eval suite already carries.
    #[test]
    fn a_real_sound_is_read_once_and_kept() {
        let Some(root) = crate::engine::moonsplice_root() else {
            eprintln!("skipped: no checkout found");
            return;
        };
        let piano = root.join("comps/assets/piano.ogg");
        if !piano.is_file() {
            eprintln!("skipped: no piano.ogg");
            return;
        }
        let shapes = Waveforms::new();
        let first = match shapes.of(&piano) {
            Ok(p) => p,
            Err(why) => {
                eprintln!("skipped: {why}");
                return;
            }
        };
        assert_eq!(first.len(), BUCKETS);
        assert!(first.iter().any(|p| *p > 60), "a piano roll is not silence");
        assert!(
            first.iter().any(|p| *p < 250),
            "and it is not a solid block either"
        );

        // Asked again, it is the same object and nothing was read.
        let again = shapes.of(&piano).unwrap();
        assert!(Arc::ptr_eq(&first, &again));
        assert_eq!(shapes.held(), 1);
        assert!(shapes.ready(&piano).is_some());
    }
}
