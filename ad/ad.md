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

## License

MIT
