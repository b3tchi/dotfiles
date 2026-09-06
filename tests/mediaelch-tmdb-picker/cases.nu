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
    (run-case "movie-stem/uses-video-complete-base-name" {
        assert-eq (movie-stem "/movies/The.Matrix.1999.mkv") "The.Matrix.1999"
    })
    (run-case "sidecar-plan/mediaelch-kodi-names-by-stem" {
        let plan = (sidecar-plan "/movies/The.Matrix.1999.mkv")
        assert-eq $plan.nfo "/movies/The.Matrix.1999.nfo"
        assert-eq $plan.poster "/movies/The.Matrix.1999-poster.jpg"
        assert-eq $plan.fanart "/movies/The.Matrix.1999-fanart.jpg"
        assert-eq $plan.clearlogo "/movies/The.Matrix.1999-clearlogo.png"
        assert-eq $plan.clearart "/movies/The.Matrix.1999-clearart.png"
        assert-eq $plan.discart "/movies/The.Matrix.1999-discart.png"
        assert-eq $plan.banner "/movies/The.Matrix.1999-banner.jpg"
        assert-eq $plan.landscape "/movies/The.Matrix.1999-landscape.jpg"
        assert-eq $plan.extra_fanart_dir "/movies/extrafanart"
    })
    (run-case "detail-url/requests-all-needed-tmdb-parts" {
        let url = (build-detail-url "603" --api-key "KEY" --locale "cs-CZ")
        assert-true ($url | str contains "/movie/603?") "movie detail endpoint"
        assert-true ($url | str contains "append_to_response=credits%2Crelease_dates%2Ckeywords%2Cvideos%2Cimages%2Cexternal_ids") "append_to_response encoded"
    })
    (run-case "artwork-plan/selects-mediaelch-sidecars-and-extra-fanart" {
        let detail = (open ($env.FILE_PWD | path join fixtures/movie-detail-matrix.json))
        let plan = (artwork-plan $detail "/movies/The.Matrix.1999.mkv")
        assert-eq ($plan | where kind == "poster" | get 0.path) "/movies/The.Matrix.1999-poster.jpg"
        assert-eq ($plan | where kind == "fanart" | get 0.path) "/movies/The.Matrix.1999-fanart.jpg"
        assert-eq ($plan | where kind == "clearlogo" | get 0.path) "/movies/The.Matrix.1999-clearlogo.png"
        assert-eq ($plan | where kind == "extra_fanart" | get 0.path) "/movies/extrafanart/fanart1.jpg"
    })
    (run-case "nfo/render-kodi-movie-fields" {
        let detail = (open ($env.FILE_PWD | path join fixtures/movie-detail-matrix.json))
        let xml = (render-nfo $detail)
        assert-true ($xml | str contains "<movie>") "movie root"
        assert-true ($xml | str contains "<title>Matrix</title>") "title"
        assert-true ($xml | str contains "<uniqueid type=\"tmdb\">603</uniqueid>") "tmdb id"
        assert-true ($xml | str contains "<uniqueid default=\"true\" type=\"imdb\">tt0133093</uniqueid>") "imdb id"
        assert-true ($xml | str contains "<actor>") "actors"
        assert-true ($xml | str contains "<thumb>https://image.tmdb.org/t/p/original/keanu.jpg</thumb>") "actor thumb"
    })
    (run-case "fanarttv-plan/fills-mediaelch-rich-artwork" {
        let fanart = (open ($env.FILE_PWD | path join fixtures/fanarttv-matrix.json))
        let plan = (fanarttv-artwork-plan $fanart "/movies/The.Matrix.1999.mkv")
        assert-eq ($plan | where kind == "clearlogo" | get 0.path) "/movies/The.Matrix.1999-clearlogo.png"
        assert-eq ($plan | where kind == "clearart" | get 0.path) "/movies/The.Matrix.1999-clearart.png"
        assert-eq ($plan | where kind == "discart" | get 0.path) "/movies/The.Matrix.1999-discart.png"
        assert-eq ($plan | where kind == "banner" | get 0.path) "/movies/The.Matrix.1999-banner.jpg"
        assert-eq ($plan | where kind == "landscape" | get 0.path) "/movies/The.Matrix.1999-landscape.jpg"
        assert-eq ($plan | where kind == "extra_fanart" | get 0.path) "/movies/extrafanart/fanart1.jpg"
    })
]

print ($cases | to json)
if (($cases | where status == "FAIL" | length) > 0) { exit 1 }
