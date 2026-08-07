# 本地打包安装指南（不经过 CI/CD）

本分支的正式发布走 GitHub Actions：`make bump-and-release` 打 tag 后由
`.github/workflows/main.yml` 完成签名、公证、DMG/appcast 发布。当只想把当前代码
打包装到本机 `/Applications` 用，不触发任何 CI/CD release 时，按本文操作。

> 适用场景：在改完代码之后想用最新构建替换本机的 Supacode，又不想打 tag / 推送
> 触发 release 流水线。

## 使用方式：一条命令

本文的全部步骤已经封装成 `scripts/install-local.sh`，在仓库根目录直接运行即可：

```bash
./scripts/install-local.sh
```

脚本会自动完成：前置检查 → 构建未签名 Release 归档 → 本地签名 → 验证签名 →
替换 `/Applications` → 启动冒烟验证 → 恢复构建污染的 workspace 文件。

支持选项：

| 选项 | 说明 |
| --- | --- |
| `--no-build` | 不重新构建，直接复用 `build/supacode.xcarchive` 重新签名安装 |
| `--no-launch` | 装完不启动 App（跳过启动验证） |
| `--no-cleanup` | 不执行 `git checkout -- Tuist/Package.resolved supacode.json`（见下文收尾） |
| `-h` / `--help` | 查看帮助 |

## 前置条件

- `mise install` 已装好工具链；`make doctor` 无失败项（脚本会先跑 `doctor.sh --quiet`
  做同样的检查）
- 子模块已初始化（`git submodule update --init --recursive`）
- 本机 keychain 有可用的 Apple Development codesigning identity：

```bash
security find-identity -v -p codesigning
# 期望至少有一条，比如:
#   1) E677E0F3CBBE808EC54E923A4D163DB5EB910AFF "Apple Development: ..."
```

> 本机没有 Developer ID 证书，只有 Apple Development 证书。以下步骤用
> Apple Development 证书本地签名，**未公证（notarization）**，只保证本机能跑，
> 不能分发给别人。对外分发仍必须走 CI/CD。

## 脚本做了什么（对照手动流程）

1. **构建 Release 归档（不签名）**：`make archive XCODEBUILD_FLAGS="CODE_SIGNING_ALLOWED=NO
   CODE_SIGNING_REQUIRED=NO"`。`make archive` 原本按 Manual + Developer ID 签名，
   本机没有 `APPLE_TEAM_ID` / `DEVELOPER_ID_IDENTITY_SHA`，必须用这个 flag 跳过，
   否则归档失败。会重新生成 Release 配置的 workspace 并清空 DerivedData。
   产物：`build/supacode.xcarchive/Products/Applications/supacode.app`。
2. **本地签名**：取 keychain 里第一条 Apple Development identity 的 SHA，按
   最深的嵌套代码先签、最后签主 App 的顺序签名，并给主 App 注入
   `supacode/supacode.entitlements`（Release entitlements）。
3. **验证签名**：`codesign --verify --deep --strict`；`spctl -a` 会被
   rejected，这是预期（本地证书 + 未公证）。
4. **替换 `/Applications`**：先退出正在运行的 supacode，再 `ditto` 拷入。
5. **启动验证**：`open -a` 后确认进程存活。
6. **收尾清理**：`git checkout -- Tuist/Package.resolved supacode.json`，
   恢复 `tuist install` 与启动 App 造成的构建副作用。

## 发布到 GitHub Releases（不走 CI/CD）

适用场景：除了装到本机，还想把本地构建挂到 GitHub Releases 上（比如在另一台机器上下载，
或分享给同事）。同样不触发 CI/CD release。注意：该构建仍是本机 Apple Development
证书签名 + **未公证**，其它 Mac 打开会被 Gatekeeper 拦（右键“打开”可绕过）。

### 一步执行

先确保已跑过 `./scripts/install-local.sh`（或至少构建并签名了
`build/supacode.xcarchive`），然后：

```bash
./scripts/publish-local.sh
```

脚本会：把签名后的 App 打成 `supacode.app.zip` 和 `supacode.dmg`（create-dmg），
生成 `checksums.json`（与 CI 上传同格式），用 GitHub API 自动生成 release notes，
然后在 `origin` 远端创建（或更新）tag 为 `v<MARKETING_VERSION>` 的 release 并上传三个产物。

支持选项：

| 选项 | 说明 |
| --- | --- |
| `--repo owner/repo` | 发布到指定仓库（默认取 `origin` remote 对应的仓库，即你的 fork） |
| `--tag NAME` | 自定义 tag（默认取 `Configurations/Project.xcconfig` 的 `MARKETING_VERSION`，即当前分支版本） |
| `--target SHA` | release 指向的 commit（默认本地 HEAD；commit 必须已推到目标仓库） |
| `--draft` / `--prerelease` | 创建草稿 / 预发布 |
| `--dry-run` | 只打包产物并打印将执行的 gh 命令，不上传 |

## 为什么签这些

`.github/scripts/resign_exported_app.sh` 对 Frameworks/PlugIns/Resources/
XPCServices/LoginItems 下所有 `*.app|*.appex|*.framework|*.xpc|*.dylib|可执行文件`
从深到浅重新签名。但未签名归档没有可保留的 entitlement 元数据，所以主 App
改用 `--entitlements` 显式注入。`Resources/git-wt/wt` 是 bash 脚本，不需要签
（由主 App 的 seal 覆盖）。

## 注意

- **发布流程不会触发 CI**：脚本不创建本地 tag、不 push 任何东西，`gh release create`
  只在远端建 tag。请**不要**手动 `git push` 这个 tag 或 main 分支，否则 `main.yml`
  会接管并重新走 CI/CD 发布。
- **前置条件**：本地已签名归档（`scripts/install-local.sh`）、`gh` 已登录（`gh auth login`）、
  `mise install` 装好 `npm:create-dmg`（`create-dmg` 报缺模块时
  `mise uninstall -y npm:create-dmg && mise install npm:create-dmg` 重装）。
- 发布不带 Sparkle `appcast.xml` 和 delta（本地没有 Sparkle 私钥），所以 Sparkle
  不会自动检测到更新，需要手动下载安装。
- 发布产物未公证：`spctl` 拒绝；首次在其它 Mac 上打开会被 Gatekeeper 拦，右键“打开”。
- `git checkout -- Tuist/Package.resolved supacode.json` 会丢弃这两个文件里的
  未提交改动；如有想保留的改动，先跑 `--no-cleanup` 再手动恢复。
- 不要 push tag、不要 `make bump-and-release`。
- Sparkle 自动更新通道仍指向正式 release，本地装的不影响。