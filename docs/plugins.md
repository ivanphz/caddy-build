# 插件

`plugins.txt` 是唯一真源。改一行，流水线自动解析依赖、重写 `main.go`、重新编译、
发 Release、同步到三个镜像。

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


## 怎么确认某个版本到底编进了什么

不用信文档，直接问二进制：

```bash
caddy build-info                  # 完整依赖树及版本
caddy list-modules --versions     # 已注册模块
```

每个 Release 还附带两个文件可供核对：

- `main.go` — 本次编译实际使用的入口文件
- `go_modules.json` — 完整依赖快照，含每个模块的精确版本

## 供应链

插件都是从各自上游 `@latest` 拉的，这意味着**上游一旦被投毒，下一次周五构建就会
带进来**。介意的话在 `plugins.txt` 里把版本钉死：

```
github.com/example/plugin=github.com/example/plugin@v1.2.3
```

代价是要自己盯上游更新。当前取舍是「跟新」优先——每次构建的依赖快照都发在
Release 里，出事时至少能精确定位是哪一版引入的。

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
