# 部署踩坑总结

## 存储

1. 只移动程序目录不够，venv、插件、QQ 数据、缓存和镜像临时层也会占空间。
2. OCI 镜像约数百 MB，展开时需要数 GiB；必须在数据盘构建，不能挤系统闪存。
3. /etc/fstab 应使用 UUID，写入前核对文件系统与挂载点。

## SnowLuma 与 QQ

1. SnowLuma Linux Release 完整包不等于 Docker 整合镜像。官方 Docker 镜像才包含 Linux QQ、Node 和完整运行环境。
2. 不喜欢 Docker 运行时也可以拆 OCI 镜像，但必须复刻同用户、DISPLAY、D-Bus、XDG_RUNTIME_DIR、Hook socket 和 ptrace capability。
3. QQ 与 SnowLuma 用户或权限不一致时，注入可能既不成功也不明确报错。
4. SnowLuma 应在 QQ 进程启动后立即进入被动观察，不应等账号登录后才启动；登录完成后 Hook 自动切换工作模式。
5. 程序载荷与配置必须分离，更新镜像不能覆盖 QQ 登录态和 OneBot 配置。

## 系统依赖

1. Debian 13 / Ubuntu 24.04 因 time_t 过渡把 libasound2、libgtk-3-0、libatspi2.0-0 等改名为 t64 后缀；旧名成为虚拟包且可能有多个提供者，apt 会直接报 no installation candidate，必须显式回退到 t64 包名。

## 下载

1. 国内直连 GitHub 和 Docker Hub 都可能长时间无进展。
2. GitHub auto 模式按“代理 -> 直连”回退。
3. OCI 镜像按“用户配置的镜像加速 -> Docker Hub”回退，不修改全局 Docker 配置。
4. 公共加速服务可能限流或过期，所以地址必须可配置，不能散落硬编码。
5. 清华 TUNA 当前没有 Linux QQ 镜像，不应加入无效下载探测。

## systemd 与健康检查

1. Restart=on-failure 会把程序主动报错退出也拉起，不符合当前要求；主服务使用 Restart=on-abnormal。
2. 进程仍在但 WebUI 或 Hook 连续失败才按假死处理，单次波动不能触发重启。
3. Hook IPC 丢失优先重启 SnowLuma，避免不必要地重启 QQ。
4. QQ 掉线无限重启会增加账号风控，只自动恢复一次。

## 登录二维码

1. 直接把截图压成字符会破坏二维码模块与静区。
2. 正确流程是先解码截图 payload，再用 qrencode 重新生成标准终端二维码。
3. 二维码会过期，需要周期性刷新；窗口太小时应提示扩展终端，而不是继续压缩变形。
4. 账号被踢下线后，login.enc 里 isUserLogin 可能仍为 true；判断真实在线状态必须以 OneBot get_status 为准，不能只看本地登录态文件。
5. 被踢后 QQ 客户端会停留在「登录已过期」弹窗或过期的快捷登录页，画面里没有二维码，截屏解码会一直失败。恢复顺序：先重启 QQ 进程清除弹窗；仍无二维码则备份并清除 login.enc 再重启，强制回到纯扫码页。
6. Xvfb 的 PID 和 X cookie 在每次 QQ 重启后都会变化，只有 DISPLAY 号和 Xauthority 路径稳定；扫码工具必须每轮重新解析，不能在启动时缓存。
7. 快捷登录按钮的点击必须按窗口比例换算，不能写死坐标；窗口尺寸随 QQ 版本变化，精确匹配 320x460 会失配。慢速机器上 QQ 冷启动可达 20 秒以上，等待预算要 90 秒级别。

## AstrBot

1. --no-sync 是 uv 参数，普通 venv 启动不能使用。
2. 新版 AstrBot 需要 Python 3.12 或更高。
3. 更新时创建新 venv，安装成功并通过启动检查后再切换。
4. nbot astrbot logs 默认应输出完整 journal，-n 和 -f 作为可选模式。
