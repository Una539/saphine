#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project"
export ZIG_GLOBAL_CACHE_DIR="$project/.zig-cache/global"
zig build
compiler="$project/zig-out/bin/saphine"
cases="$project/examples/modules"
scratch=$(mktemp -d "$project/.zig-cache/modules.XXXXXX")
failures=0
positive_count=0
cleanup() {
    if [ "$failures" -eq 0 ]; then rm -rf "$scratch";
    else printf 'Failure artifacts: %s\n' "$scratch"; fi
}
trap cleanup EXIT
cd "$scratch"

for source in "$cases"/*.saph; do
    name=${source##*/}
    name=${name%.saph}
    positive_count=$((positive_count + 1))
    if "$compiler" check "$source" &&
       "$compiler" emit-zig "$source" -o "$name.zig" &&
       zig build-exe "$name.zig" "-femit-bin=$name-emitted" &&
       "$compiler" build "$source" -o "$name-native" &&
       "./$name-emitted" > "$name-emitted.out" &&
       "./$name-native" > "$name-native.out" &&
       diff -u "$cases/outputs/$name.out" "$name-emitted.out" &&
       diff -u "$cases/outputs/$name.out" "$name-native.out"; then
        printf 'PASS %s\n' "$name"
    else
        failures=$((failures + 1))
        printf 'FAIL %s\n' "$name" >&2
    fi
done

printf '%s module programs, %s failures.\n' "$positive_count" "$failures"
[ "$failures" -eq 0 ]
