use super::*;

// ------------------------------------------------------------------------------- commands

pub(super) fn init(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let dir = a.words.first().ok_or("say where the project goes: moonsplice-agent init DIR")?;
    let footage: Vec<PathBuf> = a.all("--footage").into_iter().map(PathBuf::from).collect();
    let comp = a.get(&["--comp", "-c"]).unwrap_or_else(|| "Main".into());
    let size = match a.get(&["--size"]) {
        None => (1920, 1080),
        Some(s) => {
            let (w, h) = s.split_once(['x', 'X']).ok_or("--size is WIDTHxHEIGHT, like 1920x1080")?;
            (
                w.parse().map_err(|_| "--size is WIDTHxHEIGHT")?,
                h.parse().map_err(|_| "--size is WIDTHxHEIGHT")?,
            )
        }
    };
    let fps = a.num(&["--fps"])?.unwrap_or(30.0);
    let duration = a.num(&["--duration"])?.unwrap_or(10.0);
    let made = headless::init(Path::new(dir), &footage, &comp, size, fps, duration)?;
    println!("{}", serde_json::to_string_pretty(&made).unwrap());
    Ok(ExitCode::SUCCESS)
}

pub(super) fn tools(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let list = agent::list_tools(&paths(&a)?)?;
    if a.has(&["--json"]) {
        println!("{}", serde_json::to_string_pretty(&list).unwrap());
        return Ok(ExitCode::SUCCESS);
    }
    println!(
        "{} — {} tools, {} steps a turn, model {}\n",
        list["agent"].as_str().unwrap_or("agent"),
        list["tools"].as_array().map(|t| t.len()).unwrap_or(0),
        list["budget"],
        list["model"].as_str().unwrap_or("?"),
    );
    for t in list["tools"].as_array().cloned().unwrap_or_default() {
        println!(
            "{}{}\n  {}",
            t["name"].as_str().unwrap_or(""),
            if t["asks_first"].as_bool().unwrap_or(false) { "  (changes the composition)" } else { "" },
            t["description"].as_str().unwrap_or("")
        );
        let req: Vec<String> = t["input_schema"]["required"]
            .as_array()
            .map(|r| r.iter().filter_map(|v| v.as_str().map(String::from)).collect())
            .unwrap_or_default();
        if let Some(props) = t["input_schema"]["properties"].as_object() {
            for (k, p) in props {
                println!(
                    "    {k}{} ({}) — {}",
                    if req.contains(k) { "" } else { "?" },
                    p["type"].as_str().unwrap_or(""),
                    p["description"].as_str().unwrap_or("").split_whitespace().collect::<Vec<_>>().join(" ")
                );
            }
        }
        println!();
    }
    Ok(ExitCode::SUCCESS)
}

pub(super) fn call(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let tool = a.words.first().ok_or("say which tool: moonsplice-agent call TOOL '{...}' --project DIR")?;
    let args: serde_json::Value = match a.words.get(1) {
        None => serde_json::json!({}),
        Some(s) if s == "-" => {
            let mut text = String::new();
            std::io::Read::read_to_string(&mut std::io::stdin(), &mut text).map_err(|e| e.to_string())?;
            serde_json::from_str(&text).map_err(|e| format!("the arguments are not JSON ({e})"))?
        }
        Some(s) => serde_json::from_str(s).map_err(|e| format!("the arguments are not JSON ({e})"))?,
    };
    let paths = paths(&a)?;
    let s = Arc::new(session(&a)?);
    let out = agent::call_tool(&paths, s.clone(), tool, args);
    s.close();
    match out {
        Ok(text) => {
            println!("{text}");
            Ok(ExitCode::SUCCESS)
        }
        Err(why) => {
            println!("{why}");
            Ok(ExitCode::from(1))
        }
    }
}

pub(super) fn render(raw: &[String]) -> Result<ExitCode, String> {
    let a = Args::parse(raw);
    let project = a.get(&["--project", "-p"]).ok_or("say which project with --project DIR")?;
    let root_dir = Path::new(&project).canonicalize().map_err(|e| format!("{project}: {e}"))?;
    let p = moonsplice_studio_lib::project::Project::open(&root_dir).map_err(|e| e.to_string())?;
    let variation = headless::pick_variation(&p, a.get(&["--comp", "-c"]).as_deref())?;
    let comp = p.source_of(&variation).ok_or("that composition is not in this project")?;
    let rel = comp.strip_prefix(&root_dir).unwrap_or(&comp).to_path_buf();
    let out = match a.get(&["-o", "--out"]) {
        Some(o) => {
            let o = PathBuf::from(o);
            if o.is_absolute() { o } else { std::env::current_dir().map_err(|e| e.to_string())?.join(o) }
        }
        None => root_dir.join("exports").join(format!("{variation}.mp4")),
    };
    if let Some(d) = out.parent() {
        std::fs::create_dir_all(d).map_err(|e| e.to_string())?;
    }
    let quality = a.get(&["--quality", "-q"]).unwrap_or_else(|| "standard".into());
    let mut cmd = std::process::Command::new(root()?.join("moonsplice"));
    cmd.arg("render").arg(&rel).arg("-o").arg(&out).current_dir(&root_dir).env("MOONSPLICE_QUALITY", &quality);
    if let Some(f) = a.get(&["--fps"]) {
        cmd.arg("--fps").arg(f);
    }
    let started = Instant::now();
    let status = cmd.status().map_err(|e| format!("the renderer did not start ({e})"))?;
    if !status.success() {
        return Err("the render failed (the renderer's own message is above)".into());
    }
    let summary = serde_json::json!({
        "out": out,
        "comp": variation,
        "quality": quality,
        "elapsed_s": (started.elapsed().as_secs_f64() * 10.0).round() / 10.0,
        "duration_s": headless::media_duration(&out).ok(),
    });
    println!("{}", serde_json::to_string_pretty(&summary).unwrap());
    Ok(ExitCode::SUCCESS)
}
