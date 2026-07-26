#!/usr/bin/env bash
# shellcheck source=common-base.sh
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common-base.sh"

atomic_symlink() {
  local target=$1
  local link=$2
  local temp="${link}.new"
  ln -sfn "$target" "$temp"
  mv -Tf "$temp" "$link"
}
