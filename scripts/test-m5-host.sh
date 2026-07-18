#!/bin/sh
set -eu

script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
project_root=$(dirname "$script_dir")
firmware_dir="$project_root/firmware/m5stickc"
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/codex-m5-host-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT HUP INT TERM

compile_and_run() {
  name=$1
  source=$2

  c++ -std=c++17 -Wall -Wextra -Werror \
    -I"$firmware_dir/src" \
    "$firmware_dir/test-host/${name}_test.cpp" \
    "$firmware_dir/src/$source" \
    -o "$build_dir/$name"
  "$build_dir/$name"
}

compile_and_run codex_rpc_protocol codex_rpc_protocol.cpp
compile_and_run ride_protocol ride_protocol.cpp
compile_and_run voice_button_controller voice_button_controller.cpp

echo "M5 host tests passed"
