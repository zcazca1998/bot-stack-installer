## **本项目代码 100% 由 AI 编写，人类负责需求、设计决策与验收。**

# nbot

[![CI](https://github.com/zcazca1998/nbot-linux/actions/workflows/ci.yml/badge.svg)](https://github.com/zcazca1998/nbot-linux/actions/workflows/ci.yml)

Debian / Ubuntu / Armbian 上的 **AstrBot + SnowLuma + Linux QQ** 一键部署器。
自动识别 amd64 与 arm64，不安装 Docker，全部服务由原生 systemd 管理。

安装后用 `sudo nbot` 进入交互菜单，或 `nbot help` 查看全部命令。

---

## 快速开始

**国内机器**（脚本本身也走加速站）：

~~~bash
curl -fsSL https://gh-proxy.com/https://raw.githubusercontent.com/zcazca1998/nbot-linux/main/bootstrap.sh | sudo bash
~~~

**海外机器**（直连）：

~~~bash
curl -fsSL https://raw.githubusercontent.com/zcazca1998/nbot-linux/main/bootstrap.sh | sudo bash
~~~

一条命令走完：探测网络环境 → 选择镜像 → 装 AstrBot → 拆 SnowLuma+QQ 镜像 →
注册服务与看门狗 → 扫码登录 → 配置 OneBot 对接 → 打印下一步指引。

加速站不通时换 `ghfast.top` 或 `ghproxy.net` 前缀。想先看菜单而不是直接安装，
在 `sudo` 后加 `NBOT_ARGS=menu`。

手动克隆也可以：

~~~bash
git clone https://github.com/zcazca1998/nbot-linux.git
cd nbot && sudo ./install.sh
~~~

装完后在任意目录都能用 `sudo nbot`。

---

## 命令速查

`sudo nbot` 无参数进入交互菜单；`nbot help` 随时查看完整列表。

### 安装与配置

| 命令 | 说明 |
| --- | --- |
| `nbot install-all` | 一键安装全部（推荐） |
| `nbot install-astrbot` | 安装 / 更新 AstrBot |
| `nbot install-snowluma` | 安装 / 更新 SnowLuma + QQ |
| `nbot install-novnc` | 安装 noVNC 远程画面 |
| `nbot install-caddy` | 安装 / 配置 Caddy 反向代理 |
| `nbot configure` | 基础配置（目录 / 端口 / 代理 / 镜像 / 日志上限） |
| `nbot configure-onebot` | 配置 OneBot 对接 AstrBot，并显示 token |
| `nbot repair` | 重装服务、看门狗、控制脚本与日志轮转 |
| `nbot uninstall` | 卸载（默认保留数据，删数据需输入 `DELETE`） |

### QQ 登录

| 命令 | 说明 |
| --- | --- |
| `nbot login` | 终端扫码登录 |
| `nbot login --fresh` | 被踢下线 / 登录过期后强制重新扫码 |
| `nbot refresh` | 手动点击刷新二维码 |
| `nbot qq status` | 查询 QQ 在线状态 |

### 组件控制

四个组件 `astrbot`、`snowluma`、`qq`、`novnc` 共用同一套动作：

~~~bash
nbot <组件> start|stop|restart|status|logs|update|version|rollback
~~~

| 示例 | 说明 |
| --- | --- |
| `nbot astrbot restart` | 重启 AstrBot |
| `nbot snowluma logs -f` | 实时跟踪 SnowLuma + QQ 日志 |
| `nbot astrbot logs -n 200` | 查看最近 200 行 |
| `nbot qq restart` | 重启 QQ（会先停 SnowLuma，避免 Hook 悬空） |
| `nbot snowluma update` | 重新拆镜像更新 SnowLuma + QQ |
| `nbot astrbot version` | 显示当前版本与可回滚的版本 |
| `nbot astrbot rollback` | 退回上一个版本（**不必知道版本号**） |
| `nbot snowluma rollback` | 退回上一个 SnowLuma + QQ 载荷 |

### 上游发了坏版本怎么办

安装器默认装最新版，但**每次更新都会留着上一个版本**，所以不需要你事先知道
哪个版本有 bug：

~~~bash
nbot astrbot version     # 看当前版本和可退回的版本
nbot astrbot rollback    # 直接退回上一版
~~~

回滚是**双向切换**：再执行一次 `rollback` 就切回去，不会把自己锁死。
新版本装不起来时安装器本来就会自动恢复旧版；`rollback` 解决的是
「装起来了但用着有问题」这种情况。

SnowLuma 的回滚只切程序载荷的软链接，配置、缓存和 QQ 登录态都不在版本目录里，
所以回滚不会丢登录态、不用重新扫码。

noVNC 与 Caddy 另有专属动作：

| 命令 | 说明 |
| --- | --- |
| `nbot novnc url` | 显示可直接打开的完整访问地址 |
| `nbot novnc password` | 查看 VNC 密码（仅未装反代时使用） |
| `nbot novnc set-password` | 更换 VNC 密码（仅未装反代时使用） |
| `nbot novnc proxy-example` | 打印 Nginx / Caddy 反代配置示例 |
| `nbot caddy set-auth` | 更换网页登录账号 / 密码 |
| `nbot caddy status` | Caddy 运行状态 |
| `nbot caddy logs` | Caddy 日志 |
| `nbot astrbot webui` | 显示 AstrBot WebUI 地址与初始密码 |
| `nbot snowluma webui` | 显示 SnowLuma WebUI 地址与初始密码 |
| `nbot astrbot set-password` | 重置 AstrBot WebUI 密码 |
| `nbot snowluma set-password` | 重置 SnowLuma WebUI 密码 |

### 凭据一览与重置

**两个 WebUI 的初始密码都是首次启动时随机生成、只打印在日志里的**，
不是固定的默认密码。忘记了直接重置，不必翻日志：

| 凭据 | 初始值 | 查看 | 重置 |
| --- | --- | --- | --- |
| AstrBot WebUI | 账号 `astrbot`，密码随机 24 位 | `nbot astrbot webui` | `nbot astrbot set-password` |
| SnowLuma WebUI | 账号 `admin`，密码随机 16 位 | `nbot snowluma webui` | `nbot snowluma set-password` |
| 网页登录（Caddy） | 账号 `admin`，安装时可自填 | 只存哈希，无法查看 | `nbot caddy set-auth` |
| OneBot token | `configure-onebot` 时显示 | 读 SnowLuma 配置 | `nbot configure-onebot` |

`webui` 子命令会自动从日志里提取初始密码并连同地址一起显示；日志已轮转掉时
就用 `set-password` 重置。重置走的是各自的官方途径（AstrBot 的
`ASTRBOT_RESET_DASHBOARD_PASSWORD`、SnowLuma 的重新生成机制），
不会手改密码哈希，所以升级后也不会失配。

密码要求：AstrBot ≥ 8 位；SnowLuma ≥ 10 位且需含大小写与特殊字符、不能有空格。
留空则由对应程序随机生成并显示。

**装了 Caddy 之后 noVNC 没有单独的密码**：访问必经 Caddy 的账号密码，
而 noVNC 与 VNC 端口都只监听回环，回环上再加一道 VNC 密码不增加安全性。
所以 x11vnc 以 `-nopw` 运行，改密码只需 `nbot caddy set-auth` 一处。
没装反向代理时才启用 VNC 密码，可用 `nbot novnc password` 查看、
`nbot novnc set-password` 更换。

### 状态与诊断

| 命令 | 说明 |
| --- | --- |
| `nbot status` | 全部服务状态总览 |
| `nbot doctor` | 环境诊断（挂载、端口、WebUI 探活） |
| `nbot logs astrbot` | AstrBot 完整日志 |
| `nbot logs snowluma` | SnowLuma + QQ 完整日志 |
| `nbot logs watchdog` | 看门狗动作记录（何时重启了什么、为什么） |

---

## 安装后

| 服务 | 默认地址 | 登录 |
| --- | --- | --- |
| AstrBot WebUI | `http://服务器IP:6185` | `astrbot` + 随机密码（`nbot astrbot webui` 查看） |
| SnowLuma WebUI | `http://服务器IP:5099` | `admin` + 随机密码（`nbot snowluma webui` 查看） |

对接步骤（`install-all` 会自动引导，也可手动执行）：

1. `sudo nbot login` 扫码登录 QQ
2. `sudo nbot configure-onebot` 生成配置并**显示 token**
3. AstrBot WebUI → 平台适配器 → 添加 **OneBot v11（aiocqhttp）** → 端口 `6199` + 上一步的 token

---

## 目录结构

统一工作区，各组件按名字分开，基础配置里可整体或单独修改：

~~~text
/nbot/
├── astrbot/            AstrBot 数据、venv、托管 Python
├── snowluma/           SnowLuma 配置、缓存、QQ 登录态
└── payload/snowluma/   SnowLuma、QQ、Node 程序载荷（版本化）
~~~

系统盘只放 systemd unit、控制脚本和 `/etc/nbot.conf`。
拆镜像时载荷目录需要至少 6 GiB 可用空间（临时层用完即清）。

安装前确认数据盘已挂载：

~~~bash
findmnt --target /nbot
df -h /nbot
~~~

脚本不会格式化磁盘，也不会修改 `/etc/fstab`。
从旧版 `bot-stack` 升级时会自动迁移命名，数据目录不动。

---

## 国内网络优化

首次运行基础配置会**实测**能否直连 GitHub 与 PyPI：海外机器默认全部直连，
国内机器默认启用镜像。三条链路都逐级回退，每一项都能在菜单里选或自己填。

| 链路 | 回退顺序 | 候选 |
| --- | --- | --- |
| GitHub | 代理 → 加速站 → 直连 | gh-proxy.com、ghfast.top、ghproxy.net、全部依次尝试、不加速 |
| 容器镜像 | 首选 → 备用 → Docker Hub | dockerproxy.net、docker.1ms.run、m.daocloud.io/docker.io、docker.xuanyuan.me、不加速 |
| pip | 镜像 → 官方 PyPI | 清华 TUNA（默认）、阿里云、腾讯云、中科大 USTC、华为云、官方 |

镜像切换时已下载的 blob 会复用，不必从头再来。
pip 的 `trusted-host` 自动从索引地址推导，填自建镜像也不用额外配置。

### GitHub API 限流

安装器要读 AstrBot 最新版本号，走的是 GitHub API——**匿名调用每个 IP 每小时
只有 60 次**。共用出口 IP（校园网、公司网、部分云厂商）或短时间反复重装容易
触顶，表现为「无法读取最新版本」。此时安装器会明确提示限流，两种解法：

- 等一小时配额自动恢复
- 用令牌提额到 5000 次/小时（令牌只发给 `api.github.com`，不会给加速站）：

~~~bash
sudo GITHUB_TOKEN=ghp_你的令牌 nbot install-astrbot
~~~

令牌在 GitHub → Settings → Developer settings → Personal access tokens 生成，
**不需要勾任何权限**，公开仓库的只读调用用不到。

### 无人值守安装

所有提问在没有终端时都会取默认值，因此可以完全自动化：

~~~bash
# 环境变量覆盖
sudo NBOT_NONINTERACTIVE=1 \
     PIP_INDEX_URL=https://pypi.mycorp.internal/simple \
     GITHUB_MIRRORS=https://my.gh.proxy \
     nbot install-all
~~~

~~~bash
# 或直接写配置文件
sudo tee /etc/nbot.conf >/dev/null <<'EOF'
PIP_INDEX_URL=https://pypi.mycorp.internal/simple
GITHUB_MIRRORS=
EOF
sudo nbot install-all
~~~

---

## noVNC 与反向代理

可选安装浏览器远程画面，用于观察或操作 QQ 的 Xvfb 桌面：

~~~bash
sudo nbot install-novnc
~~~

- websockify 与 x11vnc **只绑定 127.0.0.1**，不直接暴露公网。
- noVNC 用相对路径，可挂在 `/novnc/` 之类子路径下；websockify 开了 30 秒心跳，
  不会被反代空闲超时掐断。
- x11vnc 复用 QQ 的 `DISPLAY :91` 与 Xauthority，随 QQ 服务启停。
- VNC 密码在 `/nbot/snowluma/config/vnc-password`（`nbot novnc password` 查看），
  它只是第二层防护，**鉴权必须由反代承担**。

安装器可以直接接管 Caddy（装完 noVNC 会询问，也可单独执行）：

~~~bash
sudo nbot install-caddy
~~~

- 二进制从 GitHub Release 下载（走同一套加速回退）；系统已有 apt 版 Caddy 时不覆盖。
- 填域名 → 自动申请 HTTPS 证书；留空 → 本地自签名证书 + 自定义端口（默认 8443），
  纯 IP 访问也能用。
- 自动生成 basic_auth 登录（账号默认 `admin`，密码可自填或随机生成）。
- 站点配置独立在 `/etc/caddy/conf.d/novnc.caddy`；已有 Caddyfile 只追加一行
  `import` 并自动备份。
- 启动前 `caddy validate` 校验，自签名模式还会自测「未认证 401 / 带凭据 200」。

---

## 运行机制

### 部署方式

- AstrBot 使用普通 Python venv（不用 uv）；系统缺 Python 3.12+ 时会把官方
  python-build-standalone 3.13 放到 `/nbot/astrbot/.python` 再建 venv。
- SnowLuma 与 QQ 从官方多架构 OCI 镜像**拆包**取得，不安装也不运行 Docker daemon。
- QQ 与 SnowLuma 共用同一个 `snowluma` 用户、DISPLAY、D-Bus 和 Hook 运行目录。
- Node 保留 `cap_sys_ptrace=ep` 以满足官方 Hook 要求。
- 程序载荷通过软链接原子切换，配置、缓存和登录态不放在版本目录；更新失败会恢复
  旧链接，成功后只保留当前和上一个 release。
- 所有更新手动触发，不启用定时自动更新。

### 守护策略

- 主服务用 `Restart=on-failure` + `StartLimitBurst=3`（5 分钟窗口），
  用**活了多久**区分两种失败：
  - 跑着跑着崩了（偶发 bug、被 OOM 杀掉、外部因素）→ 自动拉起
  - 起来就崩（配置错、端口占用）→ 试 3 次后停手，停在 `failed` 等人处理
- **看门狗与 systemd 遵守同一套判据**：服务处于 `failed`（systemd 已放弃）或
  `inactive`（用户主动停止）时，看门狗一律不动作，也不累积失败计数。
  不会出现「systemd 放弃了、看门狗还在反复拉」的情况。
- 触顶后连手动启动都会被 systemd 拒绝，所以 `nbot <组件> start/restart`
  和 `nbot repair` 会先自动 `reset-failed`，修好问题就能正常启动。
- WebUI 或 Hook **连续三次**检查失败才判定假死并重启，单次波动不触发。
- Hook 丢失优先只重启 SnowLuma，不轻易重启 QQ。
- QQ 掉线只自动恢复一次，仍需登录时等待人工 `nbot login`。
- QQ 的 Xvfb / D-Bus 运行时保护独立于 SnowLuma 状态，SnowLuma 停止时同样生效。

### 被踢下线与登录过期

- `nbot login` 发现本地登录态为已登录、但 OneBot 实测不在线时，判定为被踢，
  询问后重启 QQ 并清除过期登录态（`login.enc` 先备份为 `.expired.bak`）。
- 扫码时长时间抓不到二维码会分级自愈：先重启 QQ 清「登录已过期」弹窗；
  仍无二维码则清登录态后再重启，强制回到扫码页。
- 快捷登录按钮采用**视觉定位**（识别登录页上的品牌蓝按钮并点击质心），
  不依赖固定坐标或窗口尺寸，QQ 改版和换分辨率都能自适应。
- 也可直接 `nbot login --fresh` 一步到位。

### 日志限制

- 应用日志由 logrotate 按单文件 20M、保留 7 天轮转。
- QQ 客户端日志与崩溃转储每日清理，保留 7 天；临时目录残留保留 3 天。
- journald 总量上限在基础配置里设置（默认建议 500M，留空则不改系统默认）。

---

## 开发

~~~bash
# 离线测试（无需网络与 root）
for f in tests/*-check.sh; do bash "$f"; done
~~~

CI（`.github/workflows/ci.yml`）：

- `tests` — 每次推送跑全部离线测试、语法检查与 ShellCheck
- `astrbot-e2e` — 每次推送在干净 runner 上**真实完整安装** AstrBot 并验证 WebUI
- `full-stack` — 手动触发，真实拆 SnowLuma 镜像并验证 noVNC + Caddy 反代链路

`.github/workflows/qr-debug.yml` 手动触发后会装好全栈并开一个 tmate SSH 通道，
用于人工验证扫码登录这类无法自动化的流程。

踩坑记录见 [PITFALLS.md](PITFALLS.md)。

---

## 许可

[GPL-3.0](LICENSE)。衍生作品需以相同许可开源。
