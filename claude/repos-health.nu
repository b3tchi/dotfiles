#!/usr/bin/env nu
# repos-health: check claude/bd/perles/dolt setup health for current repo

def check [name: string, ok: bool, detail: string = ""] {
    let mark = if $ok { "✓" } else { "✗" }
    let color = if $ok { (ansi green) } else { (ansi red) }
    print $"($color)($mark)(ansi reset) ($name)(if $detail != '' { $': ($detail)' } else { '' })"
    $ok
}

def warn [name: string, detail: string] {
    print $"(ansi yellow)⚠(ansi reset) ($name): ($detail)"
}

def section [title: string] {
    print ""
    print $"(ansi cyan_bold)── ($title) ──(ansi reset)"
}

def has-cmd [cmd: string]: nothing -> bool {
    (which $cmd | length) > 0
}

def main [] {
    mut fails = 0

    section "Binaries"
    for cmd in [claude bd perles dolt] {
        let ok = (has-cmd $cmd)
        if not (check $cmd $ok) { $fails = $fails + 1 }
    }

    section "Versions"
    if (has-cmd "claude") {
        let v = (do { ^claude --version } | complete | get stdout | str trim)
        check "claude" true $v | ignore
    }
    if (has-cmd "bd") {
        let v = (do { ^bd --version } | complete | get stdout | lines | first | str trim)
        check "bd" true $v | ignore
    }
    if (has-cmd "perles") {
        let v = (do { ^perles --version } | complete | get stdout | lines | first | str trim)
        check "perles" true $v | ignore
        let latest = (try {
            http get https://api.github.com/repos/zjrosen/perles/releases/latest | get tag_name
        } catch { "" })
        if $latest != "" {
            let installed = ($v | parse --regex 'perles version (?<v>[\d.]+)' | get v.0? | default "")
            let latest_clean = ($latest | str replace -r '^v' '')
            if $installed != $latest_clean {
                warn "perles outdated" $"installed ($installed), latest ($latest_clean)"
            }
        }
    }

    section "Symlinks"
    let links = [
        [path target_pattern];
        ["~/.config/perles/config.yaml" ".dotfiles/claude/perles"]
        ["~/.claude/settings.json" ".dotfiles/claude/settings.json"]
        ["~/.claude/statusline.sh" ".dotfiles/claude/statusline.sh"]
    ]
    for row in $links {
        let p = ($row.path | path expand --no-symlink)
        let exists = ($p | path exists)
        let target = if $exists {
            (^readlink $p | complete | get stdout | str trim)
        } else { "missing" }
        let ok = ($exists and ($target | str contains $row.target_pattern))
        if not (check $row.path $ok $target) { $fails = $fails + 1 }
    }

    section "Dolt server"
    if (has-cmd "bd") {
        let r = (do { ^bd dolt status } | complete)
        let running = ($r.stdout | str contains "Dolt server: running")
        if not (check "dolt running" $running) { $fails = $fails + 1 }
        if $running {
            let port_line = ($r.stdout | lines | where ($it | str contains "Port:") | first | default "")
            let data_line = ($r.stdout | lines | where ($it | str contains "Data:") | first | default "")
            print $"  ($port_line | str trim)"
            print $"  ($data_line | str trim)"
        }
    }

    section "Repo bd state"
    let cwd = (pwd)
    let beads_dir = ($cwd | path join ".beads")
    let in_repo = ($beads_dir | path exists)
    if not $in_repo {
        warn "no .beads/" $"($cwd) — skipping repo checks"
    } else {
        let r = (do { ^bd list --type epic } | complete)
        let reachable = ($r.exit_code == 0)
        if not (check "bd reachable" $reachable) { $fails = $fails + 1 }

        let perms = (try { ls -l $beads_dir | first | get mode | default "" } catch { "" })
        if $perms !~ '700' {
            warn "permissions" $"($beads_dir) not 0700 — chmod 700 ($beads_dir)"
        }

        let role = (do { ^git config beads.role } | complete | get stdout | str trim)
        if $role == "" {
            warn "beads.role unset" "git config beads.role maintainer"
        }

        let interactions = ($beads_dir | path join "interactions.jsonl")
        let tracked = (do { ^git ls-files --error-unmatch $interactions } | complete | get exit_code) == 0
        if $tracked {
            warn ".beads/interactions.jsonl tracked" "should be untracked"
        }

        let gi = ($beads_dir | path join ".gitignore")
        if ($gi | path exists) {
            let body = (open --raw $gi)
            if not ($body | str contains "embeddeddolt/") {
                warn ".beads/.gitignore" "missing embeddeddolt/ — bd doctor --fix"
            }
        }
    }

    section "Summary"
    if $fails == 0 {
        print $"(ansi green_bold)all critical checks passed(ansi reset)"
    } else {
        let msg = $"($fails) critical checks failed"
        print $"(ansi red_bold)($msg)(ansi reset)"
        exit 1
    }
}
