#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SOURCE_DIR/lib/common.sh"
require_root
detect_os
detect_arch
# 旧的 bot-stack 安装先迁移命名，再归一化配置：已有值经 source 保留，
# 缺失的键补上默认值，手写的部分配置文件由此变成全量配置。
migrate_legacy_layout
write_config
run_dir=$(mktemp -d)
trap 'rm -rf "$run_dir"' EXIT
# 排除 .git：只需要运行时文件，且源目录被 git 操作时复制历史对象会失败。
tar -C "$SOURCE_DIR" --exclude=./.git -cf - . | tar -C "$run_dir" -xf -
bash "$run_dir/install-core.sh" "$@"
