//! `serve`, inside the caller's process.
//!
//! The Studio used to spawn `moonsplice serve` per composition and talk to it over stdin and
//! stdout, with frames handed across in memory-mapped files. A [`Session`] runs the same
//! `core/runtime/serve.lua`, under the same boot, on a thread of the caller's own: requests go in over
//! a channel where stdin was, `CS` lines come back over another where stdout was, and a frame's
//! bytes are copied straight out of the rasterizer's buffer and kept under the path the reply
//! names (`ENGINE_HAND`, see serve.lua), where they used to be written to that path.
//!
//! Three things a process gave the runtime for free have to be given to it here, because they
//! belong to the whole process and there may be several sessions in it:
//! - `os.exit` would end the caller. It throws an `ENGINE_EXIT` instead, which the boot unwinds
//!   to its end (core/runtime/boot.lua), and the thread finishes with that status;
//! - the environment is the session's: `os.getenv` reads the session's own variables first, so
//!   each composition has its own `MOONSPLICE_CWD`, which is what every relative path in the
//!   runtime resolves against. The process's working directory is never changed;
//! - what the runtime writes to stderr -- why a composition would not open -- is kept, the last
//!   few lines of it, for the caller to read.

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;

use mlua::{Lua, Value, Variadic};

#[derive(Debug)]
pub enum SessionError {
    /// The thread would not start, or the host would not set up in it.
    Start(String),
    /// The session has ended: the composition would not load, or `quit` was asked.
    Gone(String),
}

impl std::fmt::Display for SessionError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SessionError::Start(m) | SessionError::Gone(m) => write!(f, "{m}"),
        }
    }
}

impl std::error::Error for SessionError {}

/// How many lines of stderr are kept: enough for an error and its first frames, bounded.
const SAID: usize = 40;

pub struct Session {
    requests: Option<Sender<String>>,
    replies: Mutex<Receiver<String>>,
    said: Arc<Mutex<Vec<String>>>,
    hand: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    thread: Option<JoinHandle<i32>>,
}

impl Session {
    /// Boot `core/runtime/main.lua` with `args` (`["--serve", "comp.lua"]`) on a thread of its own.
    /// `env` is what `os.getenv` answers first in this session.
    pub fn start(runtime: &Path, args: Vec<String>, env: Vec<(String, String)>) -> Result<Session, SessionError> {
        let (req_tx, req_rx) = channel::<String>();
        let (rep_tx, rep_rx) = channel::<String>();
        let said = Arc::new(Mutex::new(Vec::new()));
        let hand = Arc::new(Mutex::new(HashMap::new()));
        let runtime: PathBuf = runtime.to_path_buf();
        let (said_t, hand_t) = (said.clone(), hand.clone());
        let thread = std::thread::Builder::new()
            .name("moonsplice-session".into())
            // LuaJIT and the runtime recurse through the scene graph; a spawned thread's default
            // stack is a quarter of the main thread's.
            .stack_size(16 << 20)
            .spawn(move || {
                let keep = said_t.clone();
                let run = || -> Result<i32, String> {
                    let lua = crate::new_state(&runtime)?;
                    host_io(&lua, req_rx, rep_tx, said_t, hand_t, env).map_err(|e| e.to_string())?;
                    crate::boot(&lua, &runtime, args)
                };
                match run() {
                    Ok(code) => code,
                    Err(e) => {
                        push_said(&keep, &format!("moonsplice-engine: {e}"));
                        1
                    }
                }
            })
            .map_err(|e| SessionError::Start(e.to_string()))?;
        Ok(Session { requests: Some(req_tx), replies: Mutex::new(rep_rx), said, hand, thread: Some(thread) })
    }

    /// Run one command to its end (`["--render", "comp.lua", "-o", "out.mp4"]`) on a thread of its
    /// own, as `moonsplice` would in a process of its own: its status, and the last lines it
    /// wrote to stderr.
    pub fn run(runtime: &Path, args: Vec<String>, env: Vec<(String, String)>) -> Result<(i32, Vec<String>), SessionError> {
        let mut s = Session::start(runtime, args, env)?;
        let code = s.stop().ok_or_else(|| SessionError::Gone("the renderer stopped without a status".into()))?;
        Ok((code, s.said()))
    }

    /// One request line (serve.lua's JSON).
    pub fn send(&self, line: &str) -> Result<(), SessionError> {
        self.requests
            .as_ref()
            .ok_or_else(|| SessionError::Gone("the session was stopped".into()))?
            .send(line.to_string())
            .map_err(|_| SessionError::Gone("the renderer exited".into()))
    }

    /// The next `CS` line, without its prefix. `Gone` once the session has ended.
    pub fn recv(&self) -> Result<String, SessionError> {
        self.replies
            .lock()
            .unwrap()
            .recv()
            .map_err(|_| SessionError::Gone("the renderer exited".into()))
    }

    /// The bytes a reply named by path, taken (a slot is read once).
    pub fn take(&self, path: &str) -> Option<Vec<u8>> {
        self.hand.lock().unwrap().remove(path)
    }

    /// The last lines the runtime wrote to stderr.
    pub fn said(&self) -> Vec<String> {
        self.said.lock().unwrap().clone()
    }

    /// End the session: no more requests, then wait for the runtime to return. Its status.
    pub fn stop(&mut self) -> Option<i32> {
        self.requests.take();
        self.thread.take().and_then(|t| t.join().ok())
    }
}

/// Hangs up without waiting. A thread cannot be killed the way a child process could, so a
/// composition stuck in a loop must not hold up whoever drops its session: the runtime returns at
/// its next request, and a stuck one is left to the end of the process.
impl Drop for Session {
    fn drop(&mut self) {
        self.requests.take();
    }
}

fn push_said(said: &Mutex<Vec<String>>, text: &str) {
    let mut kept = said.lock().unwrap();
    for line in text.lines() {
        if kept.len() >= SAID {
            kept.remove(0);
        }
        kept.push(line.to_string());
    }
}

/// The process-wide things serve.lua reaches for, made the session's own (see the module comment).
fn host_io(
    lua: &Lua,
    requests: Receiver<String>,
    replies: Sender<String>,
    said: Arc<Mutex<Vec<String>>>,
    hand: Arc<Mutex<HashMap<String, Vec<u8>>>>,
    env: Vec<(String, String)>,
) -> mlua::Result<()> {
    let g = lua.globals();
    let io: mlua::Table = g.get("io")?;

    // stdin: one request per call, nil once the caller has hung up (serve.lua then returns)
    let requests = Mutex::new(requests);
    io.set("read", lua.create_function(move |_, _: Variadic<Value>| Ok(requests.lock().unwrap().recv().ok()))?)?;

    // stdout: whole lines; ours (`CS `) go to the caller, anything else is somebody's print
    let pending = Mutex::new(String::new());
    io.set(
        "write",
        lua.create_function(move |_, parts: Variadic<Value>| {
            let mut buf = pending.lock().unwrap();
            for p in parts.iter() {
                match p {
                    Value::String(s) => buf.push_str(&s.to_string_lossy()),
                    Value::Number(n) => buf.push_str(&n.to_string()),
                    Value::Integer(i) => buf.push_str(&i.to_string()),
                    _ => {}
                }
            }
            while let Some(i) = buf.find('\n') {
                let line: String = buf.drain(..=i).collect();
                let line = line.trim_end_matches(['\n', '\r']);
                match line.strip_prefix("CS ") {
                    Some(rest) => {
                        let _ = replies.send(rest.to_string());
                    }
                    None => println!("{line}"),
                }
            }
            Ok(())
        })?,
    )?;
    io.set("flush", lua.create_function(|_, _: Variadic<Value>| Ok(()))?)?;

    let said_fn = lua.create_function(move |_, text: String| {
        push_said(&said, &text);
        Ok(())
    })?;

    let hand_fn = lua.create_function(move |_, (path, v, size): (String, Value, Option<usize>)| {
        let bytes = match v {
            Value::String(s) => s.as_bytes().to_vec(),
            Value::Number(_) | Value::Integer(_) => {
                let addr = match v {
                    Value::Number(n) => n as usize,
                    Value::Integer(i) => i as usize,
                    _ => unreachable!(),
                };
                let n = size.unwrap_or(0);
                if addr == 0 || n == 0 {
                    return Err(mlua::Error::runtime("ENGINE_HAND: no bytes"));
                }
                // SAFETY: serve.lua passes the address and size of the frame it is holding, and
                // holds it for the length of this call.
                unsafe { std::slice::from_raw_parts(addr as *const u8, n) }.to_vec()
            }
            _ => return Err(mlua::Error::runtime("ENGINE_HAND: bytes or an address")),
        };
        hand.lock().unwrap().insert(path, bytes);
        Ok(())
    })?;
    g.set("ENGINE_HAND", hand_fn)?;

    let env_t = lua.create_table()?;
    for (k, v) in env {
        env_t.set(k, v)?;
    }

    lua.load(
        r##"
        local env, said = ...
        ENGINE_EXIT = { __tostring = function(e) return "exit " .. tostring(e.code) end }
        os.exit = function(c)
          if c == nil or c == true then c = 0 elseif c == false then c = 1 end
          error(setmetatable({ code = c }, ENGINE_EXIT), 0)
        end
        local getenv = os.getenv
        os.getenv = function(k)
          local v = env[k]
          if v ~= nil then return v end
          return getenv(k)
        end
        local err = {}
        function err:write(...)
          for i = 1, select("#", ...) do said(tostring((select(i, ...)))) end
          return self
        end
        function err:flush() return self end
        function err:close() return true end
        function err:setvbuf() return true end
        io.stderr = err
        "##,
    )
    .set_name("=engine/session")
    .call::<()>((env_t, said_fn))
}
