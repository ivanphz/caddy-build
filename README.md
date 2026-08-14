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
sudo CADDY_TAG=v2.11.4-20260807.1930 caddy-update  # 装/回退到指定版本
sudo NO_SERVICE=1 caddy-update              # 只更新二进制，不碰 systemd
```

### 完整卸载

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

### 国内镜像

每次发布后由 `build.yml` 调用 `mirror.yml` 自动同步到两个国内平台，二进制、
`install.sh`、一份精简 README 和一个 `manifest.txt` 都会推过去。镜像仓库不含源码、
不含插件清单。

**注意分支**：Gitee 建仓默认 `master`，CNB 默认 `main`，两边的 raw 路径因此不同。
流水线每次都会探测远端默认分支并把正确的地址写进镜像仓库的 README 和运行摘要 ——
下面这两条命令以实际探测结果为准，改过分支就照镜像仓库首页那份。

**Gitee**（默认 `master`）

```bash
curl -fsSL https://gitee.com/ivanabc/caddy-build/raw/master/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://gitee.com/ivanabc/caddy-build/raw/master \
  CADDY_MANIFEST=https://gitee.com/ivanabc/caddy-build/raw/master/manifest.txt bash
```

**CNB**（默认 `main`，注意 raw 路径是 `/-/git/raw/`）

```bash
curl -fsSL https://cnb.cool/ivanabc/caddy-build/-/git/raw/main/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://cnb.cool/ivanabc/caddy-build/-/git/raw/main \
  CADDY_MANIFEST=https://cnb.cool/ivanabc/caddy-build/-/git/raw/main/manifest.txt bash
```

> CNB 的 `/-/raw/` 会返回 **HTTP 200 + 一张 HTML 错误页**（软 404），
> `curl -f` 拦不住，整页 HTML 会被喂进 `bash`，报的是
> `syntax error near unexpected token '<'`。真实地址在网页上打开任意文件、
> 点「复制路径 → 通过 cURL 下载」就能拿到；`/-/blob/` 是文件页不是原始内容。

`manifest.txt` 里是流水线从各平台 API **实际拿到**的下载地址，对地址形状不做任何假设。
Gitee 目前返回的是 `releases/download/{tag}/{文件名}`，和 GitHub 同形，所以
`CADDY_REL_BASE` 一样能用；但同类平台历史上出现过 `attach_files/{数字ID}/download/{文件名}`
这种从 tag 推不出来的形状。清单的价值就在于两种情况它都对，平台哪天改了也不用动安装脚本。

清单只描述**最新一版**。要装指定旧版本，改用 `CADDY_REL_BASE` + `CADDY_TAG`：

```bash
curl -fsSL https://gitee.com/ivanabc/caddy-build/raw/master/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://gitee.com/ivanabc/caddy-build/raw/master \
  CADDY_REL_BASE=https://gitee.com/ivanabc/caddy-build/releases/download \
  CADDY_TAG=v2.11.4-20260807.1930 bash
```

同时设了 `CADDY_MANIFEST` 和一个对不上的 `CADDY_TAG`，脚本会直接报错停下，
不会「日志说在装 A、实际下载 B」。

> Gitee 的 raw 地址会 302 跳到 `raw.giteeusercontent.com` 的签名链接。
> 脚本用的是 `curl -fsSL`（带 `-L`）所以没问题，手动 `curl` 验证时记得加 `-L`，
> 否则只会看到一段 `<a href="...">Found</a>` 的跳转页。

> 仓库名来自仓库变量 `GITEE_REPO` / `CNB_REPO`，上面写的 `ivanabc/caddy-build`
> 只是当前的值。

两边的配额差两个数量级，保留策略因此不同：

| | 附件配额 | 每 release 占用 | 保留数 |
| :--- | ---: | ---: | ---: |
| GitHub | 无限制 | 139 MB | 12 |
| Gitee | **1 GB**（含仓库附件） | 139 MB | **5** |
| CNB | 100 GiB（对象存储免费额度） | 139 MB | 12 |

Gitee 是唯一瓶颈：7 个就到 966 MB，第 8 个直接爆配额，且失败会发生在上传中途、
留下一个附件不全的 release。所以 `GITEE_KEEP` 默认 5 且必须真的执行删除。

#### Gitee 走 SSH 中转

GitHub runner 在境外，直传 Gitee 实测不到 75 KB/s 且会卡死；CNB 有 366 KB/s，够用。
所以 **Gitee 的上传腿走中转机，CNB 直连**。

只有 72MB 的上传走中转：建 release、清理旧版本等控制面仍在 runner 上跑。中转机直接
从 GitHub 拉产物，runner 不碰大文件。

| 类型 | 名称 | 说明 |
| :--- | :--- | :--- |
| Secret | `GITEE_RELAY_KEY` | 私钥全文（含 BEGIN/END 行） |
| Variable | `GITEE_RELAY_HOST` | 中转机地址 |
| Variable | `GITEE_RELAY_USER` | 默认 `root` |
| Variable | `GITEE_RELAY_PORT` | 默认 `22` |
| Variable | `GITEE_RELAY_KNOWN_HOSTS` | `ssh-keyscan -p 22 <host>` 的输出 |

**不设 `GITEE_RELAY_HOST` 就自动回落到直连**，其余配置不变。

```bash
# 生成专用密钥（独立一把，泄露时好单独吊销）
ssh-keygen -t ed25519 -f ~/.ssh/caddy_relay -N '' -C 'gh-actions-relay'
ssh-copy-id -i ~/.ssh/caddy_relay.pub root@<中转机>

cat ~/.ssh/caddy_relay      # → GITEE_RELAY_KEY
ssh-keyscan -p 22 <中转机>   # → GITEE_RELAY_KNOWN_HOSTS
```

中转机上建议给这把钥匙加限制，它只需要执行 `bash -s`：

```
# ~/.ssh/authorized_keys，公钥前加 restrict
restrict,pty ssh-ed25519 AAAA... gh-actions-relay
```

**中转机不留痕**，三条是设计保证：

- 远端工作目录用 `mktemp -d`，`trap` 覆盖 `EXIT HUP INT TERM`，SSH 断线也会清理
- 脚本经 stdin 喂给 `bash -s`，不落远端磁盘
- token 走 curl 配置文件而非命令行（否则 `ps` 全程可见），随临时目录一起删

中转机下载完还会用 runner 那份 `.sha256` 校验，等于给链路加了端到端一致性检查，
校验不过就中止，不会把损坏的文件推上去。

### 选中转机：必须实测

`scripts/bench-mirror.sh` 用来测一台机器值不值得做中转。**不要凭地理位置猜** ——
实测两台都在香港的机器，结果差了 80 倍：

| 机器 | GitHub 下载 | → Gitee 上传 | 结论 |
| :--- | ---: | ---: | :--- |
| AWS 香港 | 快 | **3007 KB/s** | 可用，72MB 约 24 秒 |
| 另一台香港 VPS | 106 MB/s | **13~39 KB/s** | 不可用 |
| GitHub runner | — | <75 KB/s（卡死） | 不可用 |

下载腿快不代表上传腿快，出海方向和回国方向是两条路由。

```bash
scp scripts/bench-mirror.sh root@<候选机>:/tmp/
ssh root@<候选机>

export GITEE_TOKEN=xxx CNB_TOKEN=yyy          # 别写进命令行，会留在 history 里
/tmp/bench-mirror.sh dl    ivanphz/caddy-build              # GitHub → 本机
/tmp/bench-mirror.sh gitee ivanabc/caddy-build "$GITEE_TOKEN"
/tmp/bench-mirror.sh cnb   ivanabc/caddy-build "$CNB_TOKEN"
```

测试 release 在退出时删除，**Ctrl-C / 被 kill / 中途报错也会删**。万一还是漏了
（比如机器断电），扫一遍：

```bash
/tmp/bench-mirror.sh purge gitee ivanabc/caddy-build "$GITEE_TOKEN"
```

每个遗留的 `bench-*` 都带着 20MB 附件，会一直占着 Gitee 那 1 GB 的配额。

传 20MB 随机数据（随机是为了防中间环节压缩把速率测虚），带实时进度，完事自动删掉
测试 release。判断标准：

| 上行速率 | 结论 |
| :--- | :--- |
| > 1 MB/s | 适合做中转，72MB 约 1 分钟 |
| 300~800 KB/s | 能用，单文件 2~4 分钟 |
| < 150 KB/s | 不可用，换机器 |

可选环境变量：`SIZE_MB`（默认 20）、`INTERVAL`（进度间隔，默认 3）、`PROXY`（走代理测，
`curl --proxy` 语法）、`BRANCH`、`KEEP=1`（保留测试 release 便于排查，此时需自行删除）。

### 下载来源

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

自己可控的第三条下载路径，不依赖任何代码托管平台。**不设 `R2_ACCESS_KEY_ID`
就整个步骤跳过**，对默认使用者零影响。

### 桶里的布局

```
<PREFIX>/<tag>/caddy-linux-amd64        资产，按 tag 分目录
<PREFIX>/<tag>/caddy-linux-amd64.sha256
<PREFIX>/main/scripts/install.sh        仓库文件
<PREFIX>/main/dist/Caddyfile
<PREFIX>/main/dist/index.html
<PREFIX>/main/manifest.txt
<PREFIX>/latest.txt                     最新 tag，给 CADDY_TAG_FILE 用
```

保留策略**以 GitHub 上还存在的 release 为准**，两边自动一致，也不用担心 tag
字典序排不对（`v2.9` vs `v2.11`）。和另外两个平台一样，重跑时会先核对资产是否
齐全，齐全就跳过上传。

### 一、建桶和令牌

1. Cloudflare 控制台 → **R2** → 创建桶。区域选自动即可。
2. 同一页右侧 **Manage R2 API Tokens** → **Create API token**：
   - 权限选 **Object Read & Write**
   - **Specify bucket** 只勾刚建的那个桶（别给账户级权限，这个流水线只需要读写对象）
   - 创建后会给出 **Access Key ID** 和 **Secret Access Key**，
     后者**只显示一次**，当场存好
3. **Account ID** 在 R2 概览页右侧，也可以从控制台 URL 里取。

工作流用的 S3 端点是 `https://<Account ID>.r2.cloudflarestorage.com`，
由 `R2_ACCOUNT_ID` 拼出来，不用单独配。

### 二、公开访问（可选但强烈建议）

桶默认是私有的。不配公开地址流水线照样跑，只是不生成清单、装机得自己指定地址。

两种开法：

| 方式 | 地址形如 | 适用 |
| :--- | :--- | :--- |
| **自定义域**（推荐） | `https://cdn.example.com` | 走 Cloudflare 缓存，可加 WAF / 缓存规则 |
| r2.dev 子域 | `https://pub-<32位十六进制>.r2.dev` | 只适合临时验证 |

Cloudflare 官方明确说 r2.dev **不是给生产用的**：超过速率限制（每秒几百请求）会返回
`429`，而且**带宽本身也可能被限速**。这里要发的是 70 MB 的二进制，限速直接体现在
下载耗时上 —— 用自定义域。

配自定义域：桶 → **Settings** → **Custom Domains** → **Connect Domain**，
填一个**该 Cloudflare 账户下已托管的域名**的子域，等状态从 Initializing 变成 Active。
走自定义域还有个附带好处：重复下载命中 Cloudflare 边缘缓存，连 Class B 操作都省了。

### 三、填进 GitHub

`Settings → Secrets and variables → Actions`

| 类型 | 名称 | 值 |
| :--- | :--- | :--- |
| Secret | `R2_ACCESS_KEY_ID` | 上面拿到的 Access Key ID |
| Secret | `R2_SECRET_ACCESS_KEY` | Secret Access Key |
| Variable | `R2_ACCOUNT_ID` | 账户 ID |
| Variable | `R2_BUCKET` | 桶名 |
| **Secret** | `R2_PUBLIC_BASE` | `https://cdn.example.com`（不带尾斜杠） |
| Variable | `R2_PREFIX` | 可选，默认 `caddy` |
| Variable | `R2_KEEP` | 可选，默认 12 |

`R2_PUBLIC_BASE` **放 Secrets 而不是 Variables**：本仓库是公开的，GitHub 会把
step 的 `env:` 块原样打进日志，`vars.*` 明文可见、`secrets.*` 才打码。桶名和账户 ID
泄露无所谓（没凭据用不了），公开域名泄露就等于把下载地址挂出去了。

### 四、装机

```bash
curl -fsSL https://cdn.example.com/caddy/main/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://cdn.example.com/caddy/main \
  CADDY_MANIFEST=https://cdn.example.com/caddy/main/manifest.txt bash
```

R2 的地址能按 tag 拼出来（和 GitHub 同形），所以还有第二条路 —— 它能装
**任意还保留着的旧版本**，清单只指向最新一版：

```bash
curl -fsSL https://cdn.example.com/caddy/main/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://cdn.example.com/caddy/main \
  CADDY_REL_BASE=https://cdn.example.com/caddy \
  CADDY_TAG_FILE=https://cdn.example.com/caddy/latest.txt bash
```

两条命令流水线跑完都会打进 Run summary。

### 会不会产生费用

R2 **不收出网带宽费**（任何量级），免费额度是每月 10 GB 存储 + 100 万次 A 类操作
（写/列举）+ 1000 万次 B 类操作（读）。

按这个项目的量：保留 12 个版本约 1.7 GB 存储，离 10 GB 还远；每次发布约十几次
A 类操作。B 类操作要一千万次才碰线 —— 也就是一千万次下载。**正常用法下是 0 元。**

真正要盯的是存储：调大 `R2_KEEP` 会线性增长，每个版本约 140 MB。

### 镜像端排障

镜像仓库里应该有这些：

```bash
B=https://gitee.com/ivanabc/caddy-build/raw/master   # 换成你的
for f in scripts/install.sh dist/Caddyfile dist/index.html manifest.txt; do
  printf '%-24s ' "$f"
  curl -sSL -o /dev/null -w '%{http_code}  %{size_download} bytes\n' "$B/$f"
done
```

四个都该是 `200` 且字节数非零。

- 某个是 `404` → 先等几分钟再试（见下面的缓存说明）；一直 404 才是真没推上去，
  看 workflow 日志里「已推送 README.md / …」那行列了哪些文件
- 某个是 `403` → 平台拦了这类文件，把它从 `MIRROR_REPO_FILES` 去掉，
  靠 `CADDY_RAW_FALLBACK` 兜底
- 全是 `000` → 网络问题，与镜像无关

**「git push 成功」不等于「raw 读得到」。** Gitee 公开仓库的 raw 数据在服务端有
60~300 秒缓存（见响应头 `Cache-Control`）。刚被 404 过的路径，即使文件已经推上去，
也可能继续返回一段时间的 404，而且**不同文件的缓存不是同时失效的** —— 会出现
「同一次装机里 `dist/Caddyfile` 拿到了、`dist/index.html` 还是 404」这种现象。

为此有三层防护，不用手动干预：

1. `mirror.yml` 推完会**回读一遍**这几个文件，读不到就等 30 秒再试一轮，
   仍然不行则在 workflow 里打警告
2. `install.sh` 取不到时会打出 **HTTP 状态码**，而不是一句「下载失败」
3. 主源取不到就自动改用 `CADDY_RAW_FALLBACK`（默认 jsDelivr），装机不会因此失败

> `gitee.com/.../raw/...` 会 302 到 `raw.giteeusercontent.com` 的签名地址，
> 手动 `curl` 一定要带 `-L`。

`caddy-update` 在版本没变时会直接返回，**不会**重新去取 `dist/*`。只想补回欢迎页：

```bash
sudo caddy-update install --force
```

### 镜像里放了什么，没放什么

镜像端只有二进制、`.sha256`、`install.sh`、`dist/*`、一份精简 README 和 `manifest.txt`。
**不放源码、不放 `plugins.txt`、不放 `go_modules.json`、不放 GitHub 那份带插件版本表的
release notes。**

但要清楚一件事：**不同步清单只降低仓库页面的关键词可发现性，不降低产物被识别的概率。**
Go 把依赖清单写在二进制的 buildinfo 段里，`-ldflags "-w -s"` 剥不掉，
`strings caddy | grep forwardproxy` 直接命中，不需要运行它。

所以取舍的真实内容是别的：本仓库的二进制编进了 forwardproxy(naive) 和 trojan，
而 Gitee 自 2022 年 5 月起新建的开源仓库需人工审核才能公开、重新公开要提交承诺书，
腾讯云 COS、阿里云 OSS 同样要实名且内容会被扫描。风险不在于仓库被下架，
而在于把实名身份和这个产物绑定。**这条路的障碍不是技术性的**，
不同步清单帮不上忙 —— 别把「仓库里没写」当成「查不出来」。

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
    └─ Build Custom Caddy (go.mod / go.sum 变更时触发)
          go mod verify           ← 不跑 tidy，-mod=readonly 保证可复现
          go build × {amd64, arm64}
          冒烟测试：caddy version 是否与上游一致、模块数是否合理
          对比上一个 Release 的 go_modules.json 生成变更日志
          发 Release → 清理旧 Release
             └─ Mirror → Gitee / CNB / R2（各自没配就跳过，不报错）
```

只看 `go.mod` / `go.sum` 而不看 `main.go`：`main.go` 的任何实质变更都必然伴随这两者变化，
单独改 `main.go`（比如 `plugins.txt` 只调了顺序）产出的二进制是一样的，不值得重建。

每个 workflow 的详细职责、触发条件和所需 Secret 见
[`.github/workflows/README.md`](.github/workflows/README.md)。

版本号形如 `v2.11.4-20260807.1930`（Asia/Shanghai），由 `init` job 统一生成，两个架构共用同一个 tag。

编译参数与 Caddy 官方一致：`-trimpath -ldflags "-w -s" -tags nobadger,nomysql,nopgx`（排除 BadgerDB / MySQL / PostgreSQL 存储后端以缩小体积）。**刻意不注入 `CustomVersion`** —— 理由见下面「版本号」一节。`main.go` 里 import 了 `time/tzdata`，所以在没有系统时区库的精简环境下 `@` 时间匹配器一样能用。

### 仓库结构

```
plugins.txt                        ★ 插件清单，唯一需要手动编辑的文件
main.go                            自动生成，勿手改
go.mod / go.sum                    自动生成，勿手改

dist/Caddyfile                     → /etc/caddy/Caddyfile（仅当不存在时）
dist/index.html                    → /usr/share/caddy/index.html
dist/UPSTREAM.md                   同步来源与上游 commit 记录

mirror/README.md                   镜像仓库用的精简 README 模板
                                   （占位符由 mirror.yml 按平台替换）

scripts/install.sh                 安装 / 更新 / 卸载
scripts/release_notes.py           Release 正文生成
scripts/mirror-lib.sh              分发流程（平台无关），被 mirror.yml source
scripts/ci-lib.sh                  CI 共用小工具（目前只有网络重试）
scripts/bench-mirror.sh            镜像链路测速，选中转机用（不参与流水线）

.github/workflows/README.md        ★ 各 workflow 的职责与配置总览
.github/workflows/update_deps.yml  依赖解析
.github/workflows/build.yml        编译与发布
.github/workflows/sync_dist.yml    从 caddyserver/dist 同步打包资产
.github/workflows/mirror.yml       分发到 Gitee / CNB / R2（由 build.yml 调用）
.github/dependabot.yml             Actions 版本自动跟进（不管 Go 依赖）
.gitattributes                     强制 LF，防 CRLF 混入 plugins.txt
```

加一个分发平台 = 在 `mirror.yml` 里复制一个 step、实现 6 个 `platform_*` 函数，
`mirror-lib.sh` 一行都不用改。适配器契约写在 `mirror-lib.sh` 顶部。

`scripts/bench-mirror.sh` 是运维工具不是流水线的一环 —— 放在仓库里是为了版本化管理、
随手 `scp` 到候选机器上就能跑，本身不被任何 workflow 引用。

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

`/usr/share/caddy/` 同时是默认站点根目录，所以 `install.sh` 会记一份欢迎页的
sha256 到 `/etc/caddy/.welcome-sha256`：指纹对得上说明这页是脚本自己写的、
可以覆盖；对不上（你换成了自己的内容）就保留不动并提示 —— 与 Caddyfile
「已有一律不动」的处理保持一致。想换回官方欢迎页，删掉 `index.html` 再
`caddy-update` 即可。

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

镜像端也有对应的一层：重跑 `mirror.yml` 时会先核对目标版本的资产
（文件名 / 字节数 / `.sha256` 内容），齐全就跳过上传，不齐才删掉重传 ——
不会每次都白传 140 MB。

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

| 名称 | 必需 | 用途 |
| :--- | :--- | :--- |
| `PAT` | 是 | 有 `repo` 权限的 Personal Access Token。`Update Dependencies` 用它提交 —— `GITHUB_TOKEN` 的推送不会触发 `build.yml` |
| `GITEE_TOKEN` | 否 | Gitee 私人令牌，镜像用 |
| `CNB_TOKEN` | 否 | CNB 访问令牌，需 `repo-release:rw` |
| `GITEE_RELAY_KEY` | 否 | 中转机 SSH 私钥 |
| `R2_ACCESS_KEY_ID` / `R2_SECRET_ACCESS_KEY` | 否 | R2 镜像用 |

Variables：

| 名称 | 默认 | 用途 |
| :--- | :--- | :--- |
| `KEEP_RELEASES` | 12 | GitHub 保留数，脚本内置下限 3 |
| `MIN_MODULES` | 100 | 冒烟测试的模块数下限 |
| `GITEE_REPO` / `CNB_REPO` | — | 镜像仓库，形如 `owner/repo` |
| `GITEE_BRANCH` / `CNB_BRANCH` | 自动探测 | 探测不到会**报错停下**，不再猜 `main` |
| `GITEE_USER` | 取 `GITEE_REPO` 的 owner | 仓库属于组织时 owner ≠ 登录名，需显式设 |
| `GITEE_KEEP` / `CNB_KEEP` | 5 / 12 | 镜像端保留数 |
| `GITEE_ASSETS` / `CNB_ASSETS` | 全部 | 只镜像部分资产时用 |
| `GITEE_RELAY_HOST` / `_USER` / `_PORT` / `_KNOWN_HOSTS` | — | SSH 中转；不设 HOST 就直连 |
| `R2_BUCKET` / `R2_ACCOUNT_ID` / `R2_PREFIX` | — | 不设 `R2_ACCESS_KEY_ID` 则 R2 步骤整个跳过 |
| `R2_PUBLIC_BASE` | — | R2 公开域名，**可不配**：不配则只上传产物，不生成清单、不回显地址。建议放 Secrets——公开仓库的 Actions 日志会明文打印 `vars.*` |

**缺配置一律跳过、不报错**；配了却用不了（token 无效、上传失败）才会标红。
详见 [`.github/workflows/README.md`](.github/workflows/README.md) 的「容错约定」
与「什么会出现在公开日志里」。

---

## 校验与信任

每个 Release 都附带 `.sha256`，正文里也有一份。另外还发布了：

- `main.go` — 本次编译实际使用的入口文件，可以核对到底编进去了哪些插件
- `go_modules.json` — 完整依赖快照，可以核对每个模块的精确版本

安装脚本默认校验 SHA256，失败会中止。

插件都是从各自上游 `@latest` 拉的，这意味着上游一旦被投毒，下一次周五构建就会带进来。介意的话可以在 `plugins.txt` 里把版本钉死（用 `original=original@v1.2.3` 的形式）。
