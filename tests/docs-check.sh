#!/usr/bin/env bash
# 文档与实现一致性：README 和 nbot help 里出现的命令必须真的能分发。
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# 提取 main() 的 case 分支作为可用命令清单。
mapfile -t dispatch < <(
  sed -n '/^  case "${1:-menu}"/,/^  esac/p' "$ROOT/install-core.sh" |
    grep -oE '^\s+[a-z|_-]+\)' | tr -d ' )' | tr '|' '\n' | sort -u
)
[[ ${#dispatch[@]} -gt 10 ]] || { echo '未能解析命令分发表' >&2; exit 1; }
has_command() {
  local want=$1 have
  for have in "${dispatch[@]}"; do
    [[ "$have" == "$want" ]] && return 0
  done
  return 1
}

# 组件控制是 nbot <组件> <动作>，组件名本身就是分发分支。
components=(astrbot snowluma qq novnc)
for c in "${components[@]}"; do
  has_command "$c" || { echo "组件未接入分发：$c" >&2; exit 1; }
done

# README 中反引号包裹的 nbot 命令，取第一个词校验。
missing=()
while read -r cmd; do
  [[ -n "$cmd" ]] || continue
  has_command "$cmd" || missing+=("README: nbot $cmd")
done < <(grep -oE '`nbot [a-z][a-z-]*' "$ROOT/README.md" |
           sed 's/`nbot //' | sort -u)

# nbot help 的命令区块：缩进两格 + 至少两个空格对齐说明列，
# 这样散文段落和 heredoc 行不会被误当成命令。
while read -r cmd; do
  [[ -n "$cmd" ]] || continue
  has_command "$cmd" || missing+=("help: $cmd")
done < <(
  sed -n "/^show_help() {/,/^}/p" "$ROOT/install-core.sh" |
    grep -oE '^  [a-z][a-z-]+ {2,}' | tr -d ' ' | sort -u
)

if ((${#missing[@]})); then
  printf '文档提到但未实现的命令：\n' >&2
  printf '  %s\n' "${missing[@]}" >&2
  exit 1
fi

# 反过来：核心命令必须在 README 里有交代，避免文档漏写。
for cmd in install-all install-astrbot install-snowluma install-novnc \
           install-caddy configure configure-onebot repair uninstall \
           login refresh status doctor logs; do
  grep -q "nbot $cmd" "$ROOT/README.md" ||
    { echo "README 未记录命令：nbot $cmd" >&2; exit 1; }
done

# 一键安装命令必须指向真实仓库，且国内版带加速前缀。
grep -q 'raw.githubusercontent.com/zcazca1998/nbot-linux/main/bootstrap.sh' "$ROOT/README.md"
grep -q 'gh-proxy.com/https://raw.githubusercontent.com' "$ROOT/README.md"

echo 'Docs consistency checks passed.'
