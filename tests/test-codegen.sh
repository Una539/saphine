#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ZIG_GLOBAL_CACHE_DIR="$project/.zig-cache/global"
cd "$project"
zig build
compiler="$project/zig-out/bin/saphine"
scratch=$(mktemp -d "$project/.zig-cache/codegen.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
mkdir first second
cat > first/app.saph <<'LANG'
const add = fn(a: i32, b: i32) -> i32 { return a + b; };
const switch = fn(值: i32) -> i32 { return 值; };
const Point = struct { switch: i32, 值: i32, };
const choose = fn(T: type, value: i32) -> i32 { return value; };
const main = fn() -> void {
    const point = Point { .switch = 2, .值 = 3 };
    print(add(point.switch, point.值));
    print(switch(choose(i32, 4)));
    print(choose(bool, 5));
    const x = 1;
    { const x = 2; print(x); }
    print(x);
};
LANG
{ printf '%s\n' 'const unused = fn() -> i32 { return 0; };'; cat first/app.saph; } > second/app.saph
for directory in first second; do
    "$compiler" emit-zig "$directory/app.saph" -o "$directory/app.zig"
    zig build-exe "$directory/app.zig" "-femit-bin=$directory/program"
    "$directory/program" > "$directory/out"
    python3 - "$directory/app.zig" > "$directory/signatures" <<'PY'
import re
import sys
from pathlib import Path

source = Path(sys.argv[1]).read_text()
if re.search(r"\b(?:fn F|const [SE])\d+", source):
    raise SystemExit("numeric emitted symbol")
wanted = {"add", '@"switch"', "choose__i32", "choose__bool"}
functions = {}
for name, params, result in re.findall(r"^fn (.+?)\((.*?)\) ([^\n{]+) \{", source, re.M | re.S):
    if name in wanted:
        functions[name] = f"fn {name}({params.strip().rstrip(',').strip()}) {result}"
for name in sorted(wanted):
    print(functions[name])
assert re.search(r'^const Point = struct \{', source, re.M)
assert re.search(r'^    @"switch": i32,', source, re.M)
assert 'const x__1: i32' in source
PY
done
cat > signatures <<'GOLDEN'
fn @"switch"(@"值": i32) i32
fn add(a: i32, b: i32) i32
fn choose__bool(value: i32) i32
fn choose__i32(value: i32) i32
GOLDEN
diff -u signatures first/signatures
diff -u first/signatures second/signatures
diff -u first/out second/out
printf 'Codegen golden passed.\n'
