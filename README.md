# DockerOnAndroid

**English** | [中文](README.zh-CN.md)

Full **native Docker/Podman bridge networking semantics on Android** — even with a kernel that has no VETH and no netfilter.

## Background

A typical Android kernel (e.g. the 4.4.302 on the target device, a Xiaomi whyred) ships with only `NET_NS` and `TUN`, lacking almost everything the container network stack depends on:

```
✗ USER_NS  PID_NS  IPC_NS  OVERLAY_FS
✗ VETH  MACVLAN  IPVLAN  NETFILTER/NF_TABLES
✓ NET_NS  TUN
```

This means podman's official netavark bridge driver, slirp4netns, and real veth pairs are all unusable. This project uses a **patched [passt/pasta](https://passt.top/)** (pure userspace TCP/UDP forwarding, requiring only TUN) as the data plane, and plugs pasta seamlessly into podman's network lifecycle via three tiny wrappers. The result:

- `docker run -p` / `-P` / UDP publishing, semantics identical to upstream
- `docker ps` / `inspect` natively show PORTS / IP / MAC
- Multi-network containers (`-I` multi-interface) + source-based policy routing
- `internal` networks (no outbound, in-network connectivity)
- Per-network container DNS (aardvark, short name + FQDN)
- Full lifecycle: restart / stop / rm / `network rm`
- Pods / podman-compose / EXPOSE inter-container connectivity
- pasta crash auto-restart, log rotation, `/dev/net/tun` permission self-healing

**Not a label-injection hack**: IPs and port bindings live in podman's own database, so any tool (podman-compose, docker CLI alias, API) sees the ground truth.

## Architecture

```
docker ──alias──▶ podman (wrapper: warning filter / env injection only)
                      │  normal DB / image / netns logic
                      ▼
              netavark (wrapper = this project's shim)
                      │  bridge driver: allocates IP/MAC,
                      │  generates pasta args + per-container
                      │  launch script, adds container IP
                      │  aliases on host lo, writes aardvark
                      │  DNS records; other drivers pass
                      │  through to netavark.real
                      ▼
              conmon (wrapper)
                      │  closes podman's reserved LISTEN fds
                      │  before exec (frees published ports
                      │  so pasta can bind them), triggers
                      │  the container launch script
                      ▼
              pasta (one per container per network, TUN)
                      │  host-side bind of published ports
                      │  + lo alias forwarding
                      ▼
              crun-nomq ──▶ container (new netns, its IP on lo)
```

### Why the conmon wrapper is needed

When creating a container, podman **actively binds + LISTENs on every published port and holds the fd for the container's entire lifetime** (to prevent port theft). When pasta later tries to bind the same port it inevitably gets `EADDRINUSE`. The conmon wrapper, before exec'ing the real conmon, scans `/proc/net/{tcp,tcp6,udp,udp6}` for all inherited fds in LISTEN state and closes them — by then podman has already committed its transaction, the ports are safely released, and pasta takes over.

### pasta constraints and countermeasures

| pasta behavior | countermeasure |
|---|---|
| starts before the container process; `-T/-U` opens in-ns splice listeners that steal container ports | publishing is unified to host-side `-t/-u`, plus `-T none -U none` |
| `--netns` rejects `/proc/*/ns/net` magic symlinks | use a bind-mounted regular file instead |
| single interface without `-I`; multi-network containers get asymmetric return paths | one pasta per network + `-I <ifn>`, with `ip rule from <cip>` policy routing inside the container |
| `isolate_initial` drops CAP_NET_RAW; ICMP echo needs ping sockets | patch keeps CAP_NET_RAW (see `patches/`) |
| Android sockets require the `aid_inet` egid | `--runas 0:3003` |
| `/dev/net/tun` permissions are reset at every boot | shim self-heals with `chgrp 3003 + chmod 660` during setup |

## Requirements

- A rooted Android device (validated on: Magisk 30.7, SELinux Permissive)
- A Linux userland — any distro (validated on: [LinuxOnAndroid](https://github.com/HsOjo/LinuxOnAndroid) musl/Alpine guest); `build-pasta.sh` installs build deps via apk / apt / dnf / pacman, and the podman libexec dir (`/usr/libexec/podman` vs `/usr/lib/podman`) is auto-detected at install time
- podman **5.3.2** + netavark **1.13.1** + aardvark-dns (version-pinned, see below)
- Kernel with `NET_NS` + `TUN`; device can load tun

## Install

Copy this repo onto the device however you like (ssh / adb / ...), then **run on the device**:

```sh
./configure           # probe the kernel empirically, write config.env (FORCE_PASTA=1 to force the shim route)
./build-pasta.sh      # only if configure picked the pasta route and no binary is present yet
./install.sh          # installs per config.env; backs up podman/conmon/netavark as *.real and pre-existing configs as *.doa-bak
```

`configure` decides per device: kernels with veth + bridge + a working firewall (iptables or nftables) get netavark's **native bridge** with no shim at all; weaker kernels get the **pasta shim stack**; `crun-nomq` (no IPC_NS), the podman wrapper (no USER_NS) and the storage driver (overlayfs vs vfs) are each enabled only when needed. Re-running `configure` + `install.sh` reconciles the system — wrappers no longer needed are restored from `*.real`.

Verify on the device:

```sh
podman run -d --name web -p 8080:80 nginx:alpine
curl localhost:8080
podman ps             # PORTS shown natively
podman rm -f web
```

## Rebuilding pasta from source

Runs on the device; set `PROXY` if it needs one to reach the internet:

```sh
PROXY=http://<proxy>:<port> ./build-pasta.sh   # clone passt (pinned tag) -> apply patches/ -> make -> rootfs/
```

## Uninstall

```sh
./uninstall.sh        # run on the device: stops all pasta/containers, restores official podman/conmon/netavark from *.real
```

## Known limitations

- **IPv4 only**: the shim does not generate IPv6 forwarding rules yet.
- **Not true L2 isolation**: inter-container isolation is implemented at the IP layer + routing, not equivalent to veth-bridge layer-2 isolation; host firewall is also unavailable (no netfilter in kernel).
- **"No outbound" on internal networks is enforced by flushing the container's route table** — a determined privileged container can add a default route back.
- **EXPOSE connectivity relies on an asynchronous inspect** (querying the container's own config right after start); under extreme timing the first rule may arrive seconds late.
- **Version-pinned**: the wrappers depend on podman 5.3.x's netavark plugin protocol and conmon argument format; upgrading podman requires regression testing.

## Layout

```
rootfs/
  usr/bin/podman              # wrapper: userns warning filter + env injection
  usr/bin/conmon              # wrapper: release LISTEN fds + trigger launch script
  usr/libexec/podman/netavark # core shim: bridge lifecycle / aardvark / policy routing
                              # (installed to /usr/lib/podman on Debian-likes)
  usr/local/bin/crun-nomq     # crun wrapper: strips unsupported cgroup mounts
                              # (pasta binary produced by build-pasta.sh, not tracked)
  etc/containers/             # containers.conf / registries.conf etc.
install.sh  build-pasta.sh  uninstall.sh
patches/passt/android-compat.patch
```

## Development notes

- Every podman invocation on the device takes a global sqlite lock; **never call podman recursively inside the shim** (inspect in the setup path deadlocks) — container config can only be read asynchronously by the conmon wrapper after the container starts.
- Image storage driver is `vfs` (no overlayfs); database backend is `sqlite` (boltdb's mmap misbehaves on this kernel).
- busybox environment: no `grep -P`, no `PIPESTATUS`; scripts stay POSIX.

## License

[MIT](LICENSE)
