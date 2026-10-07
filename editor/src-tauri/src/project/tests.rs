use super::*;
use tempfile::tempdir;

#[test]
fn a_path_becomes_words() {
    assert_eq!(humanise("assets/footage/handoff_take_02.mp4"), "Handoff take 02");
    assert_eq!(humanise("comps/heroCutdown.lua"), "HeroCutdown".replace("roC", "ro C"));
    assert_eq!(humanise("x/.hidden"), "Hidden".replace("Hidden", "Hidden"));
}

#[test]
fn an_aspect_reads_as_a_shape() {
    assert_eq!(aspect_of(1920, 1080), "16:9");
    assert_eq!(aspect_of(1080, 1920), "9:16");
    assert_eq!(aspect_of(1080, 1080), "1:1");
    assert_eq!(aspect_word("9:16"), "Vertical");
}

#[test]
fn kinds_come_from_what_a_thing_is() {
    assert_eq!(AssetKind::of(Path::new("a.MOV")), AssetKind::Footage);
    assert_eq!(AssetKind::of(Path::new("a.woff2")), AssetKind::Font);
    assert_eq!(AssetKind::of(Path::new("a.zzz")), AssetKind::Other);
}

/// The shell decided that an export's result enters the project. It enters as the video a
/// person made, named after the composition, and exporting twice does not leave two of them.
#[test]
fn an_export_enters_the_project_as_the_video_it_is() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    p.add_composition("Hero", 1920, 1080, "").unwrap();
    std::fs::create_dir_all(dir.path().join("exports")).unwrap();
    std::fs::write(dir.path().join("exports/hero.mp4"), b"not really a video").unwrap();

    let a = p.add_export("exports/hero.mp4", "Hero").unwrap();
    assert_eq!(a.name, "Hero");
    assert_eq!(a.kind, AssetKind::Footage);
    assert_eq!(a.size, Some(18));
    assert_eq!(p.view().assets.len(), 1);

    // The same export again is the same video, made again.
    p.add_export("exports/hero.mp4", "Hero").unwrap();
    assert_eq!(p.view().assets.len(), 1);

    // And it is registered where it already is, not copied into `assets/`.
    assert!(!dir.path().join("assets/footage/hero.mp4").exists());
    assert_eq!(p.manifest.assets[0].source, "exports/hero.mp4");
}

/// What the export is called. A choice of shapes means the shape is part of the name, because
/// two files called "Motion" in the left pane are not two names.
#[test]
fn an_export_of_one_shape_among_several_says_which() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    let id = p.add_composition("Motion", 1920, 1080, "").unwrap();
    assert_eq!(p.title_of(&id).unwrap(), "Motion");
    let other = p.add_variation("motion", 1080, 1920).unwrap();
    assert_eq!(p.title_of(&other).unwrap(), "Motion Vertical");
    assert_eq!(p.title_of("nothing-like-it"), None);
}

#[test]
fn an_empty_composition_is_still_listed() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    p.add_composition("Hero", 1920, 1080, "").unwrap();
    let view = p.view();
    assert_eq!(view.compositions.len(), 1);
    assert!(view.compositions[0].variations[0].empty);
}

#[test]
fn a_new_variation_is_the_other_shape() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    let id = p.add_composition("Hero", 1920, 1080, "").unwrap();
    p.add_variation(&id, 1080, 1920).unwrap();
    let view = p.view();
    let titles: Vec<&str> = view.compositions[0]
        .variations
        .iter()
        .map(|v| v.title.as_str())
        .collect();
    assert_eq!(titles, vec!["Wide", "Vertical"]);
    // Beside the shape it came from, which is where the composition lives.
    let src = std::fs::read_to_string(dir.path().join("hero-9-16.lua")).unwrap();
    assert!(src.contains("width = 1080, height = 1920"));
}

#[test]
fn a_file_of_any_kind_becomes_an_asset() {
    let dir = tempdir().unwrap();
    let drop = dir.path().join("Some Thing.zzz");
    std::fs::write(&drop, b"x").unwrap();
    let proj = tempdir().unwrap();
    let mut p = Project::open(proj.path()).unwrap();
    // Into the folder it was dropped on, which here is the top of the project.
    let a = p.add_asset(&drop, "").unwrap();
    assert_eq!(a.kind, AssetKind::Other);
    assert_eq!(a.name, "Some Thing");
    assert!(proj.path().join("Some Thing.zzz").is_file());

    // And onto a folder, which is where a drop on a folder puts it.
    let other = dir.path().join("Another.zzz");
    std::fs::write(&other, b"x").unwrap();
    p.add_asset(&other, "Interviews").unwrap();
    assert!(proj.path().join("Interviews/Another.zzz").is_file());
}

/// Footage that arrived without the app looking is still footage.
///
/// Found by opening a ten minute project made outside the app: it held sixty clips and sound
/// files in two folders, and the pane showed none of them, because discovery only ever looked
/// in a folder called `assets`. The pane is the project's own directories now, so anything
/// the project can use, anywhere in it, is part of the project.
#[test]
fn footage_put_in_a_folder_by_hand_is_in_the_project() {
    let proj = tempdir().unwrap();
    std::fs::create_dir_all(proj.path().join("Footage")).unwrap();
    std::fs::create_dir_all(proj.path().join("Sound/Music")).unwrap();
    std::fs::write(proj.path().join("Footage/harbour.mp4"), b"x").unwrap();
    std::fs::write(proj.path().join("Sound/Music/bed.mp3"), b"x").unwrap();
    std::fs::write(proj.path().join("Sound/vo-01.mp3"), b"x").unwrap();
    // Not media, and not the app's business.
    std::fs::write(proj.path().join("Footage/notes.zzz"), b"x").unwrap();

    let p = Project::open(proj.path()).unwrap();
    let mut names: Vec<&str> = p.manifest.assets.iter().map(|a| a.name.as_str()).collect();
    names.sort();
    assert_eq!(names, vec!["Bed", "Harbour", "Vo 01"]);
    assert_eq!(
        p.manifest
            .assets
            .iter()
            .find(|a| a.name == "Harbour")
            .map(|a| a.kind),
        Some(AssetKind::Footage)
    );

    // Adopted once, not once per open, and the folders they are in are the folders they stay
    // in -- the tree is the directories, so nothing moved to be listed.
    let again = Project::open(proj.path()).unwrap();
    assert_eq!(again.manifest.assets.len(), 3);
    assert!(proj.path().join("Sound/Music/bed.mp3").is_file());
}

/// The pane is the project's own folders.
#[test]
fn the_tree_is_the_project_s_own_folders() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    p.add_composition("Opening", 1920, 1080, "").unwrap();
    p.add_composition("Vertical cut", 1080, 1920, "Cutdowns").unwrap();
    let clip = dir.path().join("day-one.mov");
    std::fs::write(&clip, b"x").unwrap();
    p.add_asset(&clip, "Interviews").unwrap();
    // A folder with nothing in it yet is still a folder.
    p.add_folder("", "Music").unwrap();

    let tree = p.view().tree;
    let names: Vec<String> = tree
        .iter()
        .map(|i| match i {
            Item::Folder { name, .. } => format!("{name}/"),
            Item::Composition { comp } => comp.title.clone(),
            Item::Asset { asset } => asset.name.clone(),
        })
        .collect();
    // Folders first, alphabetically, then the things at the top level.
    assert_eq!(names, vec!["Cutdowns/", "Interviews/", "Music/", "Opening"]);

    let Item::Folder { items, at, .. } = &tree[0] else {
        panic!("the first row is a folder");
    };
    assert_eq!(at, "Cutdowns");
    assert!(matches!(&items[0], Item::Composition { comp } if comp.title == "Vertical cut"));
    let Item::Folder { items, .. } = &tree[1] else {
        panic!("a folder");
    };
    assert!(matches!(&items[0], Item::Asset { asset } if asset.name == "Day one"));
    let Item::Folder { items, .. } = &tree[2] else {
        panic!("a folder");
    };
    assert!(items.is_empty(), "an empty folder is empty, not absent");

    // Nothing in the pane is a file name. Ids are still ids -- they are slugs of the name a
    // person reads, the same as everywhere else in the app, and nothing shows them.
    let json = serde_json::to_string(&p.view()).unwrap();
    for code in [".lua", ".mov", ".zzz"] {
        assert!(!json.contains(code), "`{code}` reached the pane: {json}");
    }
}

/// Dragging a thing into a folder moves it, and a composition takes every shape of itself.
#[test]
fn dragging_a_thing_into_a_folder_moves_the_file() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    let id = p.add_composition("Hero", 1920, 1080, "").unwrap();
    p.add_variation(&id, 1080, 1920).unwrap();
    assert!(dir.path().join("hero.lua").is_file());

    p.move_item(&id, "Cutdowns").unwrap();
    assert!(dir.path().join("Cutdowns/hero.lua").is_file());
    assert!(dir.path().join("Cutdowns/hero-9-16.lua").is_file());
    assert!(!dir.path().join("hero.lua").exists());
    // And the project still knows what it is, which is the point of moving the file rather
    // than remembering a folder somewhere.
    assert_eq!(p.source_of(&id).unwrap(), dir.path().join("Cutdowns/hero.lua"));
    assert_eq!(p.view().compositions.len(), 1);

    // Reopening reads the same thing back: the manifest and the folders agree.
    let again = Project::open(dir.path()).unwrap();
    assert_eq!(again.view().compositions.len(), 1);
    let tree = again.view().tree;
    assert!(matches!(&tree[0], Item::Folder { at, .. } if at == "Cutdowns"));
}

#[test]
fn renaming_a_folder_follows_its_files() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    p.add_composition("Hero", 1920, 1080, "Cutdowns").unwrap();
    let at = p.rename_folder("Cutdowns", "Social").unwrap();
    assert_eq!(at, "Social");
    assert!(dir.path().join("Social/hero.lua").is_file());
    assert_eq!(p.manifest.compositions[0].variations[0].source, "Social/hero.lua");
    // A folder that is already there is refused rather than merged into.
    p.add_folder("", "Music").unwrap();
    assert!(p.rename_folder("Social", "Music").is_err());
}

/// The folder is the truth: a composition copied in by hand is a composition, and one deleted
/// in the Finder is gone.
#[test]
fn the_folders_are_the_truth_when_the_app_was_not_looking() {
    let dir = tempdir().unwrap();
    let mut p = Project::open(dir.path()).unwrap();
    p.add_composition("Hero", 1920, 1080, "").unwrap();
    std::fs::create_dir_all(dir.path().join("Someone else")).unwrap();
    std::fs::write(
        dir.path().join("Someone else/brief.lua"),
        "return e.comp { width = 1080, height = 1080, scene = function(s) s:text{} end }",
    )
    .unwrap();

    let p2 = Project::open(dir.path()).unwrap();
    let titles: Vec<String> = p2.view().compositions.iter().map(|c| c.title.clone()).collect();
    assert!(titles.contains(&"Brief".to_string()), "adopted: {titles:?}");
    assert!(titles.contains(&"Hero".to_string()));

    std::fs::remove_file(dir.path().join("hero.lua")).unwrap();
    let p3 = Project::open(dir.path()).unwrap();
    let titles: Vec<String> = p3.view().compositions.iter().map(|c| c.title.clone()).collect();
    assert_eq!(titles, vec!["Brief"], "a deleted composition leaves the project");
    let _ = p;
}

#[test]
fn a_folder_of_comps_opens_without_a_manifest() {
    let dir = tempdir().unwrap();
    std::fs::create_dir_all(dir.path().join("comps")).unwrap();
    std::fs::write(
        dir.path().join("comps/hero.lua"),
        "return e.comp { width = 1080, height = 1920, scene = function(s) s:text{} end }",
    )
    .unwrap();
    let p = Project::open(dir.path()).unwrap();
    assert!(dir.path().join(MANIFEST).is_file());
    let v = p.view();
    assert_eq!(v.compositions.len(), 1);
    assert_eq!(v.compositions[0].variations[0].aspect, "9:16");
    assert!(!v.compositions[0].variations[0].empty);
}
