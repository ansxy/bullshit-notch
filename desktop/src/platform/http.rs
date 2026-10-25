//! Shared HTTP agent: rustls on Linux, SChannel (native-tls) on Windows.

use std::time::Duration;

pub fn agent() -> ureq::Agent {
    let b = ureq::AgentBuilder::new().timeout(Duration::from_secs(8));
    #[cfg(windows)]
    let b = match native_tls::TlsConnector::new() {
        Ok(c) => b.tls_connector(std::sync::Arc::new(c)),
        Err(_) => b,
    };
    b.build()
}

/// GET into memory, capped at `max` bytes.
pub fn get_bytes(url: &str, max: u64) -> Option<Vec<u8>> {
    let resp = agent().get(url).call().ok()?;
    let mut buf = Vec::new();
    std::io::Read::read_to_end(&mut std::io::Read::take(resp.into_reader(), max), &mut buf).ok()?;
    Some(buf)
}
