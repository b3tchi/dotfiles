export def assert-eq [actual, expected, msg: string = ""] {
    if $actual != $expected {
        error make {msg: $"expected ($expected | to nuon), got ($actual | to nuon). ($msg)"}
    }
}

export def assert-true [cond: bool, msg: string] {
    if not $cond { error make {msg: $"assertion failed: ($msg)"} }
}

export def run-case [name: string, body: closure] {
    try { do $body; {name: $name, status: "pass", detail: ""} } catch {|e| {name: $name, status: "FAIL", detail: $e.msg} }
}
