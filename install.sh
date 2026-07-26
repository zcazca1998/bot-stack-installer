#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SOURCE_DIR/lib/common.sh"
require_root
detect_os
detect_arch
# 始终重写配置：已有值经 source 保留，缺失的键补上默认值，
# 手写的部分配置文件由此归一化为全量配置。
write_config
run_dir=$(mktemp -d)
trap 'rm -rf "$run_dir"' EXIT
cp -a "$SOURCE_DIR/." "$run_dir/"
bash "$run_dir/install-core.sh" "$@"
