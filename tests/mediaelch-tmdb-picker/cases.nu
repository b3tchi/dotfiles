#!/usr/bin/env nu
use harness.nu *
use ../../nushell/scripts/mediaelch-tmdb/mod.nu *

let cases = [
    (run-case "build-search-url/does-not-duplicate-include-adult" {
        let url = (build-search-url "Matrix" --year 1999 --api-key "KEY" --locale "cs-CZ")
        assert-true ($url | str contains "include_adult=false") "include_adult present"
        assert-eq (($url | split row "include_adult" | length) - 1) 1 "include_adult appears once"
        assert-true ($url | str contains "query=Matrix") "query present"
        assert-true ($url | str contains "year=1999") "year present"
    })
    (run-case "parse-results/returns-mediaelch-id-lines" {
        let rows = (open ($env.FILE_PWD | path join fixtures/search-matrix.json) | parse-results)
        assert-eq ($rows | length) 2
        assert-eq ($rows.0.mediaelch_id) "id603"
        assert-eq ($rows.0.year) "1999"
        assert-true (($rows.0.display | str contains "id603") and ($rows.0.display | str contains "Matrix (1999)")) "display has title/year/id"
    })
    (run-case "line-to-id/extracts-id-from-fzf-display" {
        assert-eq (line-to-id "Matrix (1999) | id603 | 8.2 | Set in the 22nd century") "id603"
    })
]

print ($cases | to json)
if (($cases | where status == "FAIL" | length) > 0) { exit 1 }
