use super::*;

fn github() -> Needs {
    one(r#"{"docs":"https://docs.github.com/rest","fields":[{"label":"token","name":"GITHUB_TOKEN","secret":true}],
            "missing":["GITHUB_TOKEN"],"name":"GitHub","service":"github"}"#)
    .unwrap()
}

fn values(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
}

#[test]
fn no_asks_reads_as_none_however_the_command_line_spells_it() {
    assert_eq!(rows::<ConnectAsk>("{}\n").unwrap(), vec![]);
    assert_eq!(rows::<ConnectAsk>("[]").unwrap(), vec![]);
    assert!(rows::<ConnectAsk>("not json").is_err());
    // An object with keys is not an empty array; it is a mistake, and said as one.
    assert!(rows::<ConnectAsk>(r#"{"id":"x"}"#).is_err());
}

#[test]
fn each_kind_of_ask_reads_whole() {
    let asks: Vec<ConnectAsk> = rows(
        r#"[{"id":"connect-acme-1","kind":"connect","service":"acme","name":"Acme",
             "fields":[{"name":"ACME_TOKEN","label":"API token","secret":true},{"name":"ACME_ORG","label":"org"}],
             "docs":"https://acme.test/docs","why":"to fetch the chart","at":"2026-10-07T10:00:00Z","status":"open"},
            {"id":"approve-acme-2","kind":"approve","service":"acme","name":"Acme","op":"acme.post_item",
             "method":"POST","fields":{},"at":"2026-10-07T10:01:00Z","status":"open"}]"#,
    )
    .unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(asks.len(), 2);
    assert_eq!(asks[0].fields[0], Field { name: "ACME_TOKEN".into(), label: "API token".into(), secret: true });
    assert!(!asks[0].fields[1].secret, "a field that does not say it is secret is not");
    assert_eq!(asks[1].op.as_deref(), Some("acme.post_item"));
    assert_eq!(asks[1].method.as_deref(), Some("POST"));
    assert!(asks[1].fields.is_empty(), "an empty field list may arrive as {{}}");
}

#[test]
fn connections_finds_records_and_answers_read() {
    let list: Vec<Connection> =
        rows(r#"[{"service":"github","fields":["GITHUB_TOKEN"],"at":"2026-10-07T10:00:00Z"}]"#).unwrap();
    assert_eq!(list[0].fields, vec!["GITHUB_TOKEN".to_string()]);
    let found: Vec<Found> = rows(
        r#"[{"categories":["dev-tools"],"docs":"https://docs.github.com/rest","name":"GitHub","operations":1201,
             "service":"github"}]"#,
    )
    .unwrap();
    assert_eq!((found[0].name.as_str(), found[0].operations), ("GitHub", 1201));
    let rec: Recorded = one(r#"{"service":"github","fields":["GITHUB_TOKEN"],"checked":false}"#).unwrap();
    assert!(!rec.checked);
    let ans: Answered = one(r#"{"service":"acme","op":"acme.post_item","answer":"always"}"#).unwrap();
    assert_eq!(ans.answer, "always");
    assert_eq!(github().missing, vec!["GITHUB_TOKEN".to_string()]);
}

#[test]
fn save_refuses_a_field_the_service_does_not_take_before_writing_anything() {
    let mut wrote = Vec::new();
    let r = save_with(
        "github",
        &values(&[("GITHUB_TOKEN", "ghp_x"), ("AWS_SECRET_ACCESS_KEY", "y")]),
        &github(),
        |n, _| {
            wrote.push(n.to_string());
            Ok(())
        },
    );
    let why = r.unwrap_err();
    assert!(why.contains("AWS_SECRET_ACCESS_KEY"), "{why}");
    assert!(!why.contains("ghp_x"), "a refusal never repeats a value");
    assert!(wrote.is_empty(), "nothing is stored when any name is wrong: {wrote:?}");
}

#[test]
fn save_writes_exactly_the_fields_given_under_their_names() {
    let mut wrote = Vec::new();
    save_with("github", &values(&[("GITHUB_TOKEN", "ghp_x")]), &github(), |n, v| {
        wrote.push((n.to_string(), v.to_string()));
        Ok(())
    })
    .unwrap();
    assert_eq!(wrote, vec![("GITHUB_TOKEN".to_string(), "ghp_x".to_string())]);
}

#[test]
fn save_refuses_nothing_an_empty_value_and_another_services_fields() {
    let never = |_: &str, _: &str| -> Result<(), String> { panic!("nothing should be written") };
    assert!(save_with("github", &values(&[]), &github(), never).is_err());
    let why = save_with("github", &values(&[("GITHUB_TOKEN", "  ")]), &github(), never).unwrap_err();
    assert!(why.contains("token"), "{why}");
    assert!(save_with("gitlab", &values(&[("GITHUB_TOKEN", "x")]), &github(), never).is_err());
    assert!(save_with("../github", &values(&[("GITHUB_TOKEN", "x")]), &github(), never).is_err());
}

#[test]
fn names_that_become_arguments_or_paths_are_checked() {
    for good in ["github", "1password-events", "google.sheets", "x_y"] {
        assert!(service_name(good).is_ok(), "{good}");
    }
    for bad in ["", "..", "../etc", "a/b", "-rf", "--json", "a b", ".hidden"] {
        assert!(service_name(bad).is_err(), "{bad:?}");
    }
    assert!(op_name("acme", "acme.post_item").is_ok());
    assert!(op_name("acme", "other.post_item").is_err(), "an approval is for the service's own call");
    assert!(op_name("acme", "acme.").is_err());
    assert!(op_name("acme", "acme.x --always").is_err());
    assert_eq!(answer_flag("once"), Ok("--once"));
    assert_eq!(answer_flag("always"), Ok("--always"));
    assert_eq!(answer_flag("deny"), Ok("--deny"));
    assert!(answer_flag("yes").is_err());
}

#[test]
fn the_command_lines_sentence_comes_back_without_its_name() {
    assert_eq!(said("moonsplice connect: GitHub still lacks GITHUB_TOKEN\n"), "GitHub still lacks GITHUB_TOKEN");
    assert_eq!(said(""), "the connect command failed");
}

/// The real command line, read-only: what connecting GitHub takes, and finding it by name.
#[test]
fn the_directory_answers_through_the_command_line() {
    let needs = needs_now("github").unwrap_or_else(|e| panic!("{e}"));
    assert_eq!(needs.name, "GitHub");
    assert!(needs.fields.iter().any(|f| f.name == "GITHUB_TOKEN" && f.secret));
    let found: Vec<Found> = rows(&connect(&["--find", "github"]).unwrap()).unwrap();
    assert!(found.iter().any(|f| f.service == "github"));
}
