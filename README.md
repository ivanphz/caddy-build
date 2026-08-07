# my-custom-caddy

自动编译并发布带插件的 [Caddy](https://caddyserver.com) 二进制。

`plugins.txt` 是唯一真源：改一行插件清单，GitHub Actions 自动解析依赖、生成 `main.go`、编译 linux/amd64 与 linux/arm64、带 SHA256 校验和发 Release。

[![Build](https://github.com/ivanphz/my-custom-caddy/actions/workflows/build.yml/badge.svg)](https://github.com/ivanphz/my-custom-caddy/actions/workflows/build.yml)
[![Latest](https://img.shields.io/github/v/release/ivanphz/my-custom-caddy)](https://github.com/ivanphz/my-custom-caddy/releases/latest)

---

## 快速开始

### 安装

```bash
curl -fsSL https://raw.githubusercontent.com/ivanphz/my-custom-caddy/main/scripts/install.sh | sudo bash
```

脚本会自动识别架构、校验 SHA256、创建 `caddy` 系统用户、写入 systemd unit 并启动服务。装完之后 `caddy-update` 命令就可用了。

国内机器加个镜像前缀：

```bash
curl -fsSL https://raw.githubusercontent.com/ivanphz/my-custom-caddy/main/scripts/install.sh \
  | sudo GH_MIRROR=https://ghfast.top/ bash
```

### 更新

```bash
sudo caddy-update
```

已是最新版会直接退出。有新版本时的动作顺序是：下载 → 校验 SHA256 → 备份旧二进制 → 原子替换 → `caddy validate` 校验配置 → 重启 → 确认服务存活。**任何一步失败都会自动回滚到上一个二进制。**

### 其它命令

```bash
sudo caddy-update status                    # 看当前版本 / 最新版本 / 服务状态
sudo caddy-update uninstall                 # 卸载二进制和服务（保留配置与数据）
sudo CADDY_TAG=v20260724-1930 caddy-update  # 装/回退到指定版本
sudo NO_SERVICE=1 caddy-update              # 只更新二进制，不碰 systemd
```

### 日常运维

```bash
sudo systemctl reload caddy      # 热重载配置，不断连接
sudo systemctl restart caddy     # 重启
journalctl -u caddy -f           # 跟日志
caddy validate --config /etc/caddy/Caddyfile
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy list-modules --versions    # 确认插件都在
```

| 路径 | 用途 |
| :--- | :--- |
| `/usr/local/bin/caddy` | 二进制 |
| `/etc/caddy/Caddyfile` | 配置（来自 `dist/Caddyfile`） |
| `/usr/share/caddy/` | 站点根目录（默认欢迎页来自 `dist/index.html`） |
| `/var/lib/caddy` | 证书与状态（`.local/share/caddy`） |
| `/etc/systemd/system/caddy.service` | 服务定义 |

---

## 手动安装

不想跑脚本就自己来：

```bash
ARCH=amd64   # 或 arm64
BASE=https://github.com/ivanphz/my-custom-caddy/releases/latest/download

curl -fLO "$BASE/caddy-linux-$ARCH"
curl -fLO "$BASE/caddy-linux-$ARCH.sha256"
sha256sum -c "caddy-linux-$ARCH.sha256"      # 必做

sudo install -m 0755 "caddy-linux-$ARCH" /usr/local/bin/caddy
caddy version
```

> **注意**：覆盖一个正在运行的可执行文件会报 `Text file busy`。更新时先写到临时名再 `mv` 过去（`mv` 是 rename，对运行中的进程安全）：
> ```bash
> sudo install -m 0755 caddy-linux-$ARCH /usr/local/bin/caddy.new
> sudo mv -f /usr/local/bin/caddy.new /usr/local/bin/caddy
> sudo systemctl restart caddy
> ```

systemd unit 与 `caddyserver/dist/init/caddy.service` 对齐，用
`AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE`：

- `CAP_NET_BIND_SERVICE` — 非 root 的 caddy 用户绑 80/443，因此不需要 `setcap`
  （`setcap` 每次替换二进制后都会失效，很容易忘）
- `CAP_NET_ADMIN` — quic-go 用 `SO_RCVBUFFORCE` 绕过 `net.core.rmem_max` 扩 UDP
  接收缓冲，缺了它 HTTP/3 高吞吐下会丢包并在日志里刷 buffer 警告

---

## 已编译插件

| 插件 | 提供的能力 |
| :--- | :--- |
| [klzgrad/forwardproxy@naive](https://github.com/klzgrad/forwardproxy) | `forward_proxy` — NaiveProxy 分支 |
| [imgk/caddy-trojan](https://github.com/imgk/caddy-trojan) | `trojan` |
| [mholt/caddy-l4](https://github.com/mholt/caddy-l4) | `layer4` 全局块，四层代理 / 协议分流 |
| [caddyserver/jsonc-adapter](https://github.com/caddyserver/jsonc-adapter) | `--adapter jsonc`，带注释的 JSON 配置 |
| [greenpau/caddy-security](https://github.com/greenpau/caddy-security) | `authenticate` / `authorize`，SSO、OAuth、MFA |
| [mholt/caddy-events-exec](https://github.com/mholt/caddy-events-exec) | 事件触发外部命令 |
| [mholt/caddy-ratelimit](https://github.com/mholt/caddy-ratelimit) | `rate_limit` |
| [mholt/caddy-webdav](https://github.com/mholt/caddy-webdav) | `webdav` |
| [okrc/caddy-uploadcert-tencentcloud](https://github.com/okrc/caddy-uploadcert-tencentcloud) | 证书自动上传腾讯云 |
| [porech/caddy-maxmind-geolocation](https://github.com/porech/caddy-maxmind-geolocation) | `maxmind_geolocation` 匹配器（需自备 GeoLite2 库） |
| [caddy-dns/tencentcloud](https://github.com/caddy-dns/tencentcloud) | DNS-01 挑战，签泛域名证书 |
| [lanrat/caddy-dynamic-remoteip](https://github.com/lanrat/caddy-dynamic-remoteip) | `dynamic_remote_ip` 匹配器 |
| [tuzzmaniandevil/caddy-dynamic-clientip](https://github.com/tuzzmaniandevil/caddy-dynamic-clientip) | `dynamic_client_ip` 匹配器 |
| [fvbommel/caddy-combine-ip-ranges](https://github.com/fvbommel/caddy-combine-ip-ranges) | `http.ip_sources.combine` |
| [LeenHawk/caddy-edgeone-ip](https://github.com/LeenHawk/caddy-edgeone-ip) | `http.ip_sources.edgeone` |
| [monobilisim/caddy-ip-list](https://github.com/monobilisim/caddy-ip-list) | `http.ip_sources.list` |
| [WeidiDeng/caddy-cloudflare-ip](https://github.com/WeidiDeng/caddy-cloudflare-ip) | `http.ip_sources.cloudflare` |
| [xcaddyplugins/caddy-trusted-cloudfront](https://github.com/xcaddyplugins/caddy-trusted-cloudfront) | `http.ip_sources.cloudfront` |

每个 Release 的正文里有精确版本号和提交时间。

后四类都实现 `IPRangeSource`，典型用法是喂给 `trusted_proxies`：

```caddyfile
{
	servers {
		trusted_proxies combine {
			cloudflare
			edgeone
		}
	}
}
```

---

## 增删插件

编辑 `plugins.txt`，提交，剩下的交给 CI。

```
# 普通插件：一行一个 import path，永远取 @latest
github.com/mholt/caddy-ratelimit

# 需要 replace 的：original=replacement@ref
# ref 可以是分支名、tag 或 commit，CI 会解析成 pseudo-version 再写进 go.mod
github.com/caddyserver/forwardproxy=github.com/klzgrad/forwardproxy@naive

# 以 # 开头的是注释
```

`github.com/caddyserver/caddy/v2` 必须保留，但不会被写进 import（`main.go` 用的是 `caddy/v2/cmd` 和 `caddy/v2/modules/standard`）。

推送后 `Update Dependencies` 会跑，解析失败的条目会让 workflow 直接失败并列出来，**不会**把坏依赖提交上去。

---

## 工作原理

```
caddyserver/dist ──> Sync dist assets (每周一 18:00 / 手动)
                       校验后提交 dist/，不触发重新编译

plugins.txt
    │
    ├─ Update Dependencies (每周五 18:00 / 改 plugins.txt / 手动)
    │     解析 replace 的分支 → pseudo-version
    │     go get 各插件 @latest
    │     生成 main.go   ← 唯一真源，不再有 tools.go
    │     go mod tidy
    │     试编译一次（不过就不提交）
    │     提交 go.mod / go.sum / main.go  ← 用 PAT，否则不触发下游 workflow
    │
    └─ Build Custom Caddy (go.mod / go.sum / main.go 变更时触发)
          go mod verify           ← 不跑 tidy，-mod=readonly 保证可复现
          go build × {amd64, arm64}
          冒烟测试：version 注入是否生效、模块数是否合理
          对比上一个 Release 的 go_modules.json 生成变更日志
          发 Release
```

版本号形如 `v20260807-1610`（Asia/Shanghai），由 `init` job 统一生成，两个架构共用同一个 tag。

编译参数与 Caddy 官方一致：`-trimpath -ldflags "-w -s" -tags nobadger,nomysql,nopgx`（排除 BadgerDB / MySQL / PostgreSQL 存储后端以缩小体积），并额外注入 `CustomVersion`。`main.go` 里 import 了 `time/tzdata`，所以在没有系统时区库的精简环境下 `@` 时间匹配器一样能用。

### 仓库结构

```
plugins.txt                        ★ 插件清单，唯一需要手动编辑的文件
main.go                            自动生成，勿手改
go.mod / go.sum                    自动生成，勿手改

dist/Caddyfile                     → /etc/caddy/Caddyfile（仅当不存在时）
dist/index.html                    → /usr/share/caddy/index.html
dist/UPSTREAM.md                   同步来源与上游 commit 记录

scripts/install.sh                 安装 / 更新 / 卸载
scripts/release_notes.py           Release 正文生成

.github/workflows/update_deps.yml  依赖解析
.github/workflows/build.yml        编译与发布
.github/workflows/sync_dist.yml    从 caddyserver/dist 同步打包资产
.github/dependabot.yml             Actions 版本自动跟进（不管 Go 依赖）
.gitattributes                     强制 LF，防 CRLF 混入 plugins.txt
```

三层职责：**根目录 = 构建输入与产物**，`dist/` = 部署资产（不参与编译），
`scripts/` = 工具。

`dist/` 下的文件由 `sync_dist.yml` 每周一从 `caddyserver/dist` 自动同步，与上游
逐字节一致 —— 就是 `apt install caddy` 会给你的那套默认配置和欢迎页。之所以同步
进仓库而不是让 `install.sh` 直接从上游拉：`dist/Caddyfile` 会落到 `/etc/caddy/`，
走 CI 的话上游任何变动都先变成一个可审查的 commit，而不是无声地进到新装的机器上;
同时安装路径只依赖本仓库一个来源，一个 `GH_MIRROR` 覆盖全部，且任一 commit 都是
自洽快照。当前同步状态见 [`dist/UPSTREAM.md`](dist/UPSTREAM.md)。

不想要欢迎页（比如不希望默认页面暴露这是台 Caddy）：

```bash
curl -fsSL .../install.sh | sudo WELCOME=0 bash
```

此时会写一份只有 `respond` 的极简 Caddyfile，不依赖任何静态文件。

手工输入只有 `plugins.txt` 一个；`main.go` / `go.mod` / `go.sum` 全部由 `update_deps.yml`
生成并提交。**不要手改生成文件** —— `build.yml` 里的 `go mod tidy -diff` 会直接把不一致的
构建拦下来。

### 需要的 Secret

| 名称 | 用途 |
| :--- | :--- |
| `PAT` | 一个有 `repo` 权限的 Personal Access Token。`Update Dependencies` 用它提交，因为 `GITHUB_TOKEN` 的推送不会触发 `build.yml` |

---

## 校验与信任

每个 Release 都附带 `.sha256`，正文里也有一份。另外还发布了：

- `main.go` — 本次编译实际使用的入口文件，可以核对到底编进去了哪些插件
- `go_modules.json` — 完整依赖快照，可以核对每个模块的精确版本

安装脚本默认校验 SHA256，失败会中止。

插件都是从各自上游 `@latest` 拉的，这意味着上游一旦被投毒，下一次周五构建就会带进来。介意的话可以在 `plugins.txt` 里把版本钉死（用 `original=original@v1.2.3` 的形式）。
