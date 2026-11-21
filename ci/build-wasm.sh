#!/bin/sh
# Builds `golemide edit` as a WebAssembly component that starts no process:
# build/golemide-edit.wasm (src/component.almd).
#
#   ci/build-wasm.sh
#
# The source is copied, wasm/spawn.almd is put in place of src/spawn.almd (the one file
# that starts a program), and the copy's edit entry point is built for the wasm target.
# solve is not in it: it calls a model and runs the verify command, and is native.
set -eu
here=$(cd "$(dirname "$0")/.." && pwd)
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
cp -R "$here/src" "$here/almide.toml" "$here/almide.lock" "$work/"
cp "$here/wasm/spawn.almd" "$work/src/spawn.almd"
mkdir -p "$here/build"
( cd "$work" && "${ALMIDE:-almide}" build src/component.almd --target wasm -o "$here/build/golemide-edit.wasm" )
