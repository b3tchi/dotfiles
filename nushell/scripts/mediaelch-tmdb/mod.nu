# Helpers for MediaElch TMDb movie lookup.
#
# MediaElch 2.12.0 emits duplicate include_adult query parameters for movie
# text search, which TMDb rejects. These helpers build a clean search URL and
# turn TMDb results into MediaElch-friendly `idNNN` search tokens.

export const DEFAULT_TMDB_API_KEY = "5d832bdf69dcb884922381ab01548d5b"
export const DEFAULT_LOCALE = "cs-CZ"
export const TMDB_IMAGE_BASE = "https://image.tmdb.org/t/p/original"
export const DETAIL_APPEND = "credits,release_dates,keywords,videos,images,external_ids"

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

export def movie-stem [movie_path: string] {
    $movie_path | path parse | get stem
}

export def movie-dir [movie_path: string] {
    $movie_path | path dirname
}

export def sidecar-plan [movie_path: string] {
    let dir = (movie-dir $movie_path)
    let stem = (movie-stem $movie_path)
    {
        nfo: ([$dir $"($stem).nfo"] | path join),
        poster: ([$dir $"($stem)-poster.jpg"] | path join),
        fanart: ([$dir $"($stem)-fanart.jpg"] | path join),
        clearlogo: ([$dir $"($stem)-clearlogo.png"] | path join),
        clearart: ([$dir $"($stem)-clearart.png"] | path join),
        discart: ([$dir $"($stem)-discart.png"] | path join),
        banner: ([$dir $"($stem)-banner.jpg"] | path join),
        landscape: ([$dir $"($stem)-landscape.jpg"] | path join),
        extra_fanart_dir: ([$dir "extrafanart"] | path join),
    }
}

export def build-detail-url [
    tmdb_id: string,
    --api-key: string = $DEFAULT_TMDB_API_KEY,
    --locale: string = $DEFAULT_LOCALE,
] {
    let append = ($DETAIL_APPEND | str replace --all "," "%2C")
    $"https://api.themoviedb.org/3/movie/($tmdb_id)?append_to_response=($append)&api_key=($api_key)&language=($locale)"
}

export def fetch-detail [
    tmdb_id: string,
    --api-key: string = $DEFAULT_TMDB_API_KEY,
    --locale: string = $DEFAULT_LOCALE,
] {
    http get (build-detail-url $tmdb_id --api-key $api_key --locale $locale)
}

export def tmdb-image-url [path?: string] {
    if ($path | is-empty) { "" } else { $"($TMDB_IMAGE_BASE)($path)" }
}

export def artwork-plan [detail: record, movie_path: string] {
    let paths = (sidecar-plan $movie_path)
    let posters = ($detail.images?.posters? | default [])
    let backdrops = ($detail.images?.backdrops? | default [])
    let logos = ($detail.images?.logos? | default [])
    let base = []
    let base = if ($detail.poster_path? | default "" | is-not-empty) {
        $base | append {kind: "poster", path: $paths.poster, url: (tmdb-image-url $detail.poster_path)}
    } else if (($posters | length) > 0) {
        $base | append {kind: "poster", path: $paths.poster, url: (tmdb-image-url $posters.0.file_path)}
    } else { $base }
    let base = if ($detail.backdrop_path? | default "" | is-not-empty) {
        $base | append {kind: "fanart", path: $paths.fanart, url: (tmdb-image-url $detail.backdrop_path)} | append {kind: "landscape", path: $paths.landscape, url: (tmdb-image-url $detail.backdrop_path)}
    } else if (($backdrops | length) > 0) {
        $base | append {kind: "fanart", path: $paths.fanart, url: (tmdb-image-url $backdrops.0.file_path)} | append {kind: "landscape", path: $paths.landscape, url: (tmdb-image-url $backdrops.0.file_path)}
    } else { $base }
    let base = if (($logos | length) > 0) {
        $base | append {kind: "clearlogo", path: $paths.clearlogo, url: (tmdb-image-url $logos.0.file_path)}
    } else { $base }
    let extra = ($backdrops | skip 1 | enumerate | each {|b|
        {kind: "extra_fanart", path: ([$paths.extra_fanart_dir $"fanart($b.index + 1).jpg"] | path join), url: (tmdb-image-url $b.item.file_path)}
    })
    $base | append $extra | flatten | where {|r| ($r.url | is-not-empty) }
}

export def build-fanarttv-url [tmdb_id: string, api_key: string, client_key?: string] {
    let base = $"https://webservice.fanart.tv/v3/movies/($tmdb_id)?api_key=($api_key)"
    if ($client_key | default "" | is-empty) { $base } else { $"($base)&client_key=($client_key)" }
}

export def fetch-fanarttv [tmdb_id: string, api_key: string, client_key?: string] {
    http get (build-fanarttv-url $tmdb_id $api_key $client_key)
}

export def first-url [rows?: list] {
    let xs = ($rows | default [])
    if ($xs | is-empty) { "" } else { $xs.0.url? | default "" }
}

export def fanarttv-artwork-plan [fanart: record, movie_path: string] {
    let paths = (sidecar-plan $movie_path)
    let mappings = [
        {kind: "clearlogo", path: $paths.clearlogo, url: (first-url ($fanart.hdmovielogo? | default ($fanart.movielogo? | default [])))}
        {kind: "clearart", path: $paths.clearart, url: (first-url ($fanart.movieclearart? | default []))}
        {kind: "discart", path: $paths.discart, url: (first-url ($fanart.moviedisc? | default []))}
        {kind: "banner", path: $paths.banner, url: (first-url ($fanart.moviebanner? | default []))}
        {kind: "landscape", path: $paths.landscape, url: (first-url ($fanart.moviethumb? | default []))}
    ]
    let extra = ($fanart.moviebackground? | default [] | skip 1 | enumerate | each {|b|
        {kind: "extra_fanart", path: ([$paths.extra_fanart_dir $"fanart($b.index + 1).jpg"] | path join), url: ($b.item.url? | default "")}
    })
    $mappings | append $extra | flatten | where {|r| ($r.url | is-not-empty) }
}

export def merge-artwork-plans [primary: list, secondary: list] {
    mut out = []
    for item in ($secondary | append $primary | flatten) {
        if not (($out | any {|x| $x.kind == $item.kind and $x.path == $item.path })) {
            $out = ($out | append $item)
        }
    }
    $out
}

export def xml-escape [text?: any] {
    ($text | default "" | into string | str replace --all "&" "&amp;" | str replace --all "<" "&lt;" | str replace --all ">" "&gt;" | str replace --all '"' "&quot;")
}

export def xml-tag [name: string, value?: any] {
    $"  <($name)>((xml-escape $value))</($name)>"
}

export def xml-tags [name: string, values: list] {
    $values | each {|v| xml-tag $name $v }
}

export def render-nfo [detail: record] {
    let title = ($detail.title? | default $detail.original_title? | default "")
    let original = ($detail.original_title? | default "")
    let year = (if (($detail.release_date? | default "" | str length) >= 4) { $detail.release_date | str substring 0..3 } else { "" })
    let genres = ($detail.genres? | default [] | each {|g| $g.name })
    let countries = ($detail.production_countries? | default [] | each {|c| $c.name })
    let studios = ($detail.production_companies? | default [] | each {|s| $s.name })
    let directors = ($detail.credits?.crew? | default [] | where job == "Director" | get name)
    let writers = ($detail.credits?.crew? | default [] | where {|c| $c.job in ["Writer" "Screenplay" "Story"] } | get name)
    let tags = ($detail.keywords?.keywords? | default [] | each {|k| $k.name })
    let trailer = ($detail.videos?.results? | default [] | where site == "YouTube" | where type == "Trailer" | first | default {} | get -o key | default "")
    let imdb = ($detail.imdb_id? | default "")
    let tmdb = ($detail.id | into string)
    let cert = ($detail.release_dates?.results? | default [] | where iso_3166_1 == "US" | get -o 0.release_dates | default [] | where {|r| ($r.certification? | default "") != "" } | first | default {} | get -o certification | default "")
    let set_block = if (($detail.belongs_to_collection? | default null) != null) and (($detail.belongs_to_collection.name? | default "") != "") {
        [$"  <set>" (xml-tag "name" $detail.belongs_to_collection.name) (xml-tag "overview" ($detail.belongs_to_collection.overview? | default "")) $"  </set>"]
    } else { [] }
    let image_block = [
        (xml-tag "thumb" (tmdb-image-url ($detail.poster_path? | default "")))
        "  <fanart>"
        $"    <thumb>((xml-escape (tmdb-image-url ($detail.backdrop_path? | default ""))))</thumb>"
        "  </fanart>"
    ]
    let actor_block = ($detail.credits?.cast? | default [] | first 20 | each {|a|
        let thumb = (tmdb-image-url ($a.profile_path? | default ""))
        let thumb_line = if ($thumb | is-empty) { [] } else { [$"    <thumb>((xml-escape $thumb))</thumb>"] }
        (["  <actor>" (xml-tag "name" $a.name) (xml-tag "role" ($a.character? | default "")) (xml-tag "order" ($a.order? | default 0))] | append $thumb_line | append "  </actor>")
    } | flatten)
    (["<?xml version=\"1.0\" encoding=\"UTF-8\"?>" "<movie>"]
        | append (xml-tag "title" $title)
        | append (if ($original != "") and ($original != $title) { [ (xml-tag "originaltitle" $original) ] } else { [] })
        | append (xml-tag "rating" ($detail.vote_average? | default 0))
        | append (xml-tag "votes" ($detail.vote_count? | default 0))
        | append (xml-tag "outline" ($detail.overview? | default ""))
        | append (xml-tag "plot" ($detail.overview? | default ""))
        | append (xml-tag "tagline" ($detail.tagline? | default ""))
        | append (xml-tag "runtime" ($detail.runtime? | default ""))
        | append $image_block
        | append (xml-tag "mpaa" $cert)
        | append (xml-tag "id" $imdb)
        | append (if ($imdb | is-not-empty) { [$"  <uniqueid default=\"true\" type=\"imdb\">($imdb)</uniqueid>"] } else { [] })
        | append $"  <uniqueid type=\"tmdb\">($tmdb)</uniqueid>"
        | append (xml-tags "genre" $genres)
        | append (xml-tags "country" $countries)
        | append $set_block
        | append (xml-tags "credits" $writers)
        | append (xml-tags "director" $directors)
        | append (xml-tag "premiered" ($detail.release_date? | default ""))
        | append (xml-tag "year" $year)
        | append (xml-tags "studio" $studios)
        | append (if ($trailer | is-not-empty) { [ (xml-tag "trailer" $"plugin://plugin.video.youtube/?action=play_video&videoid=($trailer)") ] } else { [] })
        | append $actor_block
        | append (xml-tags "tag" $tags)
        | append "</movie>"
        | str join "\n")
}
