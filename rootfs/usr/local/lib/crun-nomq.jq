(.mounts |= ([ .[] | select(.destination != "/dev/pts" and .destination != "/dev/mqueue") | if .destination == "/dev" then {destination:"/dev",type:"bind",source:"/dev",options:["bind","rprivate"]} else . end ]))
| del(.linux.resources.devices)
| del(.linux.resources.pids)
| . as $c
| (.process.user //= {})
| (.process.user.uid) = 0
| (.process.user.gid) = 0
| (.process.user.additionalGids) = (((($c.process.user.additionalGids // []) + [($c.process.user.gid // 0), 0, 3003, 3004]) | map(select(. != null))) | unique)
