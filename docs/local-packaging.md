# 本地打包安装指南（不经过 CI/CD）

本分支的正式发布走 GitHub Actions：`make bump-and-release` 打 tag 后由
`.github/workflows/main.yml` 完成签名、公证、DMG/appcast 发布。当只想把当前代码
打包装到本机 `/Applications` 用，不触发任何 CI/CD release 时，按本文操作。

> 适用场景：在改完代码之后想用最新构建替换本机的 Supacode，又不想打 tag / 推送
> 触发 release 流水线。

## 前置条件

- `mise install` 已装好工具链；`make doctor` 无失败项
- 子模块已初始化（`git submodule update --init --recursive`）
- 本机 keychain 有可用的 codesigning identity：

```bash
security find-identity -v -p codesigning
# 期望至少有一条，比如:
#   1) E677E0F3CBBE808EC54E923A4D163DB5EB910AFF "Apple Development: ..."
```

> 本机没有 Developer ID 证书，只有 Apple Development 证书。以下步骤用
> Apple Development 证书本地签名，**未公证（notarization）**，只保证本机能跑，
> 不能分发给别人。对外分发仍必须走 CI/CD。

## 步骤一：构建 Release 归档（不签名）

`make archive` 默认按 Manual + Developer ID 签名；传入
`CODE_SIGNING_ALLOWED=NO` 跳过签名（签名在归档后手动补）：

```bash
make archive XCODEBUILD_FLAGS="CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO"
```

会重新生成 Release 配置的 workspace 并清空 DerivedData，首次编译较久。
产物：`build/supacode.xcarchive/Products/Applications/supacode.app`。

```bash
APP="build/supacode.xcarchive/Products/Applications/supacode.app"
plutil -p "$APP/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion"
# 确认版本正确（本分支当前为 0.10.8 / 148）
```

## 步骤二：本地签名

先用脚本打到最后签的 identity SHA：

```bash
IDENT="$(security find-identity -v -p codesigning | grep "Apple Development" | head -1 | awk '{print $2}')"
echo "$IDENT"
```

签名顺序：最深的嵌套代码先签，最后签主 App。

```bash
set -e
APP="build/supacode.xcarchive/Products/Applications/supacode.app"
# 若上一次 codesign 中途失败留下 .cstemp 临时文件，先删掉
find "$APP" -name "*.cstemp" -delete
S="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
codesign -f -s "$IDENT" -o runtime --timestamp "$S/Updater.app"
codesign -f -s "$IDENT" -o runtime --timestamp "$S/XPCServices/Downloader.xpc"
codesign -f -s "$IDENT" -o runtime --timestamp "$S/XPCServices/Installer.xpc"
codesign -f -s "$IDENT" -o runtime --timestamp "$S/Autoupdate"
codesign -f -s "$IDENT" -o runtime --timestamp "$APP/Contents/Resources/bin/supacode"
codesign -f -s "$IDENT" -o runtime --timestamp "$APP/Contents/Resources/zmx/zmx"
codesign -f -s "$IDENT" -o runtime --timestamp "$S/Sparkle"
codesign -f -s "$IDENT" -o runtime --timestamp "$APP/Contents/Frameworks/Sparkle.framework"
# 最后签主 App，带上 Release 的 entitlements（Debug 的是 supacodeDebug.entitlements）
codesign -f -s "$IDENT" -o runtime --timestamp --entitlements supacode/supacode.entitlements "$APP"
```

> 为什么签这些：`.github/scripts/resign_exported_app.sh` 对
> Frameworks/PlugIns/Resources/XPCServices/LoginItems 下所有
> `*.app|*.appex|*.framework|*.xpc|*.dylib|可执行文件` 从深到浅重新签名。
> 但未签名归档没有可保留的 entitlement 元数据，所以主 App 改用
> `--entitlements` 显式注入。`Resources/git-wt/wt` 是 bash 脚本，
> 不需要签（由主 App 的 seal 覆盖）。

## 步骤三：验证签名

```bash
APP="build/supacode.xcarchive/Products/Applications/supacode.app"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dv "$APP" 2>&1 | grep -E "TeamIdentifier|flags|Signed Time"
# spctl -a 会被 rejected，这是预期：本地证书 + 未公证
```

## 步骤四：替换 /Applications

```bash
set -e
APP="build/supacode.xcarchive/Products/Applications/supacode.app"
DST="/Applications/supacode.app"
# 若正在运行，先退出
pgrep -x supacode >/dev/null && (osascript -e 'quit app "supacode"'; sleep 2) || true
rm -rf "$DST"
ditto "$APP" "$DST"
plutil -p "$DST/Contents/Info.plist" | grep -E "CFBundleShortVersionString|CFBundleVersion"
codesign --verify --deep --strict "$DST" && echo "verify OK"
```

## 步骤五：验证启动

```bash
open -a /Applications/supacode.app
sleep 6
pgrep -x supacode >/dev/null && echo "RUNNING OK"
```

## 收尾：清理构建副作用

`tuist install` 会把 `Tuist/Package.resolved` 里的仓库地址规范化（去掉 `.git` 后缀）；
启动 App 会改写 `supacode.json`（如 `openActionID`）。这两个都不是我们想要的改动，
恢复后保持工作区干净。**不要 push tag、不要 `make bump-and-release`**：

```bash
git checkout -- Tuist/Package.resolved supacode.json
git status --short   # 应为空
```

## 注意事项

- `make archive` 用 Developer ID 签名（`make archive` 原目标依赖
  `APPLE_TEAM_ID` / `DEVELOPER_ID_IDENTITY_SHA` 环境变量），本机没有这些变量，
  所以必须传 `CODE_SIGNING_ALLOWED=NO` 跳过，否则归档失败。
- 本机装好后：App 可以正常启动使用；但它没有公证，`spctl` 拒绝，
  首次在其它 Mac 上复制过去打开时可能被 Gatekeeper 拦，需要右键“打开”。
- Sparkle 自动更新通道仍指向正式 release，本地装的不影响。