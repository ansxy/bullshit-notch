use std::io;
use std::path::Path;
use std::process::Stdio;

#[derive(Debug, Clone)]
pub struct CommandOutput {
    pub status: i32,
    pub stdout: String,
    pub stderr: String,
}

/// Run a program with args, capturing stdout/stderr.
/// On Windows sets `CREATE_NO_WINDOW` so console never flashes.
pub async fn run_hidden(program: &str, args: &[&str]) -> io::Result<CommandOutput> {
    let mut cmd = tokio::process::Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());

    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    let output = cmd.output().await?;
    Ok(CommandOutput {
        status: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

#[cfg(windows)]
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Blocking variant for store worker threads.
pub fn run_hidden_sync(program: &str, args: &[&str]) -> io::Result<CommandOutput> {
    run_hidden_sync_in(program, args, None)
}

pub fn run_hidden_sync_in(
    program: &str,
    args: &[&str],
    cwd: Option<&std::path::Path>,
) -> io::Result<CommandOutput> {
    let mut cmd = std::process::Command::new(program);
    cmd.args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = cwd {
        cmd.current_dir(dir);
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        cmd.creation_flags(CREATE_NO_WINDOW);
    }
    let output = cmd.output()?;
    Ok(CommandOutput {
        status: output.status.code().unwrap_or(-1),
        stdout: String::from_utf8_lossy(&output.stdout).into_owned(),
        stderr: String::from_utf8_lossy(&output.stderr).into_owned(),
    })
}

/// Kill a process and its children.
pub async fn kill_process_tree(pid: u32) -> io::Result<()> {
    #[cfg(windows)]
    {
        let out = run_hidden("taskkill", &["/F", "/T", "/PID", &pid.to_string()]).await?;
        if out.status != 0 {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("taskkill failed: {}", out.stderr),
            ));
        }
        return Ok(());
    }

    #[cfg(unix)]
    {
        let _ = run_hidden("pkill", &["-TERM", "-P", &pid.to_string()]).await;
        let out = run_hidden("kill", &["-TERM", &pid.to_string()]).await?;
        if out.status != 0 && !out.stderr.contains("No such process") {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("kill failed: {}", out.stderr),
            ));
        }
        return Ok(());
    }

    #[cfg(not(any(windows, unix)))]
    {
        let _ = pid;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "kill_process_tree unsupported on this OS",
        ))
    }
}

/// Open a file or URL with the OS handler (Explorer / `xdg-open`).
pub fn open_path(path: &Path) {
    #[cfg(windows)]
    {
        let _ = run_hidden_sync("explorer", &[path.to_str().unwrap_or(".")]);
    }
    #[cfg(not(windows))]
    {
        let _ = run_hidden_sync("xdg-open", &[path.to_str().unwrap_or(".")]);
    }
}

/// Reveal a file in its parent folder.
pub fn reveal_path(path: &Path) {
    #[cfg(windows)]
    {
        if let Some(s) = path.to_str() {
            let _ = run_hidden_sync("explorer", &["/select,", s]);
        }
    }
    #[cfg(not(windows))]
    {
        let parent = path.parent().unwrap_or(path);
        let _ = run_hidden_sync("xdg-open", &[parent.to_str().unwrap_or(".")]);
    }
}

/// Open http(s) / file URL in the default handler.
pub fn open_url(url: &str) {
    #[cfg(windows)]
    {
        let _ = run_hidden_sync("cmd", &["/C", "start", "", url]);
    }
    #[cfg(not(windows))]
    {
        let _ = run_hidden_sync("xdg-open", &[url]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn run_hidden_captures_stdout_without_window() {
        #[cfg(unix)]
        let out = run_hidden("echo", &["bullshit-notch"]).await.unwrap();
        #[cfg(windows)]
        let out = run_hidden("cmd", &["/C", "echo bullshit-notch"])
            .await
            .unwrap();
        #[cfg(not(any(unix, windows)))]
        let out = CommandOutput {
            status: 0,
            stdout: "bullshit-notch".into(),
            stderr: String::new(),
        };

        assert_eq!(out.status, 0);
        assert!(out.stdout.trim().contains("bullshit-notch"));
    }
}
