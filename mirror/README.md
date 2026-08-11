# caddy-build

带插件编译的 [Caddy](https://caddyserver.com) 二进制，{{PLATFORM}} 镜像。

> 本仓库由流水线自动同步，**请勿直接修改** —— 下次同步会被覆盖。
> 当前版本 `{{TAG}}`。

---

## 安装

```bash
curl -fsSL {{RAW_BASE}}/scripts/install.sh | sudo \
  CADDY_RAW_BASE={{RAW_BASE}} \
  CADDY_REL_BASE={{REL_BASE}} bash
```

脚本会自动识别架构、校验 SHA256、创建 `caddy` 系统用户、写入 systemd unit 并启动服务。
装完之后 `caddy-update` 命令就可用了。

## 更新

```bash
sudo caddy-update
```

安装时的下载来源会固化进 `/usr/local/bin/caddy-update`，之后每次更新自动沿用本镜像，
不必重复设环境变量。

## 其它命令

```bash
sudo caddy-update status      # 当前版本 / 最新版本 / 服务状态
sudo caddy-update uninstall   # 卸载二进制和服务（保留配置与数据）
sudo NO_SERVICE=1 caddy-update  # 只更新二进制，不碰 systemd
```

## 手动下载

| 架构 | 文件 |
| :--- | :--- |
| amd64 | [`caddy-linux-amd64`]({{REL_BASE}}/{{TAG}}/caddy-linux-amd64) |
| arm64 | [`caddy-linux-arm64`]({{REL_BASE}}/{{TAG}}/caddy-linux-arm64) |

每个文件都附带同名 `.sha256`，安装前请校验：

```bash
ARCH=amd64   # 或 arm64
curl -fLO {{REL_BASE}}/{{TAG}}/caddy-linux-$ARCH
curl -fLO {{REL_BASE}}/{{TAG}}/caddy-linux-$ARCH.sha256
sha256sum -c caddy-linux-$ARCH.sha256

sudo install -m 0755 caddy-linux-$ARCH /usr/local/bin/caddy
caddy version
```

> 覆盖正在运行的可执行文件会报 `Text file busy`。更新时先写临时名再 `mv`
> （`mv` 是 rename，对运行中的进程安全）：
> ```bash
> sudo install -m 0755 caddy-linux-$ARCH /usr/local/bin/caddy.new
> sudo mv -f /usr/local/bin/caddy.new /usr/local/bin/caddy
> sudo systemctl restart caddy
> ```

---

## 说明

`caddy version` 输出的是**真正的 Caddy 版本**，与官方二进制同形 —— 构建时没有覆盖
`CustomVersion`，所以任何按 Caddy 版本做判断的脚本、文档查询都能正常工作。

查看这个二进制里编进了什么：

```bash
caddy build-info                  # 完整依赖树及版本
caddy list-modules --versions     # 已注册模块
```

日常操作全部是原生的 `caddy` 和 `systemctl` 命令，本项目不提供任何包装层。

- `apt upgrade` **更新不了它** —— 二进制在 `/usr/local/bin/caddy`，不是 .deb 包
- 不要用 `caddy upgrade` / `caddy add-package` —— 它们会从 caddyserver.com 重新下载
  二进制并原地替换，绕过整条构建流水线
- 如果机器上装过官方 caddy apt 包，建议 `sudo apt remove caddy` 或
  `sudo apt-mark hold caddy`，避免两者长期打架

| 路径 | 用途 |
| :--- | :--- |
| `/usr/local/bin/caddy` | 二进制 |
| `/etc/caddy/Caddyfile` | 配置 |
| `/usr/share/caddy/` | 站点根目录 |
| `/var/lib/caddy` | 证书与状态 |
| `/etc/systemd/system/caddy.service` | 服务定义 |
