# react-native-nitro-qq

基于 [Nitro Modules](https://nitro.margelo.com) 构建的腾讯 QQ（OpenSDK）React Native 原生绑定库。对外暴露一个完全类型安全的 `QQ` HybridObject，统一封装登录、会话恢复、用户信息、QQ / QZone 图文与图片分享，以及 iOS 端的 URL 回调分发，iOS、Android 两端均无需新建架构即可使用。

- **iOS**：Swift 原生封装官方 `TencentOpenAPI.xcframework`（Lite，3.6.20），框架随包内置在 `ios/Vendor/`
- **Android**：Kotlin 原生封装官方 `open_sdk_3.5.19` 的 jar（已随包内置在 `android/libs/`，无需联网）
- 100% 类型安全，基于 Promise，无新架构锁定
- 已配置好发布到 npm 所需的字段（包名 `react-native-nitro-qq`）

## 环境要求

| 平台 | 最低版本 | 说明 |
| --- | --- | --- |
| React Native | 0.75+ | Nitro Modules 0.37 要求 |
| Xcode | 16.4+ | Nitro Modules 0.37 要求 |
| Swift | 5.9+ | Nitro Modules 0.37 要求 |
| Android compileSdk | 34+ | Nitro Modules 0.37 要求 |
| Android NDK | 27+ | Nitro Modules 0.37 要求 |
| react-native-nitro-modules | 0.37+ | 作为 peer 依赖自动安装 |

## 安装

```sh
npm install react-native-nitro-qq
# iOS 侧只需执行一次 CocoaPods 安装
cd ios && bundle install && bundle exec pod install
```

Android 无需额外 Gradle 步骤——QQ OpenSDK 的 jar 已随库内置在 `android/libs/`，第一次构建即生效。

## iOS 配置

1. 在 `Info.plist` 中注册 QQ 回调 URL Scheme（由 [QQ互联](https://connect.qq.com) 后台分配的 app id 决定）：

   ```xml
   <key>CFBundleURLTypes</key>
   <array>
     <dict>
       <key>CFBundleURLName</key>
       <string>com.tencent.qq</string>
       <key>CFBundleURLSchemes</key>
       <array>
         <string>tencent${QQ_APP_ID}</string>
       </array>
     </dict>
   </array>
   ```

   例如 app id 为 `1100000000`，则 scheme 为 `tencent1100000000`。

2. 如果开启 `QQConfig.enableUniversalLink`，还需给 target 添加 Associated Domains 能力，并把 Universal Link 转发给本库：

   ```swift
   func application(_ app: UIApplication, continue userActivity: NSUserActivity,
                    restorationHandler: @escaping ([UIUserActivityRestoring]?) -> Void) -> Bool {
     if userActivity.activityType == NSUserActivityTypeBrowsingWeb,
        let url = userActivity.webpageURL {
       return QQApplicationDelegate.handleUniversalLink(url)
     }
     return false
   }
   ```

3. 基于 Scene 的工程，也要在对应的 SceneDelegate / `AppDelegate.application(_:open:options:)` 中调用 `QQApplicationDelegate.handleOpenURL(_:)`。

## Android 配置

1. 在宿主 App 的 `android/build.gradle` 中设置 QQ app id，供库内 `AndroidManifest.xml` 拼出登录回调 intent-filter：

   ```gradle
   ext.qqAppId = "1100000000"
   ```

2. 登录 / 分享的回调已在本库调用 `QQ.login()` / `QQ.shareImage()` / `QQ.shareNews()` 时自动注册 `BaseActivityEventListener`，宿主无需手写在 `onActivityResult` 里转发（官方 SDK 内部通过 `Tencent.onActivityResultData` 派发）。

3. 升级 QQ Android SDK：把新的 `open_sdk_*.jar` 覆盖到 `android/libs/`，并在 `android/gradle.properties` 里把 `NitroQQ_qqSdkVersion` 改成对应版本号（仅用于 `getSdkVersion()` 展示与排查，不影响编译）。

## 使用方式

```ts
import { QQ } from 'react-native-nitro-qq'

await QQ.initialize({
  appId: '1100000000',
  universalLink: 'https://example.com/qq/', // 选填
  enableUniversalLink: true,
  userAgreement: true,
})

try {
  const session = await QQ.login(['get_user_info'])
  console.log(session.openId, session.expiresAt)
  const profile = await QQ.getUserInfo()
  console.log(profile.nickname, profile.avatarUrl)
} catch (error) {
  console.warn('QQ error', error.code, error.message)
}
```

冷启动后可用 `restoreSession()` 恢复会话，无需再次拉起 QQ：

```ts
await QQ.restoreSession(accessToken, openId, expiresAt)
```

### 分享

```ts
await QQ.shareImage({
  imagePath: '/path/to/photo.jpg',
  title: '看看这张图',
  description: '来自我的 App',
  scene: 'qzone', // 'qzone' 分享到 QQ 空间，'qq' 分享给好友 / 群
})

await QQ.shareNews({
  url: 'https://example.com/article',
  title: '文章标题',
  description: '选填的摘要',
  imageUrl: 'https://example.com/cover.png',
  scene: 'qq',
})
```

`scene` 取值为 `'qq'`（分享给好友 / 群）或 `'qzone'`（分享到 QQ 空间）。

### 错误处理

所有原生错误都会以 JavaScript `Error` 形式抛出，其 `code` 字段携带根因，例如：

- `user_cancelled` —— 用户关闭了 QQ 弹窗
- `invalid_session` —— 调用 `getUserInfo` 时登录态已失效
- `invalid_url` / `invalid_image` / `invalid_scene` —— 分享参数不合法
- `user_agreement_required` —— 需先以 `initialize({ userAgreement: true })` 同意隐私协议
- `operation_in_progress` —— 同一时间只允许一个登录或分享进行
- `share_start_failed` / `login_start_failed` —— SDK 在弹出对话框前就拒绝了请求

### API 一览

| 方法 | 说明 |
| --- | --- |
| `initialize(config)` | 初始化，必须最先调用；`userAgreement` 控制隐私授权 |
| `setUserAgreement(agreed)` | 单独设置隐私授权（便于二次弹窗后补同意） |
| `getSdkVersion()` | 返回当前 QQ SDK 版本字符串 |
| `isQQInstalled()` | 是否安装了 QQ（仅 Android 真实生效，iOS 也提供） |
| `isSessionValid()` | 当前登录态是否有效 |
| `login(scopes[])` | 拉起 QQ 登录，返回 Promise<QQLoginResult> |
| `restoreSession(token, openId, expiresAtMs)` | 恢复已有会话 |
| `logout()` | 退出登录 |
| `getUserInfo()` | 获取昵称、头像、性别、地区、VIP 等，返回 Promise<QQUserInfo> |
| `shareImage(params)` | 分享本地图片 |
| `shareNews(params)` | 分享网页图文 |
| `handleOpenURL(url)` | iOS 专用：在 AppDelegate 转发回调 |
| `handleUniversalLink(url)` | iOS 专用：在 AppDelegate 转发 Universal Link |

## 目录结构

```
react-native-nitro-qq/
├── package.json            # 包名、版本、NitroModules peer 依赖、bob 构建、prepare
├── nitro.json             # 一个 HybridObject 'QQ'，iOS Swift / Android Kotlin
├── NitroQQ.podspec        # iOS 规格（内置 xcframework + 资源 bundle + 系统依赖）
├── android/
│   ├── libs/open_sdk_3.5.19_r9483ffc7_lite.jar   # QQ Android SDK，本地引入
│   ├── build.gradle       # 工程配置（移除 Maven，改用本地 jar）
│   ├── gradle.properties  # NDK/SDK 版本与内置 QQ SDK 版本号
│   ├── CMakeLists.txt
│   ├── fix-prefab.gradle
│   ├── src/main/AndroidManifest.xml
│   └── src/main/java/com/margelo/nitro/qq/   # HybridQQ.kt / NitroQQPackage.kt
├── ios/
│   ├── HybridQQ.swift             # Swift 适配（初始化、登录、用户信息、分享、回调）
│   └── Vendor/                    # 官方 TencentOpenAPI 3.6.20 + 资源 bundle
├── src/                          # TypeScript 规格与入口
├── nitrogen/generated/            # Nitrogen 生成的 C++/Swift/Kotlin 绑定
└── lib/                          # bob 构建产物（commonjs / module / typescript）
```

## 发布到 npm

仓库根目录直接执行：

```sh
npm login
npm publish --access public
```

`prepare` 脚本会自动执行 `nitrogen` + `bob build`，确保发布的版本包含最新的 C++ 绑定与 JS 产物。

## 许可协议

MIT
