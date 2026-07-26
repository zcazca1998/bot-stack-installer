# nbot — AstrBot + SnowLuma + QQ 一键部署器

面向 Debian、Ubuntu、Armbian 的 AstrBot + SnowLuma + Linux QQ 部署脚本，自动识别 amd64/x86_64 与 arm64/aarch64。

## 部署方式

- AstrBot 使用普通 Python venv，不使用 uv。
- 若系统缺少 Python 3.12+，安装器会把官方 python-build-standalone 3.13 运行时放到 /nbot/astrbot/.python，再创建普通 venv。
- SnowLuma 与 QQ 从 SnowLuma 官方多架构 OCI 镜像拆出，但不会安装或运行 Docker daemon。
- 镜像内的 SnowLuma、QQ 和 Node 被复制到数据盘，然后由原生 systemd 管理。
- QQ 与 SnowLuma 使用同一个 snowluma 用户、DISPLAY、D-Bus 和 Hook 运行目录。
- Node 保留 cap_sys_ptrace=ep，以满足官方 Hook 要求。
- 所有更新均手动触发，不启用定时自动更新。

默认目录（统一工作区，基础配置里可整体或单独自定义）：

- 统一工作区：/nbot
- AstrBot 数据：/nbot/astrbot
- SnowLuma 配置、缓存和 QQ 登录态：/nbot/snowluma
- SnowLuma、QQ、Node 程序载荷：/nbot/payload/snowluma
- 系统盘只保存小型 unit、控制脚本和 /etc/nbot.conf
- 旧版本装过的机器沿用 /etc/nbot.conf 里已保存的路径，不受新默认值影响

拆镜像时载荷目录至少需要 6 GiB 可用空间。临时 OCI 层与 rootfs 会在成功或失败后清除。

## 使用

~~~bash
cd nbot
chmod +x install.sh
sudo ./install.sh        # 首次；安装后任何目录直接 sudo nbot
~~~

无参数进入交互菜单；推荐直接一键安装（配置 → AstrBot → SnowLuma+QQ → 服务与看门狗 → 可选 noVNC/Caddy → 输出总结与下一步指引）：

~~~bash
sudo ./install.sh install-all
~~~

也可分步执行：

~~~bash
sudo ./install.sh install-snowluma
sudo ./install.sh install-astrbot
sudo ./install.sh repair
~~~

卸载（默认保留数据；删数据需要二次确认并输入 DELETE）：

~~~bash
sudo nbot uninstall
~~~

安装器注册 `nbot` 命令，后续在任意目录可执行：

~~~bash
nbot status
nbot doctor
nbot update-astrbot
nbot update-snowluma
nbot configure-onebot
nbot logs astrbot
nbot logs snowluma
~~~

可选安装 noVNC 远程画面（浏览器里查看/操作 QQ 的 Xvfb 桌面）：

~~~bash
sudo ./install.sh install-novnc
~~~

- websockify 与 x11vnc 都只绑定 127.0.0.1，不直接暴露公网；请用 Nginx 或 Caddy 反向代理并叠加 HTTPS 与鉴权。
- 现成的反代示例（含 WebSocket upgrade、超时、Caddy basic_auth）写在 /usr/local/lib/nbot/novnc-proxy.example，`novncctl proxy-example` 可随时查看。
- noVNC 使用相对路径，可直接挂在 /novnc/ 之类的子路径下；websockify 开启了 30 秒心跳，避免被反代空闲超时断开。
- x11vnc 复用 QQ 的 DISPLAY :91 与 Xauthority，随 snowluma-qq.service 启停（PartOf）。
- VNC 密码保存在 /nbot/snowluma/config/vnc-password，`novncctl password` 查看；它只是第二层防护，鉴权必须由反代承担。

安装器可以直接接管 Caddy（noVNC 装完会询问，也可单独执行）：

~~~bash
sudo ./install.sh install-caddy
~~~

- Caddy 二进制从 GitHub Release 下载（走 GITHUB_ACCESS 的代理/直连回退），amd64/arm64 自动匹配；系统里已有 apt 安装的 Caddy 时不重复安装、不覆盖发行版 unit。
- 两种模式：填域名 → 自动申请 HTTPS 证书（需 80/443 对外可达）；留空 → 本地生成自签名证书 + 自定义端口（默认 8443），纯 IP 访问也能用（IP 连接不带 SNI，显式证书不受影响）。
- 自动生成 basic_auth 登录（账号默认 admin，密码可自填或随机生成，bcrypt 哈希存入配置）。
- 站点配置独立在 /etc/caddy/conf.d/novnc.caddy；已有 Caddyfile 只追加一行 import 并自动备份，不覆盖原配置。
- 启动前 `caddy validate` 校验；自签名模式还会自测「未认证 401 / 带凭据 200」。

~~~bash
novncctl status
novncctl url
novncctl password
novncctl proxy-example
novncctl logs -f
~~~

QQ 登录与管理：

~~~bash
qqlogin
qqlogin --fresh
qqrefresh
snowlumactl status
snowlumactl logs -f
snowlumactl qq-status
snowlumactl qq-restart
snowlumactl update
~~~

## 下载策略

GitHub 支持三种模式：

- auto：先使用配置代理，失败后自动直连。
- proxy：仅使用代理。
- direct：仅直连。

代理示例：

~~~text
socks5h://127.0.0.1:20170
~~~

SnowLuma 镜像默认先使用：

~~~text
dockerproxy.net/motricseven7/snowluma:latest
~~~

失败后复用已完成 blob，依次尝试 docker.1ms.run 和 Docker Hub。全部失败时保留 blob 缓存供下次安装续用，成功解包后清理。 `SNOWLUMA_IMAGE_PROXY` 可单独设置镜像下载代理；留空时大层下载会尝试复用 GitHub 代理，失败后直连。基础配置中可把镜像加速前缀改成 m.daocloud.io/docker.io、其他可信镜像或留空。安装器不会修改 /etc/docker/daemon.json。

## 守护策略

- 主服务使用 Restart=on-abnormal。
- 正常退出和程序主动报错退出不会由 systemd 立即拉起。
- 信号杀死会由 systemd 恢复。
- WebUI 或 Hook 连续三次检查失败时，外部 watchdog 判定假死并重启相应服务。
- Hook 丢失优先只重启 SnowLuma，不轻易重启 QQ。
- QQ 掉线只尝试恢复一次，仍需登录时等待人工运行 qqlogin。
- QQ 的 Xvfb/D-Bus 运行时保护独立于 SnowLuma 状态，SnowLuma 停止时同样生效。

被踢下线 / 登录过期的处理：

- qqlogin 发现本地登录态为已登录、但 OneBot 实测不在线时，会判定为被踢，询问后自动重启 QQ 并清除过期登录态（login.enc 会先备份为 .expired.bak）。
- 扫码过程中长时间抓不到二维码会分级自愈：先重启 QQ 清除「登录已过期」弹窗；仍无二维码则清除登录态后再重启，强制回到扫码页。
- 也可直接执行 `qqlogin --fresh` 一步到位。

## 日志限制

- 应用自有日志（SnowLuma、AstrBot 文件日志）由 logrotate 按单文件 20M、保留 7 天轮转。
- QQ 客户端日志与崩溃转储每日定时清理，保留 7 天；临时目录残留保留 3 天。
- journald 总量上限在基础配置中设置（默认建议 500M，输入 - 保持系统默认）。
- `nbot help` 查看全部命令与日志查看方式。

## 存储与升级

程序载荷通过软链接原子切换，配置、缓存和登录态不放在版本目录。更新失败会尝试恢复旧链接。 更新成功后只保留当前和上一个 `image-*` release。

安装前应确认数据盘已经挂载：

~~~bash
findmnt --target /nbot
df -h /nbot
~~~

脚本不会格式化磁盘，也不会自行修改 /etc/fstab。
