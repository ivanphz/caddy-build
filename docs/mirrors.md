# 镜像与分发

面向**配置分发链路的人**。三个下游平台各自独立，任何一个不配就整个跳过，
不影响其它平台，也不影响 GitHub 侧的发布。

| 平台 | 用途 | 实测上行（138 MB） |
| :--- | :--- | ---: |
| Gitee | 受限网络下载路径 | ~5.1 MB/s（经香港 SSH 中转） |
| CNB | 受限网络下载路径 | ~316 KB/s（runner 直连） |
| Cloudflare R2 | 自己可控的 CDN | ~6.4 MB/s |

每个平台需要哪些 Secret / Variable，见
[.github/workflows/README.md](../.github/workflows/README.md)——那里是唯一的配置清单，
这里只讲怎么用和怎么排障。

## 国内镜像

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

### Gitee 走 SSH 中转

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

## 选中转机：必须实测

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

### 为什么是 `aws` 命令和 `AWS_*` 变量

不是写错了。R2 对外提供的**就是 S3 协议**——Cloudflare 刻意这么做，好让现有 S3
工具链一行不改直接用。

`aws` CLI 本质是个通用 S3 客户端，`--endpoint-url` 指到
`<账户ID>.r2.cloudflarestorage.com`，它谈话的对象就是 Cloudflare，不会有任何流量
走到亚马逊。`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` 只是这个客户端读凭据用的
变量名，装进去的是 Cloudflare 生成的密钥——反过来看更清楚：Cloudflare 那个页面叫
「R2 API Tokens」，产出的东西却偏偏叫 **Access Key ID** 和 **Secret Access Key**，
就是为了直接塞进 S3 工具里。

另外两个变量：`AWS_DEFAULT_REGION=auto` 是因为 R2 没有区域概念，但 SigV4 签名串里
这个字段不能为空；两个 `*_CHECKSUM_*` 是关掉新版 aws CLI 默认加的 CRC32 校验头，
R2 不吃这套。

不用 `wrangler` 的原因：`aws` 在 ubuntu runner 上预装，`wrangler` 要装 Node 工具链
且用另一套凭据；而且 S3 是这类对象存储事实上的通用接口，以后换 OSS / COS / MinIO
适配器几乎不用改。

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
| Variable | `R2_CACHE_SECONDS` | 可选，默认 60，见下 |

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

### 缓存

接了自定义域之后，Cloudflare 边缘按对象自带的 `Cache-Control` 决定缓存多久，
所以这个头在**上传时**就写进对象元数据，分两类：

| 对象 | `Cache-Control` | 理由 |
| :--- | :--- | :--- |
| `<PREFIX>/<tag>/*` | `max-age=31536000, immutable` | 内容与 tag 绑定，永不变更 |
| `<PREFIX>/main/*`、`latest.txt` | `max-age=60` | 每次发布都变 |

后者要是缓存久了，会出现「**发了新版，`caddy-update` 却看不到**」——服务端明明
更新了，客户端读到的还是旧 `latest.txt` / `manifest.txt`。这类故障很难查，
所以宁可让它每分钟回源一次。`R2_CACHE_SECONDS` 可调。

> 只有新上传的对象带这个头。已经在桶里的旧版本产物不会被追加，
> 但它们本来就不变，没影响；而每次都会重传的 `main/*` 和 `latest.txt`
> 下一次跑就带上了。

### AccessDenied 排查

流水线开跑就会做一次预检（列举 + 写一个几字节的探针再删掉），
所以问题会在两秒内报出来，而不是传到一半才炸。

看到 `读不了存储桶` 或 `桶能读但写不了` 时，最快的定性方式是在本地直接试：

```bash
export AWS_ACCESS_KEY_ID=<你的>  AWS_SECRET_ACCESS_KEY=<你的>
export AWS_DEFAULT_REGION=auto
export AWS_REQUEST_CHECKSUM_CALCULATION=when_required
export AWS_RESPONSE_CHECKSUM_VALIDATION=when_required
E=https://<ACCOUNT_ID>.r2.cloudflarestorage.com

aws s3 ls --endpoint-url $E s3://<桶名>/            # 读
echo hi | aws s3 cp - --endpoint-url $E s3://<桶名>/_probe.txt   # 写
aws s3 rm --endpoint-url $E s3://<桶名>/_probe.txt
```

| 现象 | 原因 |
| :--- | :--- |
| 读能过、写 `AccessDenied` | 令牌权限选成了 **Object Read only**，重建一个 **Object Read & Write** 的 |
| 读就 `AccessDenied` | 桶名拼错（区分大小写）／ Account ID 是别的账户 ／ 令牌 **Specify bucket** 勾的不是这个桶 |
| `InvalidAccessKeyId` / `SignatureDoesNotMatch` | Key ID 与 Secret 不配对，多半是复制时串了行 |

> `aws s3 ls --endpoint-url $E`（不带桶名）报 `AccessDenied` 是**正常的** ——
> 那是 ListBuckets，按最小权限原则本就不该给对象级令牌。别在这上面浪费时间。

### 会不会产生费用

R2 **不收出网带宽费**（任何量级），免费额度是每月 10 GB 存储 + 100 万次 A 类操作
（写/列举）+ 1000 万次 B 类操作（读）。

按这个项目的量：保留 12 个版本约 1.7 GB 存储，离 10 GB 还远；每次发布约十几次
A 类操作。B 类操作要一千万次才碰线 —— 也就是一千万次下载。**正常用法下是 0 元。**

真正要盯的是存储：调大 `R2_KEEP` 会线性增长，每个版本约 140 MB。

## 镜像端排障

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

## 镜像里放了什么，没放什么

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
