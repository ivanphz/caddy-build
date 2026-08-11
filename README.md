# caddy-build

自动编译并发布带插件的 [Caddy](https://caddyserver.com) 二进制。

> 本仓库原名 `my-custom-caddy`。GitHub 会永久重定向旧地址（web / git / raw /
> release 资产都覆盖），已部署的机器无需处理。**但不要再新建一个叫
> `my-custom-caddy` 的仓库** —— 一旦重名，重定向会立即失效。

`plugins.txt` 是唯一真源：改一行插件清单，GitHub Actions 自动解析依赖、生成 `main.go`、编译 linux/amd64 与 linux/arm64、带 SHA256 校验和发 Release。

[![Build](https://github.com/ivanphz/caddy-build/actions/workflows/build.yml/badge.svg)](https://github.com/ivanphz/caddy-build/actions/workflows/build.yml)
[![Latest](https://img.shields.io/github/v/release/ivanphz/caddy-build)](https://github.com/ivanphz/caddy-build/releases/latest)

---

## 快速开始

### 安装

```bash
curl -fsSL https://raw.githubusercontent.com/ivanphz/caddy-build/main/scripts/install.sh | sudo bash
```

脚本会自动识别架构、校验 SHA256、创建 `caddy` 系统用户、写入 systemd unit 并启动服务。装完之后 `caddy-update` 命令就可用了。

网络受限时见下面的「下载来源」。

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

### 国内镜像

每次发布后自动同步到两个国内平台（`mirror_cn.yml`），二进制、`install.sh` 和一份
精简 README 都会推过去。镜像仓库不含源码、不含插件清单。

**Gitee**

```bash
curl -fsSL https://gitee.com/ivanabc/caddy-build/raw/main/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://gitee.com/ivanabc/caddy-build/raw/main \
  CADDY_REL_BASE=https://gitee.com/ivanabc/caddy-build/releases/download bash
```

**CNB**

```bash
curl -fsSL https://cnb.cool/ivanabc/caddy-build/-/raw/main/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://cnb.cool/ivanabc/caddy-build/-/raw/main \
  CADDY_REL_BASE=https://cnb.cool/ivanabc/caddy-build/-/releases/download bash
```

两边的配额差两个数量级，保留策略因此不同：

| | 附件配额 | 每 release 占用 | 保留数 |
| :--- | ---: | ---: | ---: |
| GitHub | 无限制 | 139 MB | 12 |
| Gitee | **1 GB**（含仓库附件） | 139 MB | **5** |
| CNB | 100 GiB（对象存储免费额度） | 139 MB | 12 |

Gitee 是唯一瓶颈：7 个就到 966 MB，第 8 个直接爆配额，且失败会发生在上传中途、
留下一个附件不全的 release。所以 `GITEE_KEEP` 默认 5 且必须真的执行删除。

### 下载来源

脚本要拉两类东西，**它们的 URL 形状不同，所以是两个独立开关**：

| | 内容 | 体积 | 可选来源 |
| :--- | :--- | ---: | :--- |
| `RAW_BASE` | `install.sh`、`dist/*` | 几十 KB | GitHub raw / jsDelivr / 自建 Worker / R2 |
| `REL_BASE` | 二进制 + `.sha256` | 约 69 MB | GitHub Releases / 前缀型代理 / R2 |

**jsDelivr 拿不了二进制。** 它的 `/gh/` 单文件上限 20 MB，超了返回 403；而且
`/gh/owner/repo@ref/path` 走的是 git 树，压根不经过 Releases。所以
`CADDY_SOURCE=jsdelivr` 只改仓库文件来源，二进制仍走 GitHub。

```bash
# 前缀型代理（两类都覆盖，最省事）
curl -fsSL <install.sh> | sudo GH_MIRROR=https://ghfast.top/ bash

# 仓库文件走 jsDelivr，二进制走 GitHub
curl -fsSL <install.sh> | sudo CADDY_SOURCE=jsdelivr bash
curl -fsSL <install.sh> | sudo CADDY_SOURCE=fastly bash

# 自建 Worker（私有仓库解析脚本那一套）
curl -fsSL <install.sh> | sudo \
  CADDY_RAW_BASE=https://<token>.example.com/caddy-build/main \
  CADDY_REL_BASE=https://<token>.example.com/rel/caddy-build bash

# 完全脱离 GitHub（R2 / 自建对象存储）
curl -fsSL <install.sh> | sudo \
  CADDY_RAW_BASE=https://dl.example.com/caddy-build/main \
  CADDY_REL_BASE=https://dl.example.com/caddy-build \
  CADDY_TAG_FILE=https://dl.example.com/caddy-build/latest.txt bash

# 连版本解析都走不通时，直接指定
sudo CADDY_TAG=v2.11.4-20260807.1930 caddy-update
```

`CADDY_RAW_BASE` 的形状是「基址 + `/仓库内相对路径`」，与
`raw.githubusercontent.com/<owner>/<repo>/<ref>` 完全同构，所以 Worker 那种
`https://<token>/<repo>/<ref>/<path>` 的路由开箱即用。

`CADDY_TAG_FILE` 是给自建源用的：对象存储没有 `releases/latest` 那种 302 可跟，
改用一个纯文本指针文件，里面只有一行 tag。

安装时解析出的来源会**固化进 `/usr/local/bin/caddy-update`**，之后每次更新自动沿用，
不必重复设环境变量 —— 漏了这点的话，用镜像装的机器第二次更新就会退回 GitHub 源而失败。

> **私有仓库注意**：Worker 转发仓库文件只是路径映射，但 release 资产不是 ——
> 私有仓库的资产必须走带鉴权的 API（`/repos/{owner}/{repo}/releases/assets/{id}`
> 配 `Accept: application/octet-stream`），不是静态路径。若本仓库转私有，
> 69 MB 二进制的分发要单独设计，不能照搬 wloc 那套。

### 日常运维

```bash
sudo systemctl reload caddy      # 热重载配置，不断连接
sudo systemctl restart caddy     # 重启
journalctl -u caddy -f           # 跟日志
caddy validate --config /etc/caddy/Caddyfile
caddy fmt --overwrite /etc/caddy/Caddyfile
caddy list-modules --versions    # 确认插件都在
caddy build-info | grep vcs      # 这个二进制是哪个 commit 编的
```

| 路径 | 用途 |
| :--- | :--- |
| `/usr/local/bin/caddy` | 二进制 |
| `/etc/caddy/Caddyfile` | 配置（来自 `dist/Caddyfile`） |
| `/usr/share/caddy/` | 站点根目录（默认欢迎页来自 `dist/index.html`） |
| `/var/lib/caddy` | 证书与状态（`.local/share/caddy`） |
| `/etc/systemd/system/caddy.service` | 服务定义 |

---

## 镜像到 Cloudflare R2（可选）

受限网络下的第二条下载路径。**不设仓库变量 `R2_BUCKET` 就整个任务跳过**，
对默认使用者零影响。

| 类型 | 名称 |
| :--- | :--- |
| Variables | `R2_BUCKET`、`R2_ACCOUNT_ID`、`R2_PREFIX`（可选，默认 `caddy-build`） |
| Secrets | `R2_ACCESS_KEY_ID`、`R2_SECRET_ACCESS_KEY` |

每次发布后把二进制、`.sha256`、`install.sh`、`dist/*` 和一个 `latest.txt` 版本指针
推到 R2，然后**以 GitHub 上还存在的 release 为准**清理旧目录 —— 两边保留策略自动
一致，也不用担心 tag 字典序排不对（`v2.9` vs `v2.11`）。

### 为什么不推国内平台

Gitee 自 2022 年 5 月起，所有新上线的开源仓库需人工审核后才能公开，重新公开要提交
承诺书，第一条是「不违反任何国家法律法规」。腾讯云 COS、阿里云 OSS 同样要实名，
且内容会被扫描。

而本仓库的二进制里编进了 forwardproxy(naive) 和 trojan。问题不在于仓库可能被下架，
而在于把实名身份和这个产物绑定。**这条路的障碍不是技术性的。**

### 关于公共加速站

`ghproxy.com` 已经关停，同类站点随时可能步后尘。所以脚本把镜像做成 `GH_MIRROR`
环境变量而不是写死某个域名 —— 能用就用，挂了换一个。要稳定就用自己可控的：
一个 gh-proxy Worker（零新增基础设施，`CADDY_RAW_BASE` / `CADDY_REL_BASE`
已支持任意路由形状），或上面的 R2（不依赖 Cloudflare→GitHub 这一跳）。

## 与官方 caddy 包 / caddy 自带命令的关系

本脚本**只管安装、更新、卸载**。装完之后日常操作全部是原生的 `caddy` 和 `systemctl`
命令，没有任何包装层。

有三件事需要注意：

**`apt upgrade` 更新不了它。** 这不是 .deb 包，二进制在 `/usr/local/bin/caddy`，
apt 完全不知道它存在。更新只有 `sudo caddy-update` 一条路。

**别和官方 apt 包共存。** 官方包装在 `/usr/bin/caddy` 并自带
`/lib/systemd/system/caddy.service`。本构建装在 `/usr/local/bin/caddy` 并写
`/etc/systemd/system/caddy.service` —— PATH 上 `/usr/local/bin` 在前、`/etc` 下的
unit 覆盖 `/lib` 下的，所以平时是本构建生效。但 `apt upgrade` 会悄悄换掉
`/usr/bin/caddy`，一旦本地 unit 被误删就会**静默回落到没有插件的官方版本**。
安装脚本会检测并提示，建议 `sudo apt remove caddy` 或 `sudo apt-mark hold caddy`。

**不要用 `caddy upgrade` / `caddy add-package` / `caddy remove-package`。**
这几个是 Caddy 自带的命令，会去 caddyserver.com 重新下载一个二进制并**原地替换**，
绕过整条构建流水线。你的多数插件不在官方注册表里，结果要么失败，要么装上一个缺插件的
二进制。要加减插件，改 `plugins.txt`。

## 手动安装

不想跑脚本就自己来：

```bash
ARCH=amd64   # 或 arm64
BASE=https://github.com/ivanphz/caddy-build/releases/latest/download

curl -fLO "$BASE/caddy-linux-$ARCH"
curl -fLO "$BASE/caddy-linux-$ARCH.sha256"
sha256sum -c "caddy-linux-$ARCH.sha256"      # 必做

sudo install -m 0755 "caddy-linux-$ARCH" /usr/local/bin/caddy
caddy version                                # → v2.11.4，与官方二进制同形
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

不想要欢迎页：

```bash
curl -fsSL .../install.sh | sudo WELCOME=0 bash
```

此时 Caddyfile 仍然用官方那份，只是不放 `index.html`，根路径返回 404。

### 关于默认页与「指纹」

一个常见的误判是「默认欢迎页暴露了这是 Caddy，换个低调的占位页更安全」。**反了。**

Caddy 的身份从 TLS 指纹、HTTP/3 支持、ALPN 顺序、证书签发模式上早就可见，改首页
藏不住。真正决定风险的是**匿名集大小**：

| 主动探测得到的响应 | 匿名集 | 作为扫描特征 |
| :--- | :--- | :--- |
| 官方欢迎页 | 极大 —— 全网每台装完没配过的 Caddy | 几乎无判别力 |
| 任何自造文案（如 `respond "xxx"`） | ≈ 1 | 完美判别式，一次字符串匹配即可枚举 |
| 空目录 → 404 | 大 | 判别力低 |

所以 `install.sh` 里**没有**「换一个更低调的占位页」这个选项：要么用官方那张，要么留空。
连网络故障时的兜底 Caddyfile 也是官方那份的逐字节内置副本，不会自造任何独特文本。

真正的答案不在这个开关上 —— 如果这台机器要长期承载 naive / trojan 流量，正解是放上
**真实内容**或 `reverse_proxy` 一个真实站点。只有占位页却持续有流量，这个组合本身就异常，
换哪张占位页都一样。

手工输入只有 `plugins.txt` 一个；`main.go` / `go.mod` / `go.sum` 全部由 `update_deps.yml`
生成并提交。**不要手改生成文件** —— `build.yml` 里的 `go mod tidy -diff` 会直接把不一致的
构建拦下来。

### 版本号

**`caddy version` 输出的就是真正的 Caddy 版本**，和官方二进制、和 xcaddy 构建完全同形：

```
$ caddy version
v2.11.4 h1:...
```

这是刻意的：这个产物**就是 Caddy，只是多带插件**，不应该伪装成另一个东西。
构建时没有设 `-X ...CustomVersion=` —— 那个变量会整个替换掉 Caddy 自报的版本，
任何按 Caddy 版本做判断的脚本、文档查询、issue 上报都会拿到一串它不认识的东西。
不设它时，Caddy 从 `debug.ReadBuildInfo()` 读依赖 `caddy/v2` 的版本，行为与上游一致。

Release tag 是**仓库侧的标识**，不进二进制：

```
v2.11.4-20260807.1930
└─────┘ └──────┘ └──┘
 上游核心  构建日期  时分
```

带上核心版本，是为了在 Releases 页面上一眼看出每次构建对应哪个 Caddy；
用日期而非递增构建号，是因为旧 release 会被自动清理，靠数已有 release 递增会重号。

**插件版本不进 tag。** 18 个插件会让 tag 长到没法读，且插件版本已经记录在三个地方：
release notes 的表格、随 release 发布的 `go_modules.json`、以及二进制自带的
`caddy build-info`。tag 是标识符，不是清单。

```bash
caddy build-info                  # 完整依赖树及版本
caddy list-modules --versions     # 已注册模块
```

### 为什么不把日期拼进 caddy version

拼上去的写法是 `v2.11.4-20260807.1930`，但那个连字符在 semver 里是**预发布标识符**的
引导符，而规范规定预发布版本的优先级**低于**对应正式版 —— 任何做 semver 比较的工具
会认为你跑的是比 2.11.4 **更旧**的东西。判断 `caddy >= 2.11.4` 会得到否定结论。

正确的分隔符是加号：`v2.11.4+20260807.1930`。semver 里加号引导构建元数据，明确规定
「比较优先级时忽略」。但 Docker 的 tag 字符集不允许 `+`，以后要打镜像会卡住。

更重要的是**没必要**——构建身份已经在二进制里了。Go 在编译时会把源码 commit stamp
进构建信息，`-ldflags "-w -s"` 剥不掉（它在独立的段里）：

```bash
$ caddy build-info | grep vcs
build   vcs=git
build   vcs.revision=1ef6f3399a3e451f59d2f168fb274738664274f6
build   vcs.time=2026-08-07T15:40:02Z
build   vcs.modified=false
```

commit 比日期更精确：日期只说明哪天编的，commit 直接指向那一刻的 `go.mod` 和
`main.go`。所以 `version` 那一栏留给 Caddy 自己，构建身份走 `build-info`，
release 标识走 `.build-version` —— 三个问题三个答案，不互相污染。

### 更新检测

因为 tag 不在二进制里，`caddy-update` 用两层判断：

1. `/etc/caddy/.build-version` 记录已安装的 release tag（安装时写入，root 所有 0644）
2. 状态文件缺失时（手动安装 / 从旧版迁移），回退到**比对已装二进制与最新 release 的
   sha256**

第二层其实更严格 —— 它能发现二进制被手动替换或损坏，而不只是标签对不上。
回滚发生时状态文件会被删除，避免谎报版本。

```bash
$ sudo caddy-update status
仓库           ivanphz/caddy-build
caddy version  v2.11.4
已装 release   v2.11.4-20260807.1930
源码 commit    1ef6f33
最新 release   v2.11.5-20260814.1900
服务           running

有新版本可用，运行 sudo caddy-update
```

### Release 保留策略

每次成功发布后，`build.yml` 会自动删除超出保留数量的旧 release（连同 tag），
默认保留最近 **12 个**。想改就在 Settings → Secrets and variables → Actions →
Variables 里加一个 `KEEP_RELEASES`，脚本内置下限为 3。

为什么要清理 —— 不是为了省空间。GitHub 对 release 的总大小和带宽都没有限制，
放着不管也不会有人来找你。真正的理由是**旧构建是负债**：一年前的二进制里带着
一年份未修补的 Caddy 与依赖 CVE，而 `CADDY_TAG=` 能一键把它装回任何一台机器。
留一排能一键安装的过期二进制，本身就是个降级攻击面。

按每 8~9 天一个版本的实际节奏，保留 12 个约等于 3 个月。插件更新真出问题，
你几天内就会发现；超过两三个月的构建，回滚过去比不回滚更危险。

清理逻辑按创建时间倒序跳过前 N 个，**刚发布的那个必然排第一，不会被误删** ——
这点很重要，`build.yml` 的插件变更对比要从 `releases/latest` 下载
`go_modules.json`，最新版必须保住。

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
