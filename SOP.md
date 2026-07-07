# whicc 发布 SOP（Standard Operating Procedure）

> 给其他 AI agent / 未来忘了细节的人读。按这个文件做发布，可以避开我已经踩过的 6 次连续 release build 失败。
>
> 适用范围：从 `main` 上发布一个稳定版本（e.g. `v0.2.0`），自动 build + 上传 `.app.zip` 到 GitHub Releases。

---

## 概览

```
preflight  →  bump version  →  update docs  →  tag  →  push tag  →  watch CI
   ↓             ↓              ↓             ↓         ↓            ↓
 检查状态    更新 release     写 release     git tag  force-push   验证 artifact
             notes           notes          v0.X.0   (重置)        成功
```

整个流程约 30 分钟（其中 5-10 分钟等 CI 完成 + 验证）。

---

## Step 0: 准备（5 min）

### 0.1 检查环境

```bash
cd /Users/tengzhe/Desktop/systemcc/whicc
git status
git log -1 --format="%h %s"
git remote -v   # 确认 origin 指向 nbzz/whicc
git tag -l | sort -V | tail -5   # 看最近的 tag
```

**期望**：
- `git status` clean
- HEAD 在 `main`（不要在 feature branch 发布）
- origin 指向 `git@github.com:nbzz/whicc.git`（SSH）或 `https://github.com/nbzz/whicc.git`（PAT）
- 最近 tag 例如 `v0.0.x` 或 `v0.1.0`

### 0.2 跑本地 CI 模拟

发布前本地先验证一次（不是必须，但强烈建议）：

```bash
# 跑和 ci.yml 一样的步骤
xcodegen generate --spec project.yml --project .
xcodebuild -project whicc.xcodeproj -scheme whicc -configuration Release \
  -derivedDataPath build clean build 2>&1 | tail -3
# 期望最后一行: ** BUILD SUCCEEDED **
```

如果本地 build 失败，**先修代码再发布**。

### 0.3 检查 CI 当前状态

```bash
# 拿最近 1 个 commit 的 CI 状态
curl -s "https://api.github.com/repos/nbzz/whicc/commits/$(git rev-parse HEAD)/status" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print('CI state:', d.get('state'))"
```

**期望**：`success`。如果 `pending` / `failure` / `null`，等 CI 跑完或先修。

---

## Step 1: 决定版本号（2 min）

whicc 用 [Semantic Versioning](https://semver.org/)：

```
MAJOR.MINOR.PATCH
```

| 类型 | 何时 | 例 |
|---|---|---|
| PATCH (z++) | Bug 修复，文档小改 | `0.1.0 → 0.1.1` |
| MINOR (y++) | 新功能，向后兼容 | `0.1.0 → 0.2.0` |
| MAJOR (x++) | 破坏性变更 | `0.x.y → 1.0.0` |

**当前版本是 `0.1.0`**（首次公开 release）。下一个 release 多数情况应该是 `0.2.0` 或 `0.1.1`。

写下来你要发布的版本，例如：
```bash
export RELEASE_VERSION="0.2.0"
```

---

## Step 2: 更新文档（5-10 min）

发布版本要改几个地方让代码内外一致：

### 2.1 更新 `DEVELOPMENT.md` 的「本地化与翻译」章节（如有变化）

不需要每次都改，但发布前确认 `macOS 26+` / `Python 3.13` 等版本要求还正确。

### 2.2 更新 `README.md` 的「路线图」section

把 v0.1.0 / v0.2.0 已做的项目移到「已完成」，加新项目。

### 2.3 写 release notes

在 `DEVELOPMENT.md` 末尾或单独的 `RELEASES.md` 加：

```markdown
# v0.2.0 — YYYY-MM-DD

## 主要变更

- 新功能 X
- Bug 修复 Y
- 文档改进 Z

## 安装

下载 `whicc-v0.2.0.app.zip`...
```

或者在 GitHub Release 自动生成（release.yml 用了 `generate_release_notes: true` —— 它会从 tag 之间 merged PR 自动整理）。

### 2.4 验证 git 状态

```bash
git status
git diff --stat   # 确认改动是预期的
```

---

## Step 3: Commit + tag（5 min）

### 3.1 提交文档改动

```bash
git add DEVELOPMENT.md README.md  # 改的文件
git -c user.name=cyberteng -c user.email=tengzhe@aliyun.com commit -m "docs: prepare v0.2.0 release"
git push origin main
```

如果 push 触发 CI，等 CI 跑完确认绿。

### 3.2 创建 tag

```bash
# 删旧 tag (如果重新定位 v0.X.0)
git tag -d $RELEASE_VERSION
git tag -a $RELEASE_VERSION -m "$RELEASE_VERSION — release title"

# 推到 GitHub
git push origin :refs/tags/$RELEASE_VERSION 2>&1 | tail -1   # 删 remote
git push origin $RELEASE_VERSION
```

`git push origin :refs/tags/...` 用来清掉 remote 上旧的同名 tag（如果有的话）。GitHub 不允许覆盖 tag。

**自动触发 `.github/workflows/release.yml`**，CI 跑 5-10 分钟。

---

## Step 4: 监控 CI（5-10 min）

```bash
# 找最近 release workflow run
RUN_ID=$(curl -s "https://api.github.com/repos/nbzz/whicc/actions/runs?per_page=1" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['workflow_runs'][0]['id'])")
echo "Run: https://github.com/nbzz/whicc/actions/runs/$RUN_ID"

# 轮询直到完成
for i in 1 2 3 4 5 6 7 8 9 10 11 12; do
  s=$(curl -s "https://api.github.com/repos/nbzz/whicc/actions/runs/$RUN_ID" \
    | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'{d[\"status\"]}|{d.get(\"conclusion\") or \"-\"}')")
  echo "[$(date +%H:%M:%S)] iter $i: $s"
  case "$s" in
    "completed|success") echo "✓ release green"; break ;;
    "completed|failure") echo "✗ release FAILED — see Troubleshooting"; break ;;
  esac
  sleep 30
done
```

**期望**：`completed|success` 在 5-10 分钟内。

---

## Step 5: 验证产物（3 min）

### 5.1 验证 GitHub Release 存在

```bash
curl -s "https://api.github.com/repos/nbzz/whicc/releases/tags/$RELEASE_VERSION" \
  | python3 -c "import json,sys; d=json.load(sys.stdin); print(f'tag: {d[\"tag_name\"]}, assets: {len(d[\"assets\"])}')"
```

**期望**：`tag: v0.2.0, assets: 2`（zip + SHA256SUMS）

### 5.2 验证 zip 大小合理

```bash
curl -s "https://api.github.com/repos/nbzz/whicc/releases/tags/$RELEASE_VERSION" \
  | python3 -c "
import json, sys
d = json.load(sys.stdin)
for a in d['assets']:
    print(f'  {a[\"name\"]:30}  {a[\"size\"]/1024/1024:.1f} MB')
"
```

**期望**：`whicc-v0.2.0.app.zip` ~150-200 MB

### 5.3 验证 SHA256 校验和有效

```bash
curl -s "https://api.github.com/repos/nbzz/whicc/releases/tags/$RELEASE_VERSION" \
  | python3 -c "
import json, sys, hashlib, urllib.request
d = json.load(sys.stdin)
zip_url = next(a['browser_download_url'] for a in d['assets'] if a['name'].endswith('.zip'))
zip_bytes = urllib.request.urlopen(zip_url).read()
actual = hashlib.sha256(zip_bytes).hexdigest()
print(f'downloaded {len(zip_bytes)/1024/1024:.1f} MB')
print(f'expected:   {next((a[\"digest\"] for a in d[\"assets\"] if a[\"name\"].endswith(\".zip\")), \"N/A\")}')
print(f'computed:   sha256:{actual}')
"
```

期望两个 hex 匹配。

---

## Step 6: 通知（1 min）

告诉用户/团队：
- Release URL: `https://github.com/nbzz/whicc/releases/tag/<version>`
- 关键变更（changelog link）
- 安装步骤（README 安装 section）

---

## Troubleshooting

### release build 失败：`error: cannot find 'X' in scope`

**原因**：macos-15 runner 默认 Xcode 16.4 + macOS 15.5 SDK。如果代码用了 macOS 26 专属 SwiftUI API（如 `GlassEffectContainer`、`NavigationLink` 新签名等），找不到 symbol。

**修复**（已在 release.yml 里加好，不用再改）：`Setup Xcode 26` + `sudo xcode-select` step。**重要**：

- **同时**要有 `maxim-lobanov/setup-xcode@v1` (装 Xcode 26)
- **同时**要有 `xcode-select -s /Applications/Xcode_26.0.app` (切默认)

如果只装不切，build 仍用 Xcode 16.4。

### release build 失败：但 CI build 绿

**原因**：release.yml 跟 ci.yml 步 骤可能漂移。每次改 ci.yml 时也要同步 release.yml。

**调试**：
1. 看 release workflow 哪个 step fail
2. 去 `https://github.com/nbzz/whicc/actions/runs/<run_id>` 页面 artifacts 区
3. 下载 `xcodebuild-log` + `env-snapshot` artifact
4. 看真实错误

**诊断 tips**：
- exit code 65 = xcodebuild 编译错误
- exit code 1 = preBuildScript 失败（cp venv/ 之类）
- 错误信息里的 `/Applications/Xcode_16.4.app/...` 表示 xcode-select 没切到 26

### brew tap warnings（`aws/tap` not trusted）

**原因**：macos-15 runner 上 `brew install` 被 Homebrew 限制。

**影响**：⚠️ **warning**，**不阻塞** build。xcodegen 装好就够。

**如果真因为 brew 失败导致 install xcodegen 失败**：加 step `export HOMEBREW_NO_REQUIRE_TAP_TRUST=1` 到 release.yml。

### artifact 下载 401

GitHub artifact zip API 在 2023 后强制需要 auth（即使对 public repo 的 public artifacts）。但 artifacts **本身** 在 GitHub UI 上能直接下载。

**绕开**：CI workflow 已加 `Upload env snapshot` + `Upload xcodebuild log on failure` 让诊断信息可下载。

### `git push origin v0.X.0` 没触发 release workflow

**原因**：
1. tag 名字不对（必须是 `v*` 模式匹配 release.yml 的 `tags: 'v*'`）
2. workflow file 在 tag 提交时使用 **tag commit 时** 的 version，不是 push 时

**修复**：检查 `.github/workflows/release.yml` 的 `on.push.tags` filter。

### contributors tab 显示 "claude" / "tengzhe"

**原因**：GitHub 异步 stats 计算。force-push 后 stats 缓存可能 1-24 小时才更新。

**这是 stale cache**。当前 contributors tab 显示什么不重要：
- 检查真源：去 https://github.com/nbzz/whicc/commits/main 看 commits
- 如果每个 commit author 都是 `cyberteng <tengzhe@aliyun.com>`，数据是对的
- contributors tab 会自己刷新

**如果真要立刻修**：用 `git filter-repo` 重写 author + `git push --force`（跟 0.1.0 第一次发布前一样）。

---

## CI Workflow 维护

`.github/workflows/ci.yml` 和 `.github/workflows/release.yml` 应该**完全一致**到 build 步骤。改 ci.yml 时一定要同步 release.yml。

**自动同步方案（未来）**：抽 composite action 复用 build 步骤。当前没用是为了简单。

**Sanity check 脚本**（在 PR 改动时跑）：
```bash
# Compare ci.yml and release.yml build steps
diff <(awk '/Build whicc/,/clean build/{print}' .github/workflows/ci.yml) \
     <(awk '/Build whicc/,/clean build/{print}' .github/workflows/release.yml)
```

如果输出非空，说明两份配置漂移了。

---

## 发布后工作

1. **告诉用户/团队**：附上 release URL + 主要变更
2. **更新 README badge**：如果 CI status 变化（一般不会），badge 自动更新
3. **下一个 milestone planning**：发完版后想下个版本的 roadmap

---

## 一些历史踩坑（避免重复）

### 6 次连续 release build 失败（v0.1.0 准备时）

1. CI 镜像默认 Xcode 16，缺 macOS 26 SDK → 加 `Setup Xcode 26` step
2. release.yml 没装 Xcode 26（只有 ci.yml 有）→ 把 step 复制到 release.yml
3. xcode-select 没切到 26 → 加 `sudo xcode-select -s /Applications/Xcode_26.0.app`
4. tag 推到老 commit（filter-repo 重写后） → 用 `git push origin :refs/tags/X` + `git push origin X --force` 重新定位
5. force-push 后 contributors tab 显示陌生人 → wait, GitHub cache 异步重算
6. local build 绿但 CI fail → 多数情况是 release.yml 缺关键 step

### Author email 暴露个人地址

我之前用 `whicc@local` placeholder，filter-repo 用 mailmap 改成 `cyberteng <tengzhe@aliyun.com>`。**以后 commit 用真邮箱** (避免再 filter-repo 一次)：

```bash
git config user.name "cyberteng"
git config user.email "tengzhe@aliyun.com"
# 局部仓库 (项目级)
git config --local user.name "cyberteng"
git config --local user.email "tengzhe@aliyun.com"
```

### demo.mov 在仓库里 (13 MB)

用户偏好默认仓库（不像做 .gitignore 排除）— 当前 demo.mov 在 git 里。发布不影响。但 git clone 时间会稍长（一次性的）。

---

## 紧急操作

### Release 后发现严重 bug，要快速撤回

```bash
# 1. 删除 GitHub Release (UI: Releases → v0.2.0 → Delete)
# 2. 删除 tag
git push origin :refs/tags/v0.2.0
git tag -d v0.2.0
# 3. 在 main 上发 hotfix commit
# 4. 发 v0.2.1
```

### 误推了错的 tag

```bash
# 删 tag
git push origin :refs/tags/<wrong-tag>
git tag -d <wrong-tag>
# 重新打
git tag -a <correct-tag> -m "..."
git push origin <correct-tag>
```

### GitHub UI 显示 `claude` contributor

这是 cache 问题。等 1-24 小时。期间：
- 数据真源（commits API）已经是 `cyberteng`
- 不需要 force-push
- 不要删库重建（cache 仍会显示错）
- 如果真急了，发 git filter-repo 改写 author + force-push（但 cache 仍会保留一段时间）

---

## 联系

- 仓库: https://github.com/nbzz/whicc
- 文档: [DEVELOPMENT.md](DEVELOPMENT.md) / [README.md](README.md)
- CI / release workflow 调试日志: [GitHub Actions](https://github.com/nbzz/whicc/actions)
- 历史踩坑: 本文末尾"一些历史踩坑"section

---

> Last updated: 2026-07-07, after 6-failure release debugging of v0.1.0.
> Maintainer: cyberteng <tengzhe@aliyun.com>
