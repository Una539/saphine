#!/bin/sh
set -eu

project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project"
export ZIG_GLOBAL_CACHE_DIR="$project/.zig-cache/global"
zig build
compiler="$project/zig-out/bin/saphine"
scratch=$(mktemp -d "$project/.zig-cache/acceptance.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"

positive() {
    "$compiler" check "$project/examples/basics/$1.saph"
    "$compiler" emit-zig "$project/examples/basics/$1.saph" -o "$1.zig"
    zig build-exe "$1.zig" "-femit-bin=$1-emitted"
    "$compiler" build "$project/examples/basics/$1.saph" -o "$1"
    "./$1" > actual
    "./$1-emitted" > emitted
    diff -u "$project/examples/basics/outputs/$1.out" actual
    diff -u "$project/examples/basics/outputs/$1.out" emitted
}

count=0
for source in "$project"/examples/basics/*.saph; do
    name=${source##*/}
    positive "${name%.saph}"
    count=$((count + 1))
done

printf '%s native examples passed.\n' "$count"
