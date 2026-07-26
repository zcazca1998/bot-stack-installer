#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
NBOT_CONFIG=/nonexistent
source "$ROOT/lib/common.sh"

# 选第 1 项（清华）
PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/
pick_option PIP_INDEX_URL 'pip' "$PIP_INDEX_URL" PIP_MIRROR_CHOICES <<<'1' >/dev/null
[[ "$PIP_INDEX_URL" == https://pypi.tuna.tsinghua.edu.cn/simple ]]

# 选第 4 项（USTC）
pick_option PIP_INDEX_URL 'pip' "$PIP_INDEX_URL" PIP_MIRROR_CHOICES <<<'4' >/dev/null
[[ "$PIP_INDEX_URL" == https://mirrors.ustc.edu.cn/pypi/simple ]]

# 自定义填写（第 7 项）：用户可以填任何自建镜像
pick_option PIP_INDEX_URL 'pip' "$PIP_INDEX_URL" PIP_MIRROR_CHOICES \
  <<<$'7\nhttps://pypi.example.internal/simple' >/dev/null
[[ "$PIP_INDEX_URL" == https://pypi.example.internal/simple ]]

# 回车 = 保持当前值
pick_option PIP_INDEX_URL 'pip' "$PIP_INDEX_URL" PIP_MIRROR_CHOICES <<<'' >/dev/null
[[ "$PIP_INDEX_URL" == https://pypi.example.internal/simple ]]

# 无效输入后重试，直到有效编号
pick_option PIP_INDEX_URL 'pip' "$PIP_INDEX_URL" PIP_MIRROR_CHOICES \
  <<<$'99\nabc\n2' >/dev/null 2>&1
[[ "$PIP_INDEX_URL" == https://mirrors.aliyun.com/pypi/simple/ ]]

# trusted-host 从索引地址推导
[[ $(host_of_url https://pypi.tuna.tsinghua.edu.cn/simple) == pypi.tuna.tsinghua.edu.cn ]]
[[ $(host_of_url https://mirrors.aliyun.com/pypi/simple/) == mirrors.aliyun.com ]]

# 「不使用加速」选项必须产生空值，而不是字面显示名
GITHUB_MIRRORS=https://gh-proxy.com
pick_option GITHUB_MIRRORS 'github' "$GITHUB_MIRRORS" GITHUB_MIRROR_CHOICES <<<'5' >/dev/null
[[ -z "$GITHUB_MIRRORS" ]]

# 「全部依次尝试」保留逗号分隔的完整列表
pick_option GITHUB_MIRRORS 'github' "$GITHUB_MIRRORS" GITHUB_MIRROR_CHOICES <<<'4' >/dev/null
[[ "$GITHUB_MIRRORS" == *gh-proxy.com*ghfast.top*ghproxy.net* ]]

# 容器镜像候选同样支持清空
SNOWLUMA_IMAGE_MIRROR=dockerproxy.net
pick_option SNOWLUMA_IMAGE_MIRROR 'image' "$SNOWLUMA_IMAGE_MIRROR" IMAGE_MIRROR_CHOICES <<<'5' >/dev/null
[[ -z "$SNOWLUMA_IMAGE_MIRROR" ]]

echo 'Mirror menu checks passed.'
