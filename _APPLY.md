# 应用说明

**本包只含本轮真正改动过的 5 个文件。** 上一版把没改的文件也一并覆盖，
结果把你合并的 Dependabot 升级打回了旧版本 —— 见 docs/ROADMAP.md 第 8 条。

```
scripts/mirror-lib.sh          修 manifest 被误判 soft404（真 bug）
scripts/bench-mirror.sh        用法示例去掉具体仓库名
docs/ROADMAP.md                新增第 2、3、8 条
.github/workflows/build.yml    ⚠ 见下
.github/workflows/mirror.yml   ⚠ 见下
```

## ⚠ 两个工作流文件：覆盖前先对版本

这两个文件 Dependabot 也会改。本包里的 `uses:` 版本是按你已合并的
Dependabot PR 对齐的：

```
actions/checkout@v7
actions/setup-go@v7
actions/upload-artifact@v7
actions/download-artifact@v8
softprops/action-gh-release@v3
```

覆盖之前，先看一眼 main 上现在是什么：

```bash
grep -rn "uses: actions\|uses: softprops" .github/workflows/*.yml
```

**对不上就以 main 为准**，只把下面这一步手工贴进 build.yml 的 release job
（在 `Generate Manifest` 之前）：

```yaml
      - name: Verify Artifact Layout
        run: |
          set -euo pipefail
          echo "--- 实际结构 ---"; find artifacts -maxdepth 2 | sort
          miss=""
          for d in caddy-amd64 caddy-arm64 metadata; do
            [ -d "artifacts/${d}" ] || miss="${miss} artifacts/${d}"
          done
          for f in metadata/manifest_head.txt metadata/final_note.md; do
            [ -f "artifacts/${f}" ] || miss="${miss} artifacts/${f}"
          done
          [ -z "$miss" ] || {
            echo "::error::产物结构不符合预期，缺:${miss}。多半是 download-artifact 大版本升级改了落盘路径。"
            exit 1; }
          echo "✓ 结构正确"
```

mirror.yml 里除了版本号，本轮唯一改动是把注释里的示例仓库名换成
`<owner>/caddy-build`，纯文案，可以不覆盖。
