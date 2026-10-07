//! The frame queue: the picture first, and each frame rendered once.
//!
//! Three things were wrong with answering frame requests where they arrive.
//!
//! The first is the thread. A custom scheme handler runs on the webview's own thread, so a
//! request that waits 40 ms for a render is 40 ms in which the window does not scroll, the
//! timeline does not drag and a button does not light up. It reads as the whole app fighting the
//! scrub, and it is not the renderer's fault: the renderer was never asked to be quick, it was
//! asked on the wrong thread.
//!
//! The second is the order. `player.ts` warms the next six frames while playing, so six requests
//! for frames nobody is looking at yet arrive alongside the one frame somebody is. First come,
//! first served means the frame on screen waits behind six speculative ones -- the playhead is
//! then permanently a third of a second behind, and warming, which exists to make playback
//! smooth, is what made it choppy.
//!
//! The third is duplication. The same frame is asked for twice often enough to matter: warmed,
//! then wanted; or asked for by two panes at the same size. Two requests for one frame should be
//! one render and two answers.
//!
//! So: a small pool of workers, two queues, live before warm, and one job per frame with as many
//! waiters as asked. Warm work is also capped -- a queue of stale speculation is not an asset --
//! and yields while anything live is outstanding.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Condvar, Mutex};

use crate::frames::{Frame, FrameKey};

/// What a waiter is handed when the frame is ready. One per request, called exactly once.
pub type Reply = Box<dyn FnOnce(Result<Frame, String>) + Send>;

/// How a frame is actually made. The queue knows nothing about engines or codecs; the `Instant`
/// is when the request arrived, so what it spent waiting here is recorded as waiting rather than
/// as rendering.
pub type Render =
    Arc<dyn Fn(&FrameKey, bool, std::time::Instant) -> Result<Frame, String> + Send + Sync>;

/// Warm work worth keeping. Six frames ahead is what the player asks for; twelve queued means
/// the playhead has moved on from the oldest of them and they are waste.
const WARM_DEPTH: usize = 12;

struct Job {
    live: bool,
    /// When the first request for this frame arrived.
    asked: std::time::Instant,
    waiters: Vec<Reply>,
}

struct Q {
    live: VecDeque<FrameKey>,
    warm: VecDeque<FrameKey>,
    jobs: HashMap<FrameKey, Job>,
    /// Live frames claimed by a worker but not yet finished. Warm work waits on this, which is
    /// what makes the picture win a tie.
    rendering_live: usize,
    stop: bool,
}

pub struct FrameQueue {
    q: Mutex<Q>,
    /// Work arrived, or a live render finished.
    wake: Condvar,
    workers: Mutex<Vec<std::thread::JoinHandle<()>>>,
}

impl FrameQueue {
    /// `workers` threads calling `render`. Two is the useful number today: the engine serialises
    /// renders anyway, so the second thread is there to encode one frame while another waits.
    pub fn start(workers: usize, render: Render) -> Arc<FrameQueue> {
        let queue = Arc::new(FrameQueue {
            q: Mutex::new(Q {
                live: VecDeque::new(),
                warm: VecDeque::new(),
                jobs: HashMap::new(),
                rendering_live: 0,
                stop: false,
            }),
            wake: Condvar::new(),
            workers: Mutex::new(Vec::new()),
        });
        let mut handles = Vec::new();
        for i in 0..workers.max(1) {
            let q = queue.clone();
            let r = render.clone();
            handles.push(
                std::thread::Builder::new()
                    .name(format!("frames-{i}"))
                    .spawn(move || q.work(r))
                    .expect("a frame worker"),
            );
        }
        *queue.workers.lock().expect("workers") = handles;
        queue
    }

    /// Ask for a frame. `live` means something is waiting to look at it.
    pub fn want(&self, key: FrameKey, live: bool, reply: Reply) {
        let mut q = self.q.lock().expect("queue");
        if q.stop {
            drop(q);
            reply(Err("the app is closing".into()));
            return;
        }
        if let Some(job) = q.jobs.get_mut(&key) {
            // Already on its way. A live request for a frame being warmed promotes it, because
            // the reason it was warmed has arrived.
            job.waiters.push(reply);
            if live && !job.live {
                job.live = true;
                q.warm.retain(|k| k != &key);
                q.live.push_back(key);
                self.wake.notify_all();
            }
            return;
        }
        q.jobs.insert(
            key.clone(),
            Job {
                live,
                asked: std::time::Instant::now(),
                waiters: vec![reply],
            },
        );
        if live {
            q.live.push_back(key);
        } else {
            q.warm.push_back(key);
            while q.warm.len() > WARM_DEPTH {
                if let Some(old) = q.warm.pop_front() {
                    if let Some(job) = q.jobs.remove(&old) {
                        // Dropped speculation is not an error anybody should see: the answer is
                        // that this frame was not made, and nothing was waiting on it.
                        drop(q);
                        for w in job.waiters {
                            w(Err("that frame was overtaken".into()));
                        }
                        q = self.q.lock().expect("queue");
                    }
                }
            }
        }
        self.wake.notify_all();
    }

    /// How many frames the picture is waiting for. The player uses this to stop asking for more
    /// than the renderer can make.
    pub fn live_waiting(&self) -> usize {
        let q = self.q.lock().expect("queue");
        q.live.len() + q.rendering_live
    }

    pub fn stop(&self) {
        let mut q = self.q.lock().expect("queue");
        q.stop = true;
        let jobs: Vec<Job> = q.jobs.drain().map(|(_, j)| j).collect();
        q.live.clear();
        q.warm.clear();
        drop(q);
        self.wake.notify_all();
        for job in jobs {
            for w in job.waiters {
                w(Err("the app is closing".into()));
            }
        }
    }

    fn work(&self, render: Render) {
        loop {
            let (key, live, asked) = {
                let mut q = self.q.lock().expect("queue");
                loop {
                    if q.stop {
                        return;
                    }
                    if let Some(k) = q.live.pop_front() {
                        q.rendering_live += 1;
                        let asked = q.jobs.get(&k).map(|j| j.asked).unwrap_or_else(std::time::Instant::now);
                        break (k, true, asked);
                    }
                    // Warm work waits while the picture is waiting. Not a lock -- a look, every
                    // time round -- so a warm frame starts the moment the live one is claimed.
                    if q.rendering_live == 0 {
                        if let Some(k) = q.warm.pop_front() {
                            let asked =
                                q.jobs.get(&k).map(|j| j.asked).unwrap_or_else(std::time::Instant::now);
                            break (k, false, asked);
                        }
                    }
                    q = self.wake.wait(q).expect("queue");
                }
            };

            let made = render(&key, live, asked);

            let job = {
                let mut q = self.q.lock().expect("queue");
                if live {
                    q.rendering_live = q.rendering_live.saturating_sub(1);
                }
                q.jobs.remove(&key)
            };
            // Waking after the job leaves the map, so a warm worker sees an empty live queue.
            self.wake.notify_all();
            if let Some(job) = job {
                for w in job.waiters {
                    w(made.clone());
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::sync::mpsc;
    use std::time::Duration;

    fn key(t: u32) -> FrameKey {
        FrameKey {
            variation: "v1".into(),
            hash: "h".into(),
            t_ms: t,
            w: 960,
            h: 540,
            raw: true,
        }
    }

    fn frame(n: usize) -> Frame {
        Frame {
            bytes: Arc::new(vec![7u8; n]),
            w: 960,
            h: 540,
        }
    }

    #[test]
    fn the_picture_is_served_before_anything_warmed() {
        // One worker, so the order is the queue's order and nothing else. The first job blocks
        // until told, which is how six warm requests get to be waiting when a live one arrives.
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let gate = Mutex::new(gate_rx);
        let order = Arc::new(Mutex::new(Vec::<u32>::new()));
        let seen = order.clone();
        let q = FrameQueue::start(
            1,
            Arc::new(move |k: &FrameKey, _: bool, _: std::time::Instant| {
                if k.t_ms == 0 {
                    let _ = gate.lock().unwrap().recv_timeout(Duration::from_secs(5));
                }
                seen.lock().unwrap().push(k.t_ms);
                Ok(frame(16))
            }),
        );

        let (tx, rx) = mpsc::channel();
        let done = move |t: u32| {
            let tx = tx.clone();
            Box::new(move |r: Result<Frame, String>| {
                let _ = tx.send((t, r.is_ok()));
            }) as Reply
        };

        q.want(key(0), false, done(0)); // taken by the worker at once, and blocks there
        std::thread::sleep(Duration::from_millis(30));
        for t in [100, 200, 300] {
            q.want(key(t), false, done(t));
        }
        q.want(key(900), true, done(900));
        let _ = gate_tx.send(());

        let mut got = Vec::new();
        for _ in 0..5 {
            got.push(rx.recv_timeout(Duration::from_secs(5)).expect("a reply").0);
        }
        q.stop();
        assert_eq!(got[0], 0, "the one already in hand finishes");
        assert_eq!(got[1], 900, "then the frame somebody is looking at");
        assert_eq!(&got[2..], &[100, 200, 300], "and the speculation after it");
        assert_eq!(*order.lock().unwrap(), vec![0, 900, 100, 200, 300]);
    }

    #[test]
    fn one_frame_asked_for_twice_is_rendered_once() {
        let renders = Arc::new(AtomicUsize::new(0));
        let n = renders.clone();
        let (gate_tx, gate_rx) = mpsc::channel::<()>();
        let gate = Mutex::new(gate_rx);
        let q = FrameQueue::start(
            2,
            Arc::new(move |_: &FrameKey, _: bool, _: std::time::Instant| {
                let _ = gate.lock().unwrap().recv_timeout(Duration::from_secs(5));
                n.fetch_add(1, Ordering::SeqCst);
                Ok(frame(32))
            }),
        );
        let (tx, rx) = mpsc::channel();
        for _ in 0..4 {
            let tx = tx.clone();
            q.want(
                key(500),
                true,
                Box::new(move |r| {
                    let _ = tx.send(r.map(|f| f.bytes.len()));
                }),
            );
        }
        let _ = gate_tx.send(());
        for _ in 0..4 {
            assert_eq!(
                rx.recv_timeout(Duration::from_secs(5)).expect("a reply"),
                Ok(32),
                "every waiter got the frame"
            );
        }
        q.stop();
        assert_eq!(renders.load(Ordering::SeqCst), 1, "and it was made once");
    }

    #[test]
    fn a_frame_wanted_while_it_is_being_warmed_is_not_made_twice() {
        let renders = Arc::new(AtomicUsize::new(0));
        let n = renders.clone();
        let q = FrameQueue::start(
            2,
            Arc::new(move |_: &FrameKey, _: bool, _: std::time::Instant| {
                n.fetch_add(1, Ordering::SeqCst);
                std::thread::sleep(Duration::from_millis(20));
                Ok(frame(8))
            }),
        );
        let (tx, rx) = mpsc::channel();
        for live in [false, true] {
            let tx = tx.clone();
            q.want(
                key(700),
                live,
                Box::new(move |r| {
                    let _ = tx.send(r.is_ok());
                }),
            );
        }
        for _ in 0..2 {
            assert!(rx.recv_timeout(Duration::from_secs(5)).expect("a reply"));
        }
        q.stop();
        assert_eq!(renders.load(Ordering::SeqCst), 1);
    }

    #[test]
    fn stale_speculation_is_dropped_rather_than_queued_forever() {
        // Nothing is rendering, so everything queues; past the depth, the oldest warm frames are
        // let go, because by the time a worker reached them the playhead would be elsewhere.
        let q = FrameQueue::start(
            1,
            Arc::new(|_: &FrameKey, _: bool, _: std::time::Instant| {
                std::thread::sleep(Duration::from_millis(500));
                Ok(frame(4))
            }),
        );
        let (tx, rx) = mpsc::channel();
        for t in 0..(WARM_DEPTH as u32 + 6) {
            let tx = tx.clone();
            q.want(
                key(t * 33),
                false,
                Box::new(move |r| {
                    let _ = tx.send((t, r.is_ok()));
                }),
            );
        }
        let mut overtaken = 0;
        for _ in 0..5 {
            let (_, ok) = rx.recv_timeout(Duration::from_secs(5)).expect("an answer");
            if !ok {
                overtaken += 1;
            }
        }
        q.stop();
        assert_eq!(overtaken, 5, "the oldest speculation was let go, and said so");
    }
}
