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
}
