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
- IPv6 / dual-stack networks (`podman network create --ipv6`): v6 inbound/outbound, AAAA DNS, per-family policy routing
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
- podman **5.3.2** or **5.7.0** + netavark + aardvark-dns (see [Compatibility](#compatibility))
- Kernel with `NET_NS` + `TUN`; device can load tun

## Install

Copy this repo onto the device however you like (ssh / adb / ...), then **run on the device**:

```sh
./configure           # probe the kernel empirically, write config.env
./install.sh          # installs per config.env; builds pasta/crun-doa on first run
                      # (build scripts install their own deps); backs up podman/conmon/netavark
                      # as *.real and pre-existing configs as *.doa-bak
```

`configure` tunes the install per device: `crun-nomq` (no IPC_NS), the podman wrapper (no USER_NS), `utsns = "host"` (no UTS_NS), a cgroup-v1 mount service (controllers not mounted at boot) and the storage driver (kernel overlayfs, fuse-overlayfs, or vfs) are each enabled only when needed. Re-running `configure` + `install.sh` reconciles the system — the podman wrapper is restored from `*.real` when no longer needed. (A netavark native-bridge route was evaluated and dropped: Android kernels commonly ship read-only filter tables or trimmed xt matches, which no userspace workaround can fix.)

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

## Compatibility

Validated combinations:

| podman | netavark | status |
|---|---|---|
| 5.3.2 | 1.13.1 | validated |
| 5.7.0 | 1.16.1 | validated (bridge networking, port publishing, `network reload`, teardown) |

The shim reports itself to podman as netavark `1.13.1-pasta` and writes aardvark-dns record files in the 1.x format; both podman versions above accept that interface. Other versions may work but must pass the regression check below before production use.

Kernel: developed and validated on 4.4 (Xiaomi whyred). 3.10 kernels (e.g. Xiaomi kenzo) are **not supported** — see the netns-wedge entry under [Known limitations](#known-limitations).

## Upgrading podman

Package upgrades (apk / apt / ...) replace the package-owned files `/usr/bin/podman`, `/usr/bin/conmon` and `<libexec>/netavark`, **silently discarding the wrappers** — bridge-network containers then get no networking (setup fails or pasta never launches), while host-network containers keep running and hide the breakage. Files under `/usr/local` (pasta, crun-nomq) and `/etc/containers` are not package-owned and survive.

After an upgrade, `*.real` still hold the **old** binaries. Refresh the backups first — otherwise `install.sh` would wrap the stale `.real` and downgrade you:

```sh
cp /usr/bin/podman /usr/bin/podman.real
cp /usr/bin/conmon /usr/bin/conmon.real
cp /usr/libexec/podman/netavark /usr/libexec/podman/netavark.real   # or /usr/lib/podman
./install.sh
```

Then run the full regression suite on the device:

```sh
./test.sh   # bridge TCP/UDP, outbound, IPv6, multi-net, internal, DNS,
            # EXPOSE, pods, restart/stop/start, crash recovery, teardown
```

Note on podman **>= 5.5**: pod infra containers switched to rootfs-overlay, which needs overlayfs — pods fail to start on this kernel. `install.sh` works around it by pinning `infra_image` in containers.conf to the local `podman-pause` image (image path = vfs). Without any `localhost/podman-pause` image it warns; pull or build one to keep pods working.

## Uninstall

```sh
./uninstall.sh        # run on the device: stops all pasta/containers, restores official podman/conmon/netavark from *.real
```

## Known limitations

- **IPv6 semantics on v4-only networks**: to keep published ports reachable over both stacks, containers on such networks hold the host's v6 addresses (pasta shared-address mode) and may get a v6 default route — do not rely on "container has no v6 egress" as isolation (`internal` networks strip the other family's addresses and routes entirely and are unaffected).
- **Not true L2 isolation**: inter-container isolation is implemented at the IP layer + routing, not equivalent to veth-bridge layer-2 isolation; host firewall is also unavailable (no netfilter in kernel).
- **"No outbound" on internal networks is enforced by flushing the container's route table** — a determined privileged container can add a default route back.
- **EXPOSE connectivity relies on an asynchronous inspect** (querying the container's own config right after start); under extreme timing the first rule may arrive seconds late.
- **Startup network race on containers with published ports**: podman holds the port reservations until the container starts, so pasta can only bind in the background — an entrypoint that hits the network instantly may catch a sub-second window. Containers without published ports are gated on netns readiness by the conmon wrapper and are not affected.
- **Version-bound**: the wrappers depend on podman's netavark plugin protocol and conmon argument format; only the versions listed under [Compatibility](#compatibility) are validated. A podman package upgrade also overwrites the wrappers — see [Upgrading podman](#upgrading-podman).
- **fuse-overlayfs mount loss makes container removal stickily fail (auto-recovered)**: if a container starts while its `merged` dir is not actually mounted (stale "mounted" storage metadata after a crash or unclean reboot — upstream [podman#23504](https://github.com/containers/podman/issues/23504), unfixed), podman writes its per-container config (`etc/hosts`, `resolv.conf`, `hostname`, `run/.containerenv`, plus empty skeleton dirs) into the *plain* dir, and every later `rm` / `compose down` dies at `replacing mount point ".../merged": directory not empty` — retrying is futile and the storage container leaks into `podman ps --storage`. The podman wrapper's `rm`/`stop` auto-cleans when the dir holds *only* those known podman-generated files (podman-compose is covered too — it shells out to the podman CLI); any other file means real container data written while the overlay was lost, which is preserved and reported with manual recovery steps. When this fires, capture `ps aux | grep fuse-overlayfs`, the merged dir listing and `/proc/mounts` first — the open question is what killed the FUSE daemon (suspect: Android LMK under load).
- **doa-tsd death breaks all container starts**: the thread-self FUSE shim is a single python process; if it dies, every container start fails with `failed to bind mount ns at /run/netns/...: transport endpoint is not connected`. Recover with `rc-service doa-tsd restart`.
- **3.10 kernels (e.g. Xiaomi kenzo) are not supported**: under repeated network-namespace churn the kernel leaks references onto the dying netns's `lo`, and `cleanup_net` then spins forever in `unregister_netdevice: waiting for lo to become free. Usage count = 5` holding `rtnl_mutex` — every later `podman run/start` and even `ip addr` blocks in D-state, and only a reboot recovers. Reproduced 3/3 full test-suite runs (~80-100 min in, always right after a container teardown) on kenzo's 3.10.73; isolated repro loops (bare netns, tap+DAD, pasta+v6) never trigger it. The ref leak was introduced by userspace-visible traffic/addrconf during the netns lifetime and the fixes landed upstream in 3.10.107/108 — kenzo's kernel is stuck below that. Long-lived containers barely exercise netns destruction, but any churn-heavy use (CI, the test suite) is fatal. Userspace mitigations (disabling DAD, flushing lo before teardown) were tried and did not help.

## Layout

```
rootfs/
  usr/bin/podman              # wrapper: userns warning filter, env injection,
                              #  rm/stop EBUSY retry + ENOTEMPTY auto-recovery
  usr/bin/conmon              # wrapper: release LISTEN fds + trigger launch script
  usr/libexec/podman/netavark # core shim: bridge lifecycle / aardvark / policy routing
                              # (installed to /usr/lib/podman on Debian-likes)
  usr/local/bin/crun-nomq     # crun wrapper: strips unsupported cgroup mounts,
                              #  injects aid_inet/aid_net_raw (pid1 gids + an
                              #  /etc/group bind so setuid daemons keep them),
                              #  apt sandbox bind, freezer-misread state fix
                              # (pasta binary produced by build-pasta.sh, not tracked)
  usr/bin/crun-doa            # (produced by build-crun.sh, not tracked: patched crun
                              #  for kernels w/o MEMCG or with broken cpuset)
  etc/init.d/doa-cgroups      # openrc service: mount cgroup v1 controllers (if needed)
  etc/init.d/doa-healthcheckd # openrc service: healthcheck scheduler (podman relies
                              #  on systemd timers for healthchecks; none on Android)
  usr/local/bin/doa-healthcheckd # the scheduler loop itself
  etc/containers/             # containers.conf / registries.conf etc.
install.sh  build-pasta.sh  build-crun.sh  uninstall.sh  test.sh
patches/passt/android-compat.patch
patches/crun/android-cgroup.patch
```

## Development notes

- Every podman invocation on the device takes a global sqlite lock; **never call podman recursively inside the shim** (inspect in the setup path deadlocks) — container config can only be read asynchronously by the conmon wrapper after the container starts.
- Image storage driver is kernel `overlay` when available, else `overlay` via `fuse-overlayfs`, else `vfs`; database backend is `sqlite` (boltdb's mmap misbehaves on this kernel). With `vfs` every layer and every build step is a full-tree copy — unbearable beyond toy images. Switching drivers requires wiping `/var/lib/containers/storage` (install.sh warns).
- Build performance: containers/storage probes the kernel once per process for native diff support and falls back to *naive diff* on failure — on Android the probe fails (with kernel overlayfs, and always when a `mount_program` like fuse-overlayfs is set), so each build-step commit walks both the parent and the current tree instead of just reading the overlay upperdir. DoA binary-patches podman (`patches/podman/naive-diff.py`, install-time) to no-op the probe, so native diff is always used; fuse-overlayfs whiteouts are kernel-compatible and a 3×30 MB build drops from ~25 s to ~14 s. `podman build --squash` remains available to skip intermediate image-layer commits entirely.
- Repro of the sticky ENOTEMPTY corruption (see Known limitations): `mid=$(podman inspect <c> | jq -r '.[0].GraphDriver.Data.MergedDir'); umount -l "$mid"; podman restart <c>` — libpod populates the plain merged dir, and `podman rm -f <c>` then exercises the wrapper's auto-recovery (plant any extra file in `$mid` first to verify it refuses).
- busybox environment: no `grep -P`, no `PIPESTATUS`; scripts stay POSIX.

## License

[MIT](LICENSE)
