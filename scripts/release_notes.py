#!/usr/bin/env python3
"""
生成 Release Notes。

替代原先 build.yml 里内联的 diff_logic.py heredoc + 那段 bash/jq 表格循环。
之所以整体搬到 Python：原来的 bash 版本用 `date -d "$T +8 hours"`，而 workflow
已经设了 TZ=Asia/Shanghai，等于加了两次 8 小时。Python 用 tz-aware datetime，
不存在这个问题。

输入：
  go_modules.json       `go list -m -json all | jq -s '.'`
  prev_go_modules.json  上一个 Release 的同名产物（缺失时视为空）
  plugins.txt           插件清单
环境变量：
  CUSTOM_VERSION / BUILD_TIME / GO_VERSION
  PREV_SOURCE   对比基准的来源: ok(拿到了) / none(首次发布) / failed(有但没取到)
                旧版一律把「拿不到」当成空数组，于是一次网络抖动就会让变更日志
                把全部插件列成 Added、并吞掉 Caddy Core 升级那一行，正文却毫无提示。
输出：
  final_note.md
"""

import json
import os
import re
import sys
from datetime import datetime, timedelta, timezone

TZ_CN = timezone(timedelta(hours=8), "CST")
CADDY_CORE = "github.com/caddyserver/caddy/v2"

CURRENT_FILE = "go_modules.json"
PREVIOUS_FILE = "prev_go_modules.json"
PLUGINS_FILE = "plugins.txt"
OUTPUT_FILE = "final_note.md"

PSEUDO_RE = re.compile(r"-([0-9a-f]{12})$")


def load_modules(path):
    """把 go list -m -json 的数组读成 {原始模块路径: 已解析 replace 的信息}。"""
    try:
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, json.JSONDecodeError) as exc:
        print(f"warn: 读取 {path} 失败: {exc}", file=sys.stderr)
        return {}

    out = {}
    for item in data:
        if item.get("Main") or not item.get("Path"):
            continue
        key = item["Path"]
        src = item.get("Replace") or item
        out[key] = {
            "path": src.get("Path", key),
            "version": src.get("Version", ""),
            "time": src.get("Time", ""),
            "indirect": bool(item.get("Indirect", False)),
            "replaced": bool(item.get("Replace")),
        }
    return out


def load_tracked(path):
    """plugins.txt 里声明的模块路径（replace 行取 `=` 左边）。"""
    tracked = []
    try:
        with open(path, encoding="utf-8") as fh:
            for raw in fh:
                line = raw.replace("\r", "").strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    line = line.split("=", 1)[0].strip()
                if line != CADDY_CORE and line not in tracked:
                    tracked.append(line)
    except OSError as exc:
        print(f"warn: 读取 {path} 失败: {exc}", file=sys.stderr)
    return tracked


def short_version(version):
    """v0.0.0-20250118002110-d62c80d3dd2c -> Commit: d62c80d"""
    if not version:
        return "N/A"
    m = PSEUDO_RE.search(version)
    return f"Commit: {m.group(1)[:7]}" if m else version


def to_beijing(iso, fmt="%Y-%m-%d %H:%M:%S"):
    if not iso:
        return "N/A"
    try:
        return datetime.fromisoformat(iso.replace("Z", "+00:00")).astimezone(TZ_CN).strftime(fmt)
    except ValueError:
        return "N/A"


def build_changes(current, previous, prev_source="ok"):
    """只关心 plugins.txt 里声明的 + 直接依赖，间接依赖噪音太大。"""
    # 没有基准时，逐项对比的结果是没有意义的 —— 说清楚，不要拿一份看着正常的
    # 「全部新增」糊弄过去。
    if prev_source == "none":
        return ["- 首个 Release，没有可对比的上一版。"]
    if prev_source == "failed":
        return [
            "- ⚠️ **未能取得上一个 Release 的 `go_modules.json`**，本次无法生成变更对比。",
            "- 完整依赖快照见本 Release 附带的 `go_modules.json`，或用 `caddy build-info` 查看。",
        ]

    lines = []

    # 内核升级往往才是重新构建的真正原因，单独置顶
    cur_core = current.get(CADDY_CORE, {}).get("version", "")
    prev_core = previous.get(CADDY_CORE, {}).get("version", "")
    if prev_core and cur_core != prev_core:
        lines.append(f"- 🧱 **Caddy Core** `{prev_core}` → `{cur_core}`")

    for key in sorted(set(current) | set(previous)):
        if key == CADDY_CORE:
            continue

        cur = current.get(key)
        prev = previous.get(key)
        if not ((cur and not cur["indirect"]) or (prev and not prev["indirect"])):
            continue

        info = cur or prev
        name = "/".join(info["path"].split("/")[-2:])
        link = f"https://{info['path']}"

        if cur and prev:
            if cur["version"] != prev["version"]:
                lines.append(
                    f"- ⬆️ **Updated** [{name}]({link}) "
                    f"`{short_version(prev['version'])}` → `{short_version(cur['version'])}`"
                )
        elif cur:
            lines.append(f"- ✨ **Added** [{name}]({link}) `{short_version(cur['version'])}`")
        else:
            lines.append(f"- 🗑️ **Removed** [{name}]({link})")

    return lines or ["- 本次构建无插件变更。"]


def build_table(current, tracked):
    rows = [
        "| Plugin | Version | Last Commit (Beijing) |",
        "| :--- | :--- | :--- |",
    ]
    for key in tracked:
        info = current.get(key)
        if not info:
            rows.append(f"| `{key}` | ⚠️ 未出现在 go.mod | N/A |")
            continue
        name = info["path"].split("/", 1)[-1]          # github.com/mholt/caddy-l4 -> mholt/caddy-l4
        mark = " 🔀" if info["replaced"] else ""
        rows.append(
            f"| [{name}](https://{info['path']}){mark} "
            f"| `{short_version(info['version'])}` "
            f"| {to_beijing(info['time'])} |"
        )
    return rows


def main():
    current = load_modules(CURRENT_FILE)
    if not current:
        sys.exit(f"error: {CURRENT_FILE} 为空或无法解析")
    previous = load_modules(PREVIOUS_FILE)
    tracked = load_tracked(PLUGINS_FILE)

    core = current.get(CADDY_CORE, {})
    version = os.environ.get("CUSTOM_VERSION", "dev")
    prev_source = os.environ.get("PREV_SOURCE", "ok")
    if prev_source not in ("ok", "none", "failed"):
        print(f"warn: 未知 PREV_SOURCE={prev_source!r}，按 ok 处理", file=sys.stderr)
        prev_source = "ok"
    # 基准文件存在但解析不出内容，等同于没取到
    if prev_source == "ok" and not previous:
        prev_source = "failed"

    out = [
        f"# {version}",
        "",
        "### 🚀 Build Info",
        f"- **Release Tag**: `{version}`",
        f"- **Caddy Core**: `{core.get('version', 'unknown')}` "
        f"— 即 `caddy version` 的输出，与官方二进制同形",
        f"- **Go Version**: `{os.environ.get('GO_VERSION', 'unknown')}`",
        f"- **Plugins Count**: {len(tracked)}",
        f"- **Build Time**: {os.environ.get('BUILD_TIME', 'unknown')}",
        "",
        "### 📦 Plugin Changes",
        *build_changes(current, previous, prev_source),
        "",
        "### 🔌 Installed Plugins Status",
        *build_table(current, tracked),
        "",
    ]

    with open(OUTPUT_FILE, "w", encoding="utf-8") as fh:
        fh.write("\n".join(out))
    print("\n".join(out))


if __name__ == "__main__":
    main()
