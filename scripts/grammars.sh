#!/bin/sh
# Builds the grammars in grammars.txt into $1: parser/<name>.so and queries/<name>/highlights.scm.
# Each output records its revision, so reruns only fetch what changed.
set -eu
out=$1
list=$(cd "$(dirname "$0")/.." && pwd)/grammars.txt
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$out/parser" "$out/queries"

fetch() { # repo revision dir
    mkdir -p "$3"
    curl -fsSL "https://codeload.github.com/$1/tar.gz/$2" | tar -xz -C "$3" --strip-components 1
}

grep -v '^#' "$list" | while read -r name repo rev sub; do
    [ -n "$name" ] || continue
    if [ "$name" = queries ]; then
        [ "$(cat "$out/queries/.revision" 2>/dev/null)" = "$rev" ] && continue
        echo "queries @ $rev"
        fetch "$repo" "$rev" "$tmp/queries"
        langs="$sub $(grep -v '^#' "$list" | awk '$1 != "queries" && NF { print $1 }')"
        for l in $langs; do
            mkdir -p "$out/queries/$l"
            cp "$tmp/queries/runtime/queries/$l/highlights.scm" "$out/queries/$l/"
        done
        echo "$rev" > "$out/queries/.revision"
        continue
    fi
    [ "$(cat "$out/parser/$name.revision" 2>/dev/null)" = "$rev" ] && continue
    echo "$name @ $rev"
    fetch "$repo" "$rev" "$tmp/$name"
    src="$tmp/$name/${sub:+$sub/}src"
    files="$src/parser.c"
    [ -f "$src/scanner.c" ] && files="$files $src/scanner.c"
    # shellcheck disable=SC2086
    cc -O2 -shared -fPIC -w -I "$src" $files -o "$out/parser/$name.so"
    echo "$rev" > "$out/parser/$name.revision"
done
