#!/bin/sh
# test.sh: DockerOnAndroid regression suite. Run on the device after
# install.sh, and after every podman package upgrade:
#   ./test.sh
# Covers the full claim list of README: TCP/UDP publishing, outbound,
# IPv6/dual-stack, multi-network policy routing, internal networks,
# per-network DNS, EXPOSE interconnect, pods, restart/stop/start,
# pasta crash auto-restart, teardown cleanup. Exits non-zero on failure.
# busybox-safe (ash/dash), requires: wget ping nc on the host, jq.
set -u
cd "$(dirname "$0")"

P=doat                 # name prefix for everything we create
IMG_WEB=nginx:alpine
IMG_ALP=alpine:latest
STATE=/tmp/pasta/nv

# published ports; shift the whole set with DOAT_PORT_BASE when a port is
# stuck (e.g. orphaned LISTEN socket after a killed run)
PB=${DOAT_PORT_BASE:-18080}
P_WEB=$((PB+1))    # 18081
P_POD=$((PB+2))    # 18082
P_CMP=$((PB+3))    # 18083
P_SP=$((PB+7))     # 18087
P_SAME=$((PB+808)) # 18888
P_UDP=${DOAT_PORT_UDP:-15353}

# window multiplier for slow/loaded devices (kenzo needs ~4)
SCALE=${DOAT_TW_SCALE:-1}

pass=0 fail=0
ok()  { pass=$((pass+1)); echo "ok   - $1"; }
bad() { fail=$((fail+1)); echo "FAIL - $1"; }
t()    { if sh -c "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
tnot() { if sh -c "$2" >/dev/null 2>&1; then bad "$1"; else ok "$1"; fi; }

waitfor() { # waitfor <secs> <sh-cmd>
  w_i=0
  while [ "$w_i" -lt $(($1*2)) ]; do
    if sh -c "$2" >/dev/null 2>&1; then return 0; fi
    sleep 0.5; w_i=$((w_i+1))
  done
  return 1
}
tw() { if waitfor $(( $3 * SCALE )) "$2"; then ok "$1"; else bad "$1"; fi; } # tw <name> <cmd> <secs>
cleanup() {
  for c in $(podman ps -aq --filter "name=$P" 2>/dev/null); do podman rm -f "$c" >/dev/null 2>&1; done
  podman pod rm -f "$P-pod" >/dev/null 2>&1
  for n in $(podman network ls -q --filter "name=$P" 2>/dev/null); do podman network rm "$n" >/dev/null 2>&1; done
  rm -rf /tmp/$P-compose
}
trap cleanup EXIT INT TERM

cip()  { podman inspect "$1" | jq -r '.[0].NetworkSettings.Networks[].IPAddress // empty' | head -1; }
cipn() { podman inspect "$1" | jq -r ".[0].NetworkSettings.Networks[\"$2\"].IPAddress // empty"; }
cip6n() { podman inspect "$1" | jq -r ".[0].NetworkSettings.Networks[\"$2\"].GlobalIPv6Address // empty"; }
gw6n() { podman network inspect "$1" | jq -r '.[0].subnets[] | select(.subnet | contains(":")) | .gateway // empty'; }

ping6c() { echo "ping6 -c1 -W3 $1 2>/dev/null || ping -6 -c1 -W3 $1"; }

for img in "$IMG_WEB" "$IMG_ALP"; do
  podman image exists "$img" 2>/dev/null || podman pull -q "$img" >/dev/null
done
cleanup 2>/dev/null

echo "== bridge: TCP publishing / outbound =="
podman run -d --pull=never --name $P-web -p $P_WEB:80 "$IMG_WEB" >/dev/null || { echo "cannot start test container"; exit 1; }
tw "tcp: host -> published port" "wget -q -O /dev/null --timeout=5 http://127.0.0.1:$P_WEB/" 15
cip_web=$(cip $P-web)
t "tcp: host -> container IP" "wget -q -O /dev/null --timeout=5 http://$cip_web/"
podman run -d --pull=never --name $P-cli "$IMG_ALP" sleep 86400 >/dev/null
# --no-map-gw keeps the gateway address unroutable by design (aardvark-dns
# listens on the gw lo-alias; mapping gw to host loopback would steal its
# traffic): pasta answers no ICMP there, so verify host reachability via
# the host's real address instead of ping-gateway
host4=$(ip -4 route get 223.5.5.5 2>/dev/null | sed -n 's/.*src \([0-9.]*\).*/\1/p' | head -1)
tw "v4 outbound: host reachable" "podman exec $P-cli ping -c1 -W3 $host4" 5
t "v4 outbound: internet" "podman exec $P-cli ping -c1 -W3 223.5.5.5"
# the conmon readiness gate must hold container start until the netns is
# configured: an entrypoint that goes straight to the network must work.
# retry once: images with EXPOSE get a second pasta pass after start-commit
# (podman run hides the image link until then), a ~1s restart window can
# eat a first-pass ping
t "race: entrypoint online at start" "podman run --rm --pull=never $IMG_ALP ping -c1 -W3 223.5.5.5 || podman run --rm --pull=never $IMG_ALP ping -c1 -W3 223.5.5.5"

# hp==cp publishes: the wildcard rule must not be duplicated as a cip-direct
# rule - pasta dies on the forwarding conflict otherwise
podman run -d --pull=never --name $P-sp -p $P_SP:80 -p $P_SAME:$P_SAME "$IMG_WEB" >/dev/null
tw "same-port: pasta survives" "p=\$(cat $STATE/\$(podman inspect -f '{{.Id}}' $P-sp 2>/dev/null).pastapid.* 2>/dev/null); [ -n \"\$p\" ] && kill -0 \$p 2>/dev/null" 15
tw "same-port: published port works" "wget -q -O /dev/null --timeout=5 http://127.0.0.1:$P_SP/" 15
t "same-port: host listens on hp==cp port" "netstat -tln 2>/dev/null | grep -q ':$P_SAME '"

echo "== bridge: UDP publishing =="
podman run -d --pull=never --name $P-udp -p "$P_UDP:5353/udp" "$IMG_ALP" nc -u -l -p 5353 >/dev/null
# one-shot datagrams are lossy before nc is listening: resend on every retry
tw "udp: published port delivers datagram" "echo doat-probe | nc -u -w1 127.0.0.1 $P_UDP && sleep 0.3 && podman logs $P-udp 2>&1 | grep -q doat-probe" 10

echo "== IPv6 / dual-stack =="
podman network create --ipv6 $P-v6 >/dev/null
podman run -d --pull=never --name $P-web6 --network $P-v6 "$IMG_WEB" >/dev/null
cip6=$(cip6n $P-web6 $P-v6)
if [ -n "$cip6" ]; then ok "v6: container gets global address"; else bad "v6: container gets global address"; fi
gw6=$(gw6n $P-v6)
podman run -d --pull=never --name $P-cli6 --network $P-v6 "$IMG_ALP" sleep 86400 >/dev/null
sleep 1
t "v6: ping gateway" "podman exec $P-cli6 $(ping6c "$gw6")"
t "v6: host -> container" "wget -q -O /dev/null --timeout=5 http://[$cip6]/"
t "v6: outbound internet" "podman exec $P-cli6 $(ping6c 2400:3200::1)"

echo "== multi-network + policy routing =="
podman network create $P-n2 >/dev/null
podman run -d --pull=never --name $P-multi --network podman --network $P-n2 "$IMG_ALP" sleep 86400 >/dev/null
sleep 1
t "multi: two interfaces" "[ \$(podman exec $P-multi ip addr show scope global | grep -c 'inet ') -ge 2 ]"
# podman assigns interfaces alphabetically, so either network may be the
# primary; the secondary one must carry a source policy rule
t "multi: source policy rule" "podman exec $P-multi ip rule | grep -q 'from 10.'"

echo "== internal network =="
podman network create --internal $P-int >/dev/null
podman run -d --pull=never --name $P-int1 --network $P-int "$IMG_ALP" sleep 86400 >/dev/null
podman run -d --pull=never --name $P-int2 --network $P-int "$IMG_ALP" sleep 86400 >/dev/null
sleep 1
cip_int1=$(cipn $P-int1 $P-int)
t "internal: in-net connectivity" "podman exec $P-int2 ping -c1 -W2 $cip_int1"
tnot "internal: no outbound" "podman exec $P-int1 ping -c1 -W2 223.5.5.5"

echo "== per-network DNS (aardvark) =="
podman network create $P-dns >/dev/null
podman run -d --pull=never --name $P-a --network $P-dns "$IMG_WEB" >/dev/null
podman run -d --pull=never --name $P-b --network $P-dns "$IMG_ALP" sleep 86400 >/dev/null
tw "dns: short name resolves" "podman exec $P-b ping -c1 -W2 $P-a" 15
tw "dns: FQDN resolves" "podman exec $P-b ping -c1 -W2 $P-a.$P-dns" 10

echo "== EXPOSE interconnect =="
podman run -d --pull=never --name $P-exp --expose 80 "$IMG_WEB" >/dev/null
cip_exp=$(cip $P-exp)
# first rule arrives via the conmon wrapper's async inspect; allow slack
tw "expose: peer reaches exposed port" "podman exec $P-cli wget -q -O /dev/null --timeout=5 http://$cip_exp/" 25

echo "== pod =="
podman pod create --name $P-pod -p $P_POD:80 >/dev/null
podman run -d --pull=never --pod $P-pod --name $P-podweb "$IMG_WEB" >/dev/null
tw "pod: published port works" "wget -q -O /dev/null --timeout=5 http://127.0.0.1:$P_POD/" 15

echo "== restart / stop / start =="
cid=$(podman inspect -f '{{.Id}}' $P-web)
pp0=$(cat $STATE/$cid.pastapid.* 2>/dev/null | head -1)
podman restart $P-web >/dev/null
tw "restart: published port survives" "wget -q -O /dev/null --timeout=5 http://127.0.0.1:$P_WEB/" 20
# pastapid lands ~1s after pasta binds the port: poll instead of reading once
tw "restart: pasta relaunched on new netns" "p=\$(cat $STATE/$cid.pastapid.* 2>/dev/null); [ -n \"\$p\" ] && [ \"\$p\" != \"$pp0\" ] && kill -0 \$p 2>/dev/null" 20
podman stop $P-web >/dev/null
podman start $P-web >/dev/null
tw "stop/start: published port back" "wget -q -O /dev/null --timeout=5 http://127.0.0.1:$P_WEB/" 20

echo "== pasta crash auto-restart =="
pp2=$(cat $STATE/$cid.pastapid.* 2>/dev/null | head -1)
kill "$pp2" 2>/dev/null
tw "crash: supervisor relaunches pasta" "p=\$(cat $STATE/$cid.pastapid.* 2>/dev/null); [ -n \"\$p\" ] && [ \"\$p\" != \"$pp2\" ] && kill -0 \$p 2>/dev/null" 20
tw "crash: port works after relaunch" "wget -q -O /dev/null --timeout=5 http://127.0.0.1:$P_WEB/" 10

echo "== teardown cleanup =="
podman rm -f $P-web >/dev/null
sleep 2
tnot "teardown: state files removed" "ls $STATE/$cid.* 2>/dev/null"
tnot "teardown: lo alias removed" "ip addr show lo | grep -q '$cip_web/32'"

if command -v podman-compose >/dev/null 2>&1; then
  echo "== podman-compose =="
  mkdir -p /tmp/$P-compose
  cat > /tmp/$P-compose/docker-compose.yml <<EOF
services:
  web:
    image: $IMG_WEB
    ports:
      - "$P_CMP:80"
EOF
  (cd /tmp/$P-compose && podman-compose -p $P up -d >/dev/null 2>&1)
  tw "compose: published port works" "wget -q -O /dev/null --timeout=5 http://127.0.0.1:$P_CMP/" 20
  # attached re-up against already-running containers: stock podman-compose
  # issues start -a unconditionally and crun fails with "cannot open
  # exec.fifo"; the DoA compose provider rewrites it to attach (which blocks
  # streaming, hence the timeout)
  if command -v timeout >/dev/null 2>&1; then
    # no command substitution: a surviving `podman attach` would hold the
    # pipe open and hang the test even after timeout kills its child; -k
    # because a job-control-stopped child never processes the pending TERM
    (cd /tmp/$P-compose && timeout -k 5 30 podman compose -p $P up > up.out 2>&1); rc=$?
    pkill -f "podman attach ${P}_web_1" 2>/dev/null || true
    if grep -q exec.fifo /tmp/$P-compose/up.out; then
      bad "compose: attached re-up on running containers"
    elif [ "$rc" = 124 ] || [ "$rc" = 137 ]; then
      ok "compose: attached re-up on running containers"
    else
      bad "compose: attached re-up on running containers (rc=$rc)"
    fi
  fi
  (cd /tmp/$P-compose && podman-compose -p $P down >/dev/null 2>&1)
fi

echo
echo "passed: $pass  failed: $fail"
[ "$fail" -eq 0 ]
