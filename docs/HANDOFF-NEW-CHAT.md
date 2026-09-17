# 新开对话交接 —— caddy-build

> **新开对话时把这一份整份贴进去**，再说这一轮要做什么。
> 它是上下文引子，不是规范：契约以 [`CONTRACT.md`](../CONTRACT.md) 为准，
> 坑以 [`TRAPS.md`](TRAPS.md) 为准，待办以 [`ROADMAP.md`](ROADMAP.md) 为准。
>
> **每轮结束时更新第 3 节。** 状态会过期，而过期状态最危险的形态是「看起来像待办」——
> 作废的说法写成否定句留着，比直接删掉更能拦住下一个人。

---

## 1. 这个仓库是什么

公开仓库 `ivanphz/caddy-build`：`plugins.txt` → 编译 Caddy（18 个插件，amd64 / arm64）
→ GitHub Release（SHA256 + `manifest.txt`）→ `mirror.yml` 分发到 Gitee / CNB / R2。

在整套体系里它是**生产方**，只管单组件构建和单品自测，失败就不发版：

| 谁 | 和本仓库的关系 |
| :--- | :--- |
| swage（私有） | 按 `CONTRACT.md` 消费产物，部署到舰队 |
| assay（公开） | 无鉴权读本仓库的 Release，做跨组件编组测试 |
| 私有分发库（草稿名 dray） | 将来接走国内分发，**轮询**本仓库 |

两条方向规则：

- **本仓库的 workflow 里不出现任何私有库的 owner/repo**，不持有它们的凭据，
  不向它们 dispatch。私有库来读这里，反过来不成立
- **下游仓库的内部进度不写进这里。** 别的仓库卡在哪一步、任务编号是多少，
  与本仓库无关 —— 上一版交接就是因为夹带了下游进度才过期的（见第 3 节）

---

## 2. 动手之前

- **扫一眼 [`TRAPS.md`](TRAPS.md)**：9 条，都在这个仓库里真实出现过
- **只交付真正改过的文件**，不整仓覆盖（第 7 条：会悄悄回退 Dependabot）。
  覆盖 workflow 前先 `grep -rn "uses:" .github/workflows/`，版本以 `main` 为准
- **模拟 workflow step 用 `env -i`**，只放 YAML 里声明的变量（第 9 条）
- 约束写进代码，不写在交付说明里（第 8 条）

`selftest.yml` 里三道自动检查，改完都应该是绿的：

| 检查 | 命令 | 当前 |
| :--- | :--- | :--- |
| 契约自测 | `bash scripts/contract-selftest.sh` | 20 / 20 |
| 自测会不会红（变异） | `bash scripts/contract-mutation-check.sh` | 4 / 4 |
| workflow env 作用域 | `python3 scripts/lint-workflow-env.py`（自证：`--selftest`） | 0 处 |

---

## 3. 当前状态（2026-09-16）

### 合并状态

`main` 已包含：

- 自测 flaky 修复（`printf | grep -q` → here-string）。复核：连跑 100 轮 0 假红；
  对照组改回旧写法，120 轮红 2 次 —— 说明这个循环抓得到它
- `docs/TRAPS.md`、`install_sh` 钉 tag 断言、`selftest.yml`
- **`build.yml` 发版校验步骤补上自己的 `TAG`。** 在此之前那条钉 tag 断言引用的是
  另一个 step 的 env，下一次发版必红，而且红在 Release 发出之后（`mirror` 不会跑）
- `scripts/lint-workflow-env.py`，挂在 `selftest.yml` 里

**探针**（交接文件会比代码先到，别凭印象）：

```bash
python3 scripts/lint-workflow-env.py
#   文件不存在                 → 上面最后两项没合
#   报出 build.yml 的 $TAG     → 只合了一半（build.yml 没覆盖上）
#   「没有跨 step 失效的变量引用」→ 合好了
```

没有本地环境时看 Actions → Contract Selftest 的最近一次运行：
有 `workflow-env` 这个 job 且是绿的，等价于上面第三种结果。

### 作废的说法 —— 不是待办

- **「swage 卡在 P1-1（swage-agent 用代理 token 推权威仓库 403）」—— 作废。**
  swage-agent 已否决并删除。这件事从来不归本仓库管，也不构成本仓库的任何待办
- **「钉 tag 断言实测过：钉了 tag 通过、退回分支拦下」—— 不作数。**
  那次模拟手工 export 了 `TAG`，恰好盖住了作用域问题。真实 runner 上的结果见第 4 节第 1 项

### 已经定了，不要重新讨论

- 保持**公开构建 + 公开 Release**（assay 无鉴权读取的前提）
- `manifest.txt` 的格式与 `CONTRACT.md`（`contract=1`）不因分发迁移而改变
- 国内分发迁往私有分发库，顺序是**先切消费方、后删 `mirror.yml`**，
  反过来墙内节点会在下一次发版时静默断更。影响范围见 `ROADMAP.md` 顶部；
  完整步骤见 assay 设计包里的 `caddy-build/docs/ASSAY-INTEGRATION.md`

---

## 4. 下一轮起点

| 顺序 | 事 | 为什么 |
| :--- | :--- | :--- |
| 1 | 下一次发版后，看 release job 的「Verify manifest install_sh is reachable」 | 这条断言还没在真实 runner 上跑过，绿了才算成立。报「取不到」多半是 raw 的传播窗口（已自动重试 6 次、约 1 分钟）；报「TAG 为空」或 unbound variable 是 env 没传到。红了之后 `mirror` 不会跑，修好后到 Actions → Mirror → Run workflow 手动补发（tag 留空 = 最新） |
| 2 | 合入 `docs/ASSAY-INTEGRATION.md`，做其中第一件：Release 附带 `selftest.json` | 约半小时；assay 靠它区分「CI 正式发布」和「手工上传」 |
| 3 | ROADMAP #1 架构名单一真源 | 加架构时才痛，不急 |
| 暂缓 | ROADMAP #2 transport 层、#6 测速支持 R2 | 服务端部分归迁移后的分发库，在这里做等于改要删的代码。#2 的客户端部分（`install.sh` 命名源）不受影响 |
| 暂缓 | ROADMAP #4 Docker | 本仓库只做 GHCR；国内 registry 归分发库 |
