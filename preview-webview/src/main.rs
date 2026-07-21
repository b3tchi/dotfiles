// preview-wv — chrome-less wry/tao window client for the ft005
// file-preview daemon's live `/preview<N>` window. See sp013
// (docs/notes/spec/sp013.md) and the poc007 wry harness
// (bench/webview/bench.sh) for the proven shape this mirrors.
//
// Usage: preview-wv <N> [--port P]
//   N       window slot number (non-negative integer, required)
//   --port  daemon port (default: $PREVIEW_PORT, else 4200)
//
// Loads http://127.0.0.1:<port>/preview<N>. WM_CLASS `preview-wv`, title
// `preview <N>`. Inherits DISPLAY/XAUTHORITY from the caller. Exits 0 when
// the window closes. This binary is the engine only — no consumer should
// call it directly; the wrapper (nushell/actions/preview, sp013 Task 2)
// owns lifecycle/pidfile discipline ([[adr0003]] engine-not-interface).

use std::process::ExitCode;

const DEFAULT_PORT: u16 = 4200;
const WM_CLASS: &str = "preview-wv";

const USAGE: &str = "usage: preview-wv <N> [--port P]\n\n\
N       window slot number (non-negative integer, required)\n\
--port  daemon port (default: $PREVIEW_PORT, else 4200)\n";

#[derive(Debug, PartialEq, Eq)]
struct Config {
    n: u32,
    port: u16,
}

/// Pure arg-parse: no I/O, no GTK, so it is unit-testable without a
/// display. `env_port` stands in for `$PREVIEW_PORT` so tests never touch
/// the real process environment.
fn parse_args<I>(args: I, env_port: Option<&str>) -> Result<Config, String>
where
    I: IntoIterator<Item = String>,
{
    let mut iter = args.into_iter();

    // N is required, and must be a non-negative integer. u32::parse already
    // rejects both non-numeric strings and negative numbers (no '-' sign
    // accepted), so both edge cases collapse into one check.
    let n_raw = iter.next().ok_or_else(|| USAGE.to_string())?;
    let n: u32 = n_raw.parse().map_err(|_| USAGE.to_string())?;

    let mut port_flag: Option<u16> = None;
    while let Some(arg) = iter.next() {
        match arg.as_str() {
            "--port" => {
                let raw = iter.next().ok_or_else(|| USAGE.to_string())?;
                let p: u16 = raw.parse().map_err(|_| USAGE.to_string())?;
                port_flag = Some(p);
            }
            _ => return Err(USAGE.to_string()),
        }
    }

    // Port resolution order: --port flag > $PREVIEW_PORT > 4200. An
    // unparseable $PREVIEW_PORT is not a CLI usage error (it's an
    // environment misconfiguration, not user input to this invocation) —
    // fall back to the default instead of failing the run.
    let port = match port_flag {
        Some(p) => p,
        None => env_port
            .and_then(|s| s.parse::<u16>().ok())
            .unwrap_or(DEFAULT_PORT),
    };

    Ok(Config { n, port })
}

fn window_url(cfg: &Config) -> String {
    format!("http://127.0.0.1:{}/preview{}", cfg.port, cfg.n)
}

fn window_title(cfg: &Config) -> String {
    format!("preview {}", cfg.n)
}

/// Pure formatter for the startup log line (dotfiles-bo2). run_window
/// eprintln!s it to stderr — which the wrapper redirects to
/// ~/.cache/preview/wv-<N>.log — immediately before entering the event
/// loop. It is the "this process reached a live event loop" marker a silent
/// death otherwise leaves no trace of: the log was empty on every run,
/// healthy or not, so a crash, a clean exit and a SIGKILL were
/// indistinguishable. Kept pure (no I/O) so it is unit-testable.
fn ready_line(cfg: &Config, pid: u32) -> String {
    format!(
        "preview-wv: window {} ready (pid {}, port {}) — entering event loop",
        cfg.n, pid, cfg.port
    )
}

/// Pure formatter for the clean-exit log line, emitted when the WM/session
/// delivers WindowEvent::CloseRequested — the ONLY path by which this binary
/// exits itself. Its presence after ready_line means the environment closed
/// the window (exit 0, e.g. an xrdp session recycling its X windows); its
/// ABSENCE — ready_line logged, no close_line, process gone — means an
/// external signal (SIGKILL/OOM/crash) killed it. That is the bo2
/// distinguisher, previously invisible.
fn close_line(cfg: &Config) -> String {
    format!(
        "preview-wv: window {} received CloseRequested — exiting 0",
        cfg.n
    )
}

/// The X display number from a DISPLAY value: ":10.0" -> "10", ":0" -> "0".
/// None when DISPLAY is empty, remote ("host:10"), or otherwise malformed.
fn display_number(display: &str) -> Option<&str> {
    let rest = display.strip_prefix(':')?;
    let num = rest.split('.').next().unwrap_or(rest);
    if num.is_empty() || !num.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    Some(num)
}

/// Reports whether DISPLAY is served by an xorgxrdp virtual Xorg, matched by
/// finding a running Xorg whose args carry this display's EXACT token (":N")
/// and mention xrdp. Deliberately per-display: a desktop runs native :0 (real
/// GPU) alongside xrdp :10, and only the latter must force software GL
/// (dotfiles-49j). xorg_cmdlines is injected so the match is unit-testable
/// without /proc.
fn is_xrdp_display(display: &str, xorg_cmdlines: &[String]) -> bool {
    let Some(n) = display_number(display) else {
        return false;
    };
    let tok = format!(":{n}");
    xorg_cmdlines
        .iter()
        .any(|c| c.to_lowercase().contains("xrdp") && c.split_whitespace().any(|t| t == tok))
}

/// Space-joined cmdlines of every running Xorg, read from /proc. Empty on any
/// read failure — a detection miss degrades to "not xrdp" (no guard), which
/// is the pre-fix status quo, never worse.
fn running_xorg_cmdlines() -> Vec<String> {
    let mut out = Vec::new();
    let Ok(entries) = std::fs::read_dir("/proc") else {
        return out;
    };
    for entry in entries.flatten() {
        if let Ok(bytes) = std::fs::read(entry.path().join("cmdline")) {
            let joined: String = bytes
                .split(|b| *b == 0)
                .filter_map(|s| std::str::from_utf8(s).ok())
                .collect::<Vec<_>>()
                .join(" ");
            if joined.contains("Xorg") {
                out.push(joined);
            }
        }
    }
    out
}

/// Set an env var only when the caller has not already set it, so an explicit
/// override (a manual export, or the wrapper) always wins.
fn set_env_if_unset(key: &str, val: &str) {
    if std::env::var_os(key).is_none() {
        std::env::set_var(key, val);
    }
}

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let env_port = std::env::var("PREVIEW_PORT").ok();

    let cfg = match parse_args(args, env_port.as_deref()) {
        Ok(cfg) => cfg,
        Err(msg) => {
            eprint!("{msg}");
            return ExitCode::from(2);
        }
    };

    run_window(&cfg)
}

/// GTK3/X11 derives WM_CLASS's two fields (res_name, res_class) from
/// `glib::set_prgname` when neither is set explicitly: res_name = prgname
/// verbatim, res_class = prgname with its first letter capitalized (e.g.
/// "preview-wv" -> "Preview-wv"). i3/sway `for_window [class=...]` match
/// against res_class case-sensitively, so that auto-capitalization would
/// silently break Task 3's float rule. Set both fields explicitly via a raw
/// XSetClassHint call so `xprop` reports WM_CLASS(STRING) = "preview-wv",
/// "preview-wv" verbatim. Best-effort: on any failure (non-X11 backend,
/// can't open a second display connection, ...) this logs and leaves GTK's
/// default WM_CLASS in place rather than failing the whole window.
fn force_wm_class(window: &tao::window::Window, class: &str) {
    use gtk::glib::Cast;
    use gtk::prelude::WidgetExt;
    use tao::platform::unix::WindowExtUnix;

    let gtk_window = window.gtk_window();
    gtk_window.realize();
    let Some(gdk_window) = gtk_window.window() else {
        eprintln!(
            "preview-wv: warning: window not realized, WM_CLASS may be capitalized by GTK default"
        );
        return;
    };
    let x11_window = match gdk_window.downcast::<gdkx11::X11Window>() {
        Ok(w) => w,
        Err(_) => {
            eprintln!("preview-wv: warning: non-X11 GDK backend, WM_CLASS may be capitalized by GTK default");
            return;
        }
    };
    let xid = x11_window.xid();

    let name = match std::ffi::CString::new(class) {
        Ok(c) => c,
        Err(_) => return,
    };
    let class_name = match std::ffi::CString::new(class) {
        Ok(c) => c,
        Err(_) => return,
    };

    unsafe {
        let display = x11::xlib::XOpenDisplay(std::ptr::null());
        if display.is_null() {
            eprintln!(
                "preview-wv: warning: could not open a second X11 connection to set WM_CLASS"
            );
            return;
        }
        let mut hint = x11::xlib::XClassHint {
            res_name: name.as_ptr() as *mut _,
            res_class: class_name.as_ptr() as *mut _,
        };
        x11::xlib::XSetClassHint(display, xid, &mut hint);
        x11::xlib::XFlush(display);
        x11::xlib::XCloseDisplay(display);
    }
}

fn run_window(cfg: &Config) -> ExitCode {
    use tao::{
        event::{Event, WindowEvent},
        event_loop::{ControlFlow, EventLoop},
        platform::unix::WindowExtUnix,
        window::WindowBuilder,
    };
    use wry::WebViewBuilderExtUnix;

    // Force the X11 backend before any GTK/GDK initialization — GDK reads
    // this env var exactly once, at gtk_init() time, so it must be set
    // before gtk::init()/EventLoop::new() below.
    std::env::set_var("GDK_BACKEND", "x11");

    // xorgxrdp is a GPU-less virtual Xorg: forcing hardware GL through mesa
    // there wedges its x264 encoder (dotfiles-49j; the xrdp-servo-wedges
    // signature), and there is no hardware GL to lose on a virtual display
    // anyway. When this DISPLAY is served by xorgxrdp, force software GL and
    // disable WebKit's accelerated compositing — set before gtk::init()/GL
    // context creation, alongside GDK_BACKEND, and only if the caller did not
    // already choose (an explicit override wins). Native :0 (real GPU) is
    // detected as non-xrdp and keeps hardware GL.
    let display = std::env::var("DISPLAY").unwrap_or_default();
    if is_xrdp_display(&display, &running_xorg_cmdlines()) {
        // Logged (like the lifecycle lines) so a GL choice is never silent:
        // the guard's presence is only observable in the log, since a runtime
        // setenv does not show in /proc/<pid>/environ.
        eprintln!("preview-wv: xorgxrdp display {display} — forcing software GL");
        set_env_if_unset("LIBGL_ALWAYS_SOFTWARE", "1");
        set_env_if_unset("WEBKIT_DISABLE_COMPOSITING_MODE", "1");
    }

    // On X11/GTK3, WM_CLASS's res_name/res_class default to the process's
    // prgname. Setting it here (before gtk::init()) is what makes `xprop`
    // report WM_CLASS(STRING) = "preview-wv", "preview-wv" — the contract
    // sp013 Task 3's WM float rules match on.
    glib::set_prgname(Some(WM_CLASS));

    // Pre-check GTK/GDK ourselves: gtk::init() calls gtk_init_check(),
    // which reports failure (no DISPLAY, can't connect, ...) as an Err
    // instead of aborting. tao's own EventLoop::new() unwraps internally on
    // the same failure and would panic with a backtrace — this pre-check
    // is what keeps "no DISPLAY" a clean nonzero exit instead.
    if let Err(e) = gtk::init() {
        eprintln!("preview-wv: failed to initialize GTK/GDK: {e}");
        eprintln!("preview-wv: is DISPLAY set and an X11 session reachable?");
        return ExitCode::FAILURE;
    }

    let event_loop = EventLoop::new();

    let window = match WindowBuilder::new()
        .with_title(window_title(cfg))
        .build(&event_loop)
    {
        Ok(w) => w,
        Err(e) => {
            eprintln!("preview-wv: failed to create window: {e}");
            return ExitCode::FAILURE;
        }
    };

    force_wm_class(&window, WM_CLASS);

    let vbox = match window.default_vbox() {
        Some(v) => v,
        None => {
            eprintln!("preview-wv: no default container on window");
            return ExitCode::FAILURE;
        }
    };

    let url = window_url(cfg);
    // Daemon-down is intentionally NOT pre-checked here: the webview just
    // renders WebKitGTK's own connection-error page and the process stays
    // up (sp013 Task 1 edge case) — reconnect is the daemon-side
    // websocket's concern, not this binary's.
    let _webview = match wry::WebViewBuilder::new_gtk(vbox).with_url(&url).build() {
        Ok(v) => v,
        Err(e) => {
            eprintln!("preview-wv: failed to create webview: {e}");
            return ExitCode::FAILURE;
        }
    };

    // bo2 observability: mark that a live event loop was reached, and
    // precompute the close message so the 'static event-loop closure can log
    // it without capturing the non-'static &Config borrow.
    eprintln!("{}", ready_line(cfg, std::process::id()));
    let close_msg = close_line(cfg);

    // EventLoop::run never returns (-> !); ControlFlow::Exit triggers
    // std::process::exit(0) internally, which is how "exits 0 on window
    // close" is satisfied.
    event_loop.run(move |event, _, control_flow| {
        *control_flow = ControlFlow::Wait;
        if let Event::WindowEvent {
            event: WindowEvent::CloseRequested,
            ..
        } = event
        {
            eprintln!("{close_msg}");
            *control_flow = ControlFlow::Exit;
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;

    fn args(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn defaults_to_port_4200() {
        let cfg = parse_args(args(&["1"]), None).unwrap();
        assert_eq!(cfg, Config { n: 1, port: 4200 });
    }

    #[test]
    fn port_flag_overrides_default() {
        let cfg = parse_args(args(&["2", "--port", "5000"]), None).unwrap();
        assert_eq!(cfg, Config { n: 2, port: 5000 });
    }

    #[test]
    fn env_port_overrides_default_but_not_flag() {
        let cfg = parse_args(args(&["3"]), Some("6100")).unwrap();
        assert_eq!(cfg, Config { n: 3, port: 6100 });

        let cfg = parse_args(args(&["3", "--port", "7000"]), Some("6100")).unwrap();
        assert_eq!(cfg, Config { n: 3, port: 7000 });
    }

    #[test]
    fn rejects_missing_n() {
        assert!(parse_args(args(&[]), None).is_err());
    }

    #[test]
    fn rejects_non_numeric_n() {
        assert!(parse_args(args(&["abc"]), None).is_err());
    }

    #[test]
    fn rejects_negative_n() {
        assert!(parse_args(args(&["-1"]), None).is_err());
    }

    #[test]
    fn rejects_non_numeric_port_flag() {
        assert!(parse_args(args(&["1", "--port", "nope"]), None).is_err());
    }

    #[test]
    fn rejects_port_flag_missing_value() {
        assert!(parse_args(args(&["1", "--port"]), None).is_err());
    }

    #[test]
    fn ignores_invalid_env_port_falls_back_to_default() {
        let cfg = parse_args(args(&["1"]), Some("not-a-port")).unwrap();
        assert_eq!(cfg, Config { n: 1, port: 4200 });
    }

    #[test]
    fn rejects_unknown_trailing_arg() {
        assert!(parse_args(args(&["1", "--bogus"]), None).is_err());
    }

    #[test]
    fn window_url_and_title_format() {
        let cfg = Config { n: 4, port: 4321 };
        assert_eq!(window_url(&cfg), "http://127.0.0.1:4321/preview4");
        assert_eq!(window_title(&cfg), "preview 4");
    }

    // dotfiles-bo2: lifecycle log lines are the observability that turns a
    // silent death into a diagnosable one. ready_line marks "reached a live
    // event loop"; close_line marks the only self-exit path (CloseRequested).
    // ready with no close + process gone == killed externally.
    #[test]
    fn ready_line_names_slot_pid_and_port() {
        let line = ready_line(&Config { n: 3, port: 4200 }, 12345);
        assert!(line.contains("window 3"), "{line}");
        assert!(line.contains("12345"), "{line}");
        assert!(line.contains("4200"), "{line}");
        assert!(line.contains("ready"), "{line}");
    }

    #[test]
    fn close_line_names_slot_and_clean_exit() {
        let line = close_line(&Config { n: 7, port: 4200 });
        assert!(line.contains("window 7"), "{line}");
        assert!(line.contains("CloseRequested"), "{line}");
        assert!(line.contains("exiting 0"), "{line}");
    }

    #[test]
    fn display_number_parses() {
        assert_eq!(display_number(":10.0"), Some("10"));
        assert_eq!(display_number(":0"), Some("0"));
        assert_eq!(display_number(":100"), Some("100"));
        assert_eq!(display_number(""), None);
        assert_eq!(display_number("localhost:10"), None);
    }

    #[test]
    fn xrdp_display_detected_by_matching_xorg_cmdline() {
        let cmds =
            vec!["/usr/lib/Xorg :10 -auth .Xauthority -config xrdp/xorg.conf -noreset".to_string()];
        assert!(is_xrdp_display(":10.0", &cmds));
        assert!(is_xrdp_display(":10", &cmds));
    }

    #[test]
    fn native_display_not_flagged_even_when_xrdp_coexists() {
        // Desktop: native :0 (real GPU) and xrdp :10 on the same host — only
        // the xrdp one must force software GL.
        let cmds = vec![
            "/usr/lib/Xorg :0 vt2 -displayfd 3 -auth /run/x".to_string(),
            "/usr/lib/Xorg :10 -config xrdp/xorg.conf -noreset".to_string(),
        ];
        assert!(
            !is_xrdp_display(":0", &cmds),
            ":0 is native, must not force software GL"
        );
        assert!(is_xrdp_display(":10", &cmds));
    }

    #[test]
    fn no_matching_xorg_is_not_xrdp() {
        assert!(!is_xrdp_display(":0", &[]));
        assert!(!is_xrdp_display(
            "",
            &["/usr/lib/Xorg :10 xrdp".to_string()]
        ));
    }

    #[test]
    fn display_token_not_confused_by_longer_number() {
        let cmds = vec!["/usr/lib/Xorg :100 -config xrdp/xorg.conf".to_string()];
        assert!(!is_xrdp_display(":10", &cmds), ":10 must not match :100");
    }
}
