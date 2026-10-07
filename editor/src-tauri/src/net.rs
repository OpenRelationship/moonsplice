//! The transport: one blocking HTTP call, and nothing else.
//!
//! This is the port `.robot/docs/desktop.robot` §6 says lives on the Rust side and is handed in. It
//! knows a URL, a method, headers and a body. It does not know what OpenRouter is, does not
//! retry, does not stream and does not decide what a failure means — `src/provider.lua` owns
//! all four, and duplicating any of them here would be a second place for them to drift.

use std::time::Duration;

/// `{ url, method, headers, body, timeout }`, as `spec/provider.md` §3 gives it.
#[derive(Debug, Clone, serde::Deserialize)]
pub struct Request {
    pub url: String,
    #[serde(default)]
    pub method: Option<String>,
    #[serde(default)]
    pub headers: std::collections::HashMap<String, String>,
    #[serde(default)]
    pub body: Option<String>,
    #[serde(default)]
    pub timeout: Option<f64>,
}

#[derive(Debug, Clone, serde::Serialize)]
pub struct Response {
    pub status: u16,
    pub headers: std::collections::HashMap<String, String>,
    pub body: String,
}

/// One of `port.codes`. Anything outside that set is a bug in this file.
#[derive(Debug, Clone, serde::Serialize)]
pub struct PortError {
    pub port: &'static str,
    pub call: &'static str,
    pub code: &'static str,
    pub message: String,
}

fn fail(code: &'static str, message: String) -> PortError {
    PortError {
        port: "net",
        call: "fetch",
        code,
        message,
    }
}

const MAX_BODY: usize = 16 * 1024 * 1024;

pub fn fetch(req: Request) -> Result<Response, PortError> {
    if req.url.is_empty() {
        return Err(fail("malformed", "a request with no url".into()));
    }
    let secs = req.timeout.unwrap_or(60.0).clamp(1.0, 600.0);
    let client = reqwest::blocking::Client::builder()
        .timeout(Duration::from_secs_f64(secs))
        .build()
        .map_err(|e| fail("unavailable", e.to_string()))?;
    let method = reqwest::Method::from_bytes(
        req.method.as_deref().unwrap_or("POST").to_uppercase().as_bytes(),
    )
    .map_err(|_| fail("malformed", "that is not an HTTP method".into()))?;
    let mut rb = client.request(method, &req.url);
    for (k, v) in &req.headers {
        rb = rb.header(k, v);
    }
    if let Some(body) = req.body {
        rb = rb.body(body);
    }
    let res = rb.send().map_err(|e| {
        if e.is_timeout() {
            fail("timeout", "the model did not answer in time".into())
        } else {
            fail("unavailable", e.to_string())
        }
    })?;
    let status = res.status().as_u16();
    let mut headers = std::collections::HashMap::new();
    for (k, v) in res.headers() {
        if let Ok(s) = v.to_str() {
            headers.insert(k.as_str().to_ascii_lowercase(), s.to_string());
        }
    }
    let bytes = res
        .bytes()
        .map_err(|e| fail("unavailable", e.to_string()))?;
    if bytes.len() > MAX_BODY {
        return Err(fail("too_big", format!("{} bytes", bytes.len())));
    }
    Ok(Response {
        status,
        headers,
        body: String::from_utf8_lossy(&bytes).to_string(),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn req(url: &str) -> Request {
        Request {
            url: url.into(),
            method: None,
            headers: Default::default(),
            body: None,
            timeout: Some(2.0),
        }
    }

    #[test]
    fn a_request_with_no_url_is_malformed_not_a_panic() {
        let e = fetch(req("")).unwrap_err();
        assert_eq!(e.code, "malformed");
        assert_eq!(e.port, "net");
    }

    #[test]
    fn a_bad_method_is_malformed() {
        let mut r = req("https://example.invalid/");
        r.method = Some("not a method".into());
        assert_eq!(fetch(r).unwrap_err().code, "malformed");
    }

    #[test]
    fn a_host_that_is_not_there_is_unavailable_and_says_so_once() {
        // .invalid never resolves (RFC 2606), so this needs no network to be deterministic.
        let e = fetch(req("https://moonsplice.invalid/v1")).unwrap_err();
        assert_eq!(e.code, "unavailable");
        assert!(!e.message.is_empty());
    }
}
