# DockerOnAndroid

[English](README.md) | **中文**

在 Android 上获得**完整的 Docker/Podman 原生 bridge 网络语义** —— 即使内核没有 VETH、没有 netfilter。

## 背景

典型 Android 内核（如本项目目标设备 Xiaomi whyred 的 4.4.302）只编入了 `NET_NS` 和 `TUN`，缺少容器网络栈依赖的几乎所有组件：

```
✗ USER_NS  PID_NS  IPC_NS  OVERLAY_FS
✗ VETH  MACVLAN  IPVLAN  NETFILTER/NF_TABLES
✓ NET_NS  TUN
```

这意味着 podman 官方的 netavark bridge 驱动、slirp4netns、以及真正的 veth 对全部不可用。本方案用**打过补丁的 [passt/pasta](https://passt.top/)**（纯用户态 TCP/UDP 转发，只依赖 TUN）作为数据面，通过三个极小的 wrapper 把 pasta 无缝接入 podman 的网络生命周期，最终实现：

- `docker run -p` / `-P` / UDP 发布，语义与上游完全一致
- `docker ps` / `inspect` 原生显示 PORTS / IP / MAC
- 多网络容器（`-I` 多接口）+ 源地址策略路由
- `internal` 网络（无外网，网内互联）
- 按网络的容器 DNS（aardvark，短名 + FQDN）
- 重启 / stop / rm / `network rm` 全生命周期
- pod / podman-compose / EXPOSE 容器间互联
- pasta 崩溃自动拉起、日志轮转、`/dev/net/tun` 权限自愈

**不是黑客式 label 注入**：IP/端口绑定全部落在 podman 数据库里，任何工具（podman-compose、docker CLI 别名、API）看到的就是真相。

## 架构

```
docker ──alias──▶ podman (wrapper, 仅过滤告警/注入环境)
                      │  正常走 DB / image / netns 逻辑
                      ▼
              netavark (wrapper = 本方案 shim)
                      │  bridge 驱动: 为容器分配 IP/MAC,
                      │  生成 pasta 参数 + 每容器启动脚本,
                      │  在主机 lo 上加容器 IP 别名,
                      │  写 aardvark DNS 记录
                      │  其余驱动直通 netavark.real
                      ▼
              conmon (wrapper)
                      │  exec 前关闭 podman 预留的 LISTEN fd
                      │  (释放被占用的发布端口, 供 pasta 绑定)
                      │  触发容器启动脚本
                      ▼
              pasta (每容器每网络一个, TUN)
                      │  主机侧 bind 发布端口 + lo 别名转发
                      ▼
              crun-nomq ──▶ 容器 (new netns, lo 上有自己的 IP)
```

### 为什么需要 conmon wrapper

podman 创建容器时会**主动 bind + LISTEN 每一个发布端口并持有 fd 贯穿容器生命周期**（防止端口被抢）。pasta 随后想 bind 同一端口必然 `EADDRINUSE`。conmon wrapper 在 `exec` 真正的 conmon 之前，通过 `/proc/net/{tcp,tcp6,udp,udp6}` 找出所有 LISTEN 状态的继承 fd 并关闭——此时 podman 已经退出事务，端口安全释放，pasta 得以接管。

### pasta 的约束与对策

| pasta 行为 | 对策 |
|---|---|
| 先于容器进程启动，`-T/-U` 会在 ns 内开 splice 监听抢占容器端口 | 发布语义统一改为主机侧 `-t/-u`，加 `-T none -U none` |
| `--netns` 拒绝 `/proc/*/ns/net` 魔链 | 用 bind-mount 后的普通文件 |
| 无 `-I` 时单接口，多网络容器回程走错接口 | 每网络一个 pasta + `-I <ifn>`，容器内 `ip rule from <cip>` 策略路由 |
| `isolate_initial` 丢弃 CAP_NET_RAW，ICMP echo 需 ping socket | 补丁保留 CAP_NET_RAW（见 `patches/`） |
| Android 的 socket 需要 `aid_inet` egid | `--runas 0:3003` |
| `/dev/net/tun` 每次开机权限被重置 | shim setup 时自愈 `chgrp 3003 + chmod 660` |

## 要求

- 已 root 的 Android 设备（开发验证: Magisk 30.7, SELinux Permissive）
- 一个 Linux 用户空间 — 发行版不限（开发验证: [LinuxOnAndroid](https://github.com/HsOjo/LinuxOnAndroid) musl/Alpine guest）；`build-pasta.sh` 通过 apk / apt / dnf / pacman 自动安装构建依赖，podman libexec 目录（`/usr/libexec/podman` 或 `/usr/lib/podman`）在安装时自动探测
- podman **5.3.2** + netavark **1.13.1** + aardvark-dns（版本绑定，见下文）
- 内核含 `NET_NS` + `TUN`；设备能加载 tun

## 安装

用任意方式（ssh / adb / ...）把本仓库拷到设备上，然后**在设备上执行**：

```sh
./configure           # 实测内核能力, 生成 config.env (FORCE_PASTA=1 可强制 shim 路线)
./build-pasta.sh      # 仅当 configure 选了 pasta 路线且尚无二进制时执行
./install.sh          # 按 config.env 安装; podman/conmon/netavark 备份为 *.real, 已有配置备份为 *.doa-bak
```

`configure` 按设备决策：具备 veth + bridge + 可用防火墙（iptables 或 nftables）的内核走 netavark **原生 bridge**，完全不装 shim；较弱的内核走 **pasta shim 栈**；`crun-nomq`（无 IPC_NS）、podman wrapper（无 USER_NS）、存储驱动（overlayfs 或 vfs）均按需启用。重跑 `configure` + `install.sh` 会自动对账——不再需要的 wrapper 会从 `*.real` 恢复。

设备端验证：

```sh
podman run -d --name web -p 8080:80 nginx:alpine
curl localhost:8080
podman ps             # PORTS 原生显示
podman rm -f web
```

## 从源码重建 pasta

在设备上执行；设备如需代理可通过 `PROXY` 指定：

```sh
PROXY=http://<proxy>:<port> ./build-pasta.sh   # clone passt (固定 tag) -> 应用 patches/ -> make -> rootfs/
```

## 卸载

```sh
./uninstall.sh        # 在设备上执行: 停掉所有 pasta/容器, 用 *.real 恢复官方 podman/conmon/netavark
```

## 已知限制

- **IPv4 only**：shim 暂未生成 IPv6 转发规则。
- **非真 L2 隔离**：容器间隔离靠 IP 层 + 路由实现，不等价于 veth bridge 的二层隔离；主机防火墙亦不可用（内核无 netfilter）。
- **internal 网络的 "无外网" 通过清刷容器路由表实现**，执意提权的容器可重新加回默认路由。
- **EXPOSE 互联依赖异步 inspect**（容器启动后瞬时查询自身配置），极端时序下首条规则可能晚到数秒。
- **版本绑定**：wrapper 依赖 podman 5.3.x 的 netavark 插件协议与 conmon 参数格式，升级 podman 需回归验证。

## 目录结构

```
rootfs/
  usr/bin/podman              # wrapper: 过滤 userns 告警 + 环境注入
  usr/bin/conmon              # wrapper: 释放 LISTEN fd + 触发容器启动脚本
  usr/libexec/podman/netavark # 核心 shim: bridge 生命周期 / aardvark / 策略路由
                              # (Debian 系安装到 /usr/lib/podman)
  usr/local/bin/crun-nomq     # crun wrapper: 剥离容器不支持的 cgroup 挂载
                              # (pasta 二进制由 build-pasta.sh 产出, 不入库)
  etc/containers/             # containers.conf / registries.conf 等
install.sh  build-pasta.sh  uninstall.sh
patches/passt/android-compat.patch
```

## 开发备忘

- 设备上 podman 每次调用会拿 sqlite 全局锁；**shim 内禁止递归调用 podman**（setup 路径中 inspect 会死锁）——容器配置只能由 conmon wrapper 在容器启动后异步读取。
- 容器镜像存储驱动为 `vfs`（无 overlayfs），数据库后端 `sqlite`（boltdb 在该内核上 mmap 行为异常）。
- busybox 环境：无 `grep -P`、无 `PIPESTATUS`，脚本保持 POSIX。

## License

[MIT](LICENSE)
