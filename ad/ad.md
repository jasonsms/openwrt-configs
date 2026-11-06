# xray-mini

单文件、零依赖的 Xray VLESS + Reality 脚本，面向 Alpine/OpenRC 与 64MB 小内存 VPS。

## 特点

- UUID 和 x25519 密钥由 `xray` 自身生成，不依赖 jq / openssl / python
- 下载、解压全部走 `/var/tmp`，避开 tmpfs 计入 cgroup 导致的安装期 OOM
- 只从官方 zip 流式取出 `xray` 本体，跳过 10MB+ 的 geoip/geosite
- 默认 `GOMEMLIMIT=24MiB`、`GOGC=20`、`GOMAXPROCS=1`
- OpenRC `supervise-daemon` 守护，异常自动拉起
- 输出 vless 分享链接和 mihomo / Clash 节点
- 安装后保留 `xray-mini` 管理命令

## 安装

```sh
curl -fsSL https://raw.githubusercontent.com/<OWNER>/xray-mini/main/xray-mini.sh -o /usr/local/bin/xray-mini
chmod +x /usr/local/bin/xray-mini
xray-mini install --port 8443 --ext-port 8443
```

- `--port`：容器/主机内监听端口
- `--ext-port`：NAT 面板映射出的外部端口（无 NAT 可省略）
- `--dest`：Reality 伪装目标，默认 `www.python.org`
- `--force`：重新生成配置和密钥

已经下载到本地时也可以直接执行：

```sh
sh xray-mini.sh install --port 8443 --ext-port 8443
```

安装脚本会把自身复制到 `/usr/local/bin/xray-mini`，后续可直接用管理命令。

## 管理

```sh
xray-mini info
xray-mini link
xray-mini status
xray-mini logs
xray-mini restart
xray-mini uninstall --yes
```

## 客户端注意

Xray 26.x 会协商 `X25519MLKEM768`。如果 mihomo / Clash Verge / OpenClash 报
`REALITY authentication failed`，在节点的 `reality-opts` 下加：

```yaml
support-x25519mlkem768: true
```

订阅转换后端可能丢掉该参数，必要时手动补上；同时把 mihomo 内核更新到 v1.19.33+。

## 实测

Alpine 3.24 / 64MB cgroup / 1 vCPU：

| 场景 | xray RSS | cgroup |
| --- | --- | --- |
| 空闲 | ~14 MB | ~31 MB |
| 4 路并发共 40MB 下载 | ~21 MB | ~34 MB |

安装阶段峰值更高，脚本已改为流式取二进制以降低峰值。
#!/bin/sh
mb() { awk -v n="$1" 'BEGIN{printf "%.1f", n/1048576}'; }

while true; do
    clear
    LIMIT=$(cat /sys/fs/cgroup/memory.max 2>/dev/null)
    CUR=$(cat /sys/fs/cgroup/memory.current 2>/dev/null)
    ANON=$(awk '/^anon /{print $2}' /sys/fs/cgroup/memory.stat)
    FILE=$(awk '/^file /{print $2}' /sys/fs/cgroup/memory.stat)
    INACT=$(awk '/^inactive_file /{print $2}' /sys/fs/cgroup/memory.stat)
    KERN=$(awk '/^kernel /{print $2}' /sys/fs/cgroup/memory.stat)
    SWAP=$(cat /sys/fs/cgroup/memory.swap.current 2>/dev/null)
    SWAPMAX=$(cat /sys/fs/cgroup/memory.swap.max 2>/dev/null)
    REAL=$((ANON + KERN))
    PID=$(pidof xray 2>/dev/null)

    if [ "$LIMIT" = "max" ]; then
        LIMIT_MB="unlimited"; PCT="n/a"
    else
        LIMIT_MB=$(mb "$LIMIT")
        PCT=$(awk -v u="$REAL" -v l="$LIMIT" 'BEGIN{if(l>0) printf "%.1f", u/l*100; else print "n/a"}')
    fi

    echo "===== $(date '+%F %T') ====="
    echo "限额        : ${LIMIT_MB} MB"
    echo "current     : $(mb "$CUR") MB  (含缓存，不代表真实占用)"
    echo "真实占用    : $(mb "$REAL") MB  (${PCT}%)"
    echo "  anon      : $(mb "$ANON") MB"
    echo "  kernel    : $(mb "$KERN") MB"
    echo "  file 缓存 : $(mb "$FILE") MB  (inactive $(mb "$INACT") MB 可回收)"
    echo "swap        : $(mb "$SWAP") / $(mb "$SWAPMAX") MB"
    echo "压力        : $(awk '/^some/{print $2, $3, $4}' /sys/fs/cgroup/memory.pressure)"
    echo "oom_kill    : $(awk '/^oom_kill/{print $2}' /sys/fs/cgroup/memory.events)"
    echo
    if [ -n "$PID" ]; then
        echo "xray pid=$PID  $(awk '/^VmRSS:/{print $2" "$3}' /proc/$PID/status)  匿名=$(awk '/^Anonymous:/{print $2" "$3}' /proc/$PID/smaps_rollup)"
    fi
    echo
    ps -o pid,rss,comm 2>/dev/null | sort -k2 -nr | head -6
    sleep 2
done

## License

MIT
