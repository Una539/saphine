#!/bin/sh
set -eu
project=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
export ZIG_GLOBAL_CACHE_DIR="$project/.zig-cache/global"
cd "$project"
zig build
compiler="$project/zig-out/bin/saphine"
scratch=$(mktemp -d "$project/.zig-cache/zig-interop.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
cd "$scratch"
mkdir moved
cases="$project/examples/zig-interop"

"$compiler" check "$cases/main.saph"
"$compiler" check "$cases/main.saph" --target aarch64-linux --optimize ReleaseSafe
"$compiler" emit-zig "$cases/main.saph" -o program.zig
"$compiler" build "$cases/main.saph" -o native
./native > actual
diff -u "$cases/outputs/main.out" actual
zig fmt --check program.zig
python3 - <<'PY'
import json
from pathlib import Path

data = Path("program.zig").read_bytes()
source_map = json.loads(Path("program.zig.map.json").read_text())
assert source_map["version"] == 1
calls = [entry for entry in source_map["mappings"] if entry["call_site"]]
assert calls and all(entry["source"]["path"] == "main.saph" for entry in calls)
for entry in calls:
    text = data[entry["generated_start"]:entry["generated_end"]]
    assert text.startswith(b"zig_call_") and b"break :zig_call_" in text
PY
mv program.zig program.deps moved/
sh moved/program.deps/build.sh -femit-bin=relocated
moved/relocated > actual
diff -u "$cases/outputs/main.out" actual
cp -R "$cases" cache-fixture
"$compiler" build cache-fixture/main.saph -o cache-baseline
./cache-baseline > actual
diff -u "$cases/outputs/main.out" actual
cp "$cases/resources/updated.txt" cache-fixture/modules/parts/resource.txt
"$compiler" build cache-fixture/main.saph -o rebuilt
./rebuilt > actual
test "$(sed -n '9p' actual)" = 5

"$compiler" emit-zig "$cases/named.saph" -o named.zig --zig-config "$cases/packages.json"
mv named.zig named.deps moved/
sh moved/named.deps/build.sh -femit-bin=named
moved/named > actual
diff -u "$cases/outputs/named.out" actual
"$compiler" check "$cases/named.saph" --zig-module "named=$cases/modules/named.zig" --zig-module "arithmetic=$cases/modules/math.zig"

"$compiler" check "$cases/stdlib.saph"
"$compiler" emit-zig "$cases/stdlib.saph" -o stdlib.zig
test ! -e stdlib.deps
zig build-exe stdlib.zig -femit-bin=stdlib-test
./stdlib-test > actual
diff -u "$cases/outputs/stdlib.out" actual
"$compiler" check "$cases/text.saph"
"$compiler" build "$cases/text.saph" -o text-example
./text-example > actual
diff -u "$cases/outputs/text.out" actual
printf 'Zig interop acceptance passed.\n'

memory_cases="$project/examples/memory"
zig test "$project/src/stdlib/memory.zig"
"$compiler" emit-zig "$memory_cases/main.saph" -o memory.zig
mkdir memory-relocated
mv memory.zig memory.deps memory-relocated/
sh memory-relocated/memory.deps/build.sh -femit-bin=memory-test
memory-relocated/memory-test > actual
diff -u "$memory_cases/expected.out" actual

"$compiler" emit-zig "$memory_cases/managed.saph" -o managed.zig
mkdir managed-relocated
mv managed.zig managed.deps managed-relocated/
sh managed-relocated/managed.deps/build.sh -femit-bin=managed-test
managed-relocated/managed-test > actual
diff -u "$memory_cases/managed.out" actual

"$compiler" emit-zig "$memory_cases/interfaces.saph" -o interfaces.zig
mkdir interfaces-relocated
mv interfaces.zig interfaces.deps interfaces-relocated/
sh interfaces-relocated/interfaces.deps/build.sh -femit-bin=interfaces-test
interfaces-relocated/interfaces-test > actual
diff -u "$memory_cases/interfaces.out" actual

