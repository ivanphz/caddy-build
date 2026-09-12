# caddy-build

自动编译并发布带插件的 [Caddy](https://caddyserver.com) 二进制。

[![Build](https://github.com/ivanphz/caddy-build/actions/workflows/build.yml/badge.svg)](https://github.com/ivanphz/caddy-build/actions/workflows/build.yml)
[![Latest](https://img.shields.io/github/v/release/ivanphz/caddy-build)](https://github.com/ivanphz/caddy-build/releases/latest)

`plugins.txt` 是唯一真源：改一行插件清单，GitHub Actions 自动解析依赖、生成
`main.go`、编译 linux/amd64 与 linux/arm64、带 SHA256 校验和发 Release，
再分发到 Gitee、CNB 和 Cloudflare R2。

> 本仓库原名 `my-custom-caddy`。GitHub 会永久重定向旧地址（web / git / raw /
> release 资产都覆盖），已部署的机器无需处理。**但不要再新建一个叫
> `my-custom-caddy` 的仓库** —— 一旦重名，重定向会立即失效。

---

## 装

```bash
curl -fsSL https://raw.githubusercontent.com/ivanphz/caddy-build/main/scripts/install.sh | sudo bash
```

自动识别架构、校验 SHA256、创建 `caddy` 系统用户、写 systemd unit 并启动。
装完 `caddy-update` 命令就可用了。

```bash
sudo caddy-update                # 更新到最新
sudo caddy-update status         # 看当前状态
sudo caddy-update uninstall      # 卸载（保留配置与数据）
```

中国大陆建议走镜像。Gitee（**注意是 master 分支**）：

```bash
curl -fsSL https://gitee.com/ivanabc/caddy-build/raw/master/scripts/install.sh | sudo \
  CADDY_RAW_BASE=https://gitee.com/ivanabc/caddy-build/raw/master \
  CADDY_MANIFEST=https://gitee.com/ivanabc/caddy-build/raw/master/manifest.txt bash
```

CNB、R2 两条路和换源的完整说明见 [docs/install.md](docs/install.md)。

---

## 文档

| 我想…… | 看 |
| :--- | :--- |
| 装上、更新、卸载、换个下载源、日常运维 | [docs/install.md](docs/install.md) |
| 配 Gitee / CNB / R2 镜像，或排查镜像故障 | [docs/mirrors.md](docs/mirrors.md) |
| 知道编进了哪些插件，或增删插件 | [docs/plugins.md](docs/plugins.md) |
| 改这条构建流水线 | [docs/build.md](docs/build.md) |
| 搞清楚某个写法为什么是这样 | [docs/design.md](docs/design.md) |
| 用脚本消费这个仓库（舰队编排等） | [CONTRACT.md](CONTRACT.md) |
| 知道每个 workflow 干什么、要哪些 Secret | [.github/workflows/README.md](.github/workflows/README.md) |
| 看还有什么没做 | [docs/ROADMAP.md](docs/ROADMAP.md) |

---

## 这个项目解决什么

给 Caddy 加插件，要么用 `xcaddy` 自己编（每台机器都得装 Go 工具链），
要么用官网在线构建器（不可复现、不可审计）。这里把编译放进 CI 做一次，
产出带校验和、带完整依赖快照、可追溯到具体 commit 的二进制。

几个刻意的选择，理由都在 [docs/design.md](docs/design.md)：

- **`caddy version` 输出的是真正的 Caddy 版本**，与官方二进制同形。没有覆盖
  `CustomVersion`，所以任何按版本判断的脚本、文档查询都照常工作
- **安装脚本只管装 / 更新 / 卸载**，装完全是原生的 `caddy` 和 `systemctl`，没有包装层
- **更新是原子的**：下载 → 校验 SHA256 → 备份 → 原子替换 → `validate` → 重启 →
  确认存活，任一步失败自动回滚
- **分发不依赖单一平台**：GitHub、Gitee、CNB、R2 共用一套清单机制，
  任何一条路都能独立装机

---

## 已编译插件

18 个，含 `forwardproxy(naive)`、`trojan`、`caddy-l4`、`caddy-security` 等。
完整清单与版本见 [docs/plugins.md](docs/plugins.md)，或直接问二进制：

```bash
caddy build-info
```
