# Helpers for MediaElch TMDb movie lookup.
#
# MediaElch 2.12.0 emits duplicate include_adult query parameters for movie
# text search, which TMDb rejects. These helpers build a clean search URL and
# turn TMDb results into MediaElch-friendly `idNNN` search tokens.

export const DEFAULT_TMDB_API_KEY = "5d832bdf69dcb884922381ab01548d5b"
export const DEFAULT_LOCALE = "cs-CZ"

export def build-search-url [
    query: string,
    --year: int,
    --api-key: string = $DEFAULT_TMDB_API_KEY,
    --locale: string = $DEFAULT_LOCALE,
    --include-adult = false,
] {
    let encoded_query = ($query | url encode)
    let base = $"https://api.themoviedb.org/3/search/movie?page=1&query=($encoded_query)&include_adult=($include_adult)&api_key=($api_key)&language=($locale)"
    if ($year | is-empty) {
        $base
    } else {
        $"($base)&year=($year)"
    }
}

export def parse-results [] {
    let payload = $in
    let rows = ($payload.results? | default [])
    $rows | each {|r|
        let title = ($r.title? | default $r.original_title? | default "<untitled>")
        let original = ($r.original_title? | default "")
        let release = ($r.release_date? | default "")
        let year = (if ($release | str length) >= 4 { $release | str substring 0..3 } else { "????" })
        let id = ($r.id | into string)
        let rating = ($r.vote_average? | default 0 | into string)
        let overview = ($r.overview? | default "" | str replace --all "\n" " " | str trim)
        let original_part = (if ($original != "") and ($original != $title) { $" / ($original)" } else { "" })
        let display = $"($title)($original_part) \(($year)\) | id($id) | ($rating) | ($overview)"
        {
            tmdb_id: $id,
            mediaelch_id: $"id($id)",
            title: $title,
            original_title: $original,
            year: $year,
            release_date: $release,
            rating: $rating,
            overview: $overview,
            display: $display,
        }
    }
}

export def line-to-id [line: string] {
    let parts = ($line | split row "|" | each {|p| $p | str trim })
    let ids = ($parts | where {|p| $p =~ '^id\d+$' })
    if ($ids | is-empty) { "" } else { $ids.0 }
}

export def search-tmdb [
    query: string,
    --year: int,
    --api-key: string = $DEFAULT_TMDB_API_KEY,
    --locale: string = $DEFAULT_LOCALE,
] {
    let url = (build-search-url $query --year $year --api-key $api_key --locale $locale)
    http get $url | parse-results
}
