#!/usr/bin/env bash
set -Eeuo pipefail
SOURCE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
source "$SOURCE_DIR/lib/common.sh"
require_root
detect_os
detect_arch
if [[ ! -r "$CONFIG_FILE" ]]; then
  write_config
fi
run_dir=$(mktemp -d)
trap 'rm -rf "$run_dir"' EXIT
cp -a "$SOURCE_DIR/." "$run_dir/"
bash "$run_dir/install-core.sh" "$@"
