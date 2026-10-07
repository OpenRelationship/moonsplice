//! moonsplice-solid TREE.json OUT.msh     build a solid tree; prints its measurements as JSON
//! (OUT.gltf is written beside OUT.msh). A malformed tree prints {"error": ...} and exits 1.

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.len() != 2 {
        eprintln!("usage: moonsplice-solid TREE.json OUT.msh");
        std::process::exit(2);
    }
    let r = (|| -> anyhow::Result<serde_json::Value> {
        let tree: serde_json::Value = serde_json::from_str(&std::fs::read_to_string(&args[0])?)?;
        moonsplice_solid::build(&tree, std::path::Path::new(&args[1]))
    })();
    match r {
        Ok(v) => println!("{v}"),
        Err(e) => {
            println!("{}", serde_json::json!({ "error": e.to_string() }));
            std::process::exit(1);
        }
    }
}
