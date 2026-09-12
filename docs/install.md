# 安装与运维

面向**在机器上装 caddy 的人**。想配镜像源看 [mirrors.md](mirrors.md)，
想改插件看 [plugins.md](plugins.md)。

## 安装

```bash
curl -fsSL https://raw.githubusercontent.com/ivanphz/caddy-build/main/scripts/install.sh | sudo bash
```

脚本会自动识别架构、校验 SHA256、创建 `caddy` 系统用户、写入 systemd unit 并启动服务。装完之后 `caddy-update` 命令就可用了。

网络受限时见下面的「下载来源」。

## 更新

```bash
sudo caddy-update
```

已是最新版会直接退出。有新版本时的动作顺序是：下载 → 校验 SHA256 → 备份旧二进制 → 原子替换 → `caddy validate` 校验配置 → 重启 → 确认服务存活。**任何一步失败都会自动回滚到上一个二进制。**

## 其它命令

```bash
sudo caddy-update status                    # 看当前版本 / 最新版本 / 服务状态
sudo caddy-update uninstall                 # 卸载二进制和服务（保留配置与数据）
sudo CADDY_TAG=v2.11.4-20260807.1930 caddy-update  # 装/回退到指定版本
sudo NO_SERVICE=1 caddy-update              # 只更新二进制，不碰 systemd

caddy-update --check                        # 只探测不安装，输出 key=value
caddy-update --contract-version             # 打印下游契约版本号
```

后两个是给自动化编排用的，不动机器、不需要 root：

```
$ caddy-update --check
contract=1
current=v2.11.3-20260701.0900
latest=v2.11.4-20260813.1110
would_change=yes
service_active=yes
```

退出码 `0` = 探测成功（不管有没有新版本），`1` = 探测失败，`3` = 没装。
完整约定见 [`CONTRACT.md`](../CONTRACT.md)。

## 完整卸载

`apt remove` 删不掉它 —— 二进制在 `/usr/local/bin/caddy`，不是 .deb 包。

**第一步：停服务、删程序**

```bash
sudo caddy-update uninstall
```

移除 `/usr/local/bin/caddy`、`/usr/local/bin/caddy-update`、systemd unit 和版本状态文件。
**配置、证书、站点内容一概不动** —— 卸载重装不会丢证书。

`caddy-update` 已经不在了（手动删过、或当初用 `NO_SERVICE=1` 装的旧版本）就手工来：

```bash
sudo systemctl disable --now caddy
sudo rm -f /etc/systemd/system/caddy.service
sudo rm -f /usr/local/bin/caddy /usr/local/bin/caddy.bak /usr/local/bin/caddy-update
sudo systemctl daemon-reload
```

**第二步：确认不需要后，删数据**

```bash
sudo rm -rf /etc/caddy       # Caddyfile、.build-version、.welcome-sha256
sudo rm -rf /var/lib/caddy   # 证书、ACME 账户、OCSP 缓存
sudo rm -rf /var/log/caddy
sudo rm -rf /usr/share/caddy # 站点根目录，放了自己的内容就别删
```

`/var/lib/caddy` 里是 ACME 账户密钥和已签发的证书。删掉后重装会重新走一遍签发流程，
同一域名短时间反复申请可能撞上 CA 的速率限制。**只是想换个版本就别删这个目录。**

**第三步：删系统用户**

```bash
sudo userdel caddy
sudo groupdel caddy 2>/dev/null || true
```

这个用户是 `useradd --system --create-home --home-dir /var/lib/caddy` 建的，
家目录就是数据目录，第二步已经删过。

**顺带检查有没有官方 apt 包**

```bash
dpkg -l caddy                 # 有输出说明装过官方源的包
sudo apt-mark unhold caddy    # 之前 hold 过的话
sudo apt remove --purge caddy
```

**确认干净**

```bash
command -v caddy || echo "已清除"
systemctl status caddy 2>&1 | head -1
```

## 下载来源

脚本要拉两类东西，**它们的 URL 形状不同，所以是两个独立开关**：

| | 内容 | 体积 | 可选来源 |
| :--- | :--- | ---: | :--- |
| `RAW_BASE` | `install.sh`、`dist/*` | 几十 KB | GitHub raw / jsDelivr / 自建 Worker / R2 |
| `REL_BASE` | 二进制 + `.sha256` | 约 69 MB | GitHub Releases / 前缀型代理 / R2 |

`REL_BASE` 假设资产地址能按 `基址/tag/文件名` 拼出来。**这个假设只对 GitHub 式
的平台成立。** 拼不出来的平台（Gitee）改用 `CADDY_MANIFEST` 指向一个
`文件名 → 真实地址` 的清单，它同时覆盖 `REL_BASE` 和版本解析。

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

# 地址推不出来的平台（Gitee 等）：用清单
curl -fsSL <install.sh> | sudo \
  CADDY_RAW_BASE=https://gitee.com/<owner>/<repo>/raw/master \
  CADDY_MANIFEST=https://gitee.com/<owner>/<repo>/raw/master/manifest.txt bash

# 连版本解析都走不通时，直接指定
sudo CADDY_TAG=v2.11.4-20260807.1930 caddy-update
```

仓库文件默认取 `main` 分支，可用 `CADDY_REF=` 改（自建镜像分支名不同时用得上）。

`dist/Caddyfile` 和 `dist/index.html` 这两个小文件在主源取不到时会自动改用
`CADDY_RAW_FALLBACK`（默认 jsDelivr），设成空串禁用。二进制不走这条路。
取不到时会打出 HTTP 状态码 —— 404 是镜像没同步到，403 是平台拦了，000 是没连上，
三种情况修法完全不同。

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
> 69 MB 二进制的分发要单独设计，不能照搬「Worker 转发 raw 文件」那一套。

## 关于公共加速站

`ghproxy.com` 已经关停，同类站点随时可能步后尘。所以脚本把镜像做成 `GH_MIRROR`
环境变量而不是写死某个域名 —— 能用就用，挂了换一个。要稳定就用自己可控的：
一个 gh-proxy Worker（零新增基础设施，`CADDY_RAW_BASE` / `CADDY_REL_BASE`
已支持任意路由形状），或[自建 R2](mirrors.md#镜像到-cloudflare-r2可选)（不依赖
Cloudflare→GitHub 这一跳）。

## 日常运维

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


---

| 文档 | 内容 |
| :--- | :--- |
| [README](../README.md) | 项目是什么、一条命令装上 |
| [docs/install.md](install.md) | 安装、更新、卸载、换源、日常运维 |
| [docs/mirrors.md](mirrors.md) | Gitee / CNB / R2 三个镜像的配置与排障 |
| [docs/plugins.md](plugins.md) | 编进去了哪些插件、怎么增删 |
| [docs/build.md](build.md) | 从 `plugins.txt` 到一个二进制的完整链路 |
| [docs/design.md](design.md) | 设计取舍，以及为什么不用另一种做法 |
| [docs/ROADMAP.md](ROADMAP.md) | 待开发 |
| [CONTRACT.md](../CONTRACT.md) | 下游消费契约（给脚本看的） |
| [.github/workflows/README.md](../.github/workflows/README.md) | 各 workflow 的职责与所需 Secret |
