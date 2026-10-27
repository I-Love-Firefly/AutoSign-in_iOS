# iOS 0.7.17+40：HTTP 421 修复

基于用户提供的 `AutoSign-in_iOS-0.7.16+39-source.zip` 修改。

## 问题与修改

2026-10-27 真机日志显示，CAS 的 HTTP/2 连接被用于另一学校域名，随后连续收到 421。无账号对照请求也证实：通过 CAS 连接请求 acad 返回 421，而为 acad 独立建连返回 200。

旧版按逻辑账号会话创建一个 URLSession，同时请求 `cas.xmu.edu.my`、`acad.xmu.edu.my`。新版在每个逻辑会话内，再按 HTTPS 域名分别创建 URLSession。因此同一域名内仍可复用连接，CAS 与教务站不再共享连接池；AC 课表站也独立。

Cookie 仍使用该逻辑会话自己的临时存储，按标准域名、路径规则发送，不与其他账号或系统共享。关闭会话时取消全部域名连接并清理 Cookie；重建连接时保留 Cookie。Dart 现在等待 iOS 原生连接重置完成。

重定向继续由 Dart 逐跳检查，再选择目标域名的连接池；HTTPS、主机白名单、证书校验、禁止蜂窝网络及 Wi-Fi IP 检查继续生效。没有引入证书校验绕过或自动重发签到。

此外，初始化 CAS、获取票据和交换票据现在检查 HTTP 状态。交换票据返回 421 等错误时，流程停在“建立教务登录会话”，不再先显示成功、到“获取当前学生身份”才报错。

实现依据：[Apple WWDC 2018：URLSession 的 HTTP/2 connection coalescing 与每个 session 的连接池](https://developer.apple.com/videos/play/wwdc2018/714/)。

## 关键文件

- `mobile_app/ios/Runner/SchoolSessionPool.swift`：新增按账号会话和域名分开的连接池。
- `mobile_app/ios/Runner/AppDelegate.swift`：接入新连接池及原生重置方法。
- `mobile_app/ios/Runner.xcodeproj/project.pbxproj`：将新 Swift 文件加入 Runner 编译。
- `mobile_app/lib/api_provider.dart`：登录阶段 HTTP 状态检查、等待原生重置。
- `mobile_app/test/api_provider_test.dart`：新增 7 个回归测试。
- `scripts/native-tests/SchoolSessionPoolTests.swift`：6 个原生测试，覆盖连接池和 Cookie 隔离、重置、关闭、重定向及域名限制。
- `scripts/test-native-session-pool.sh`：在 macOS 上用临时 SwiftPM 项目测试实际 Runner 源码。
- `scripts/build-unsigned-ipa.sh`：打包前先运行原生测试。
- `mobile_app/pubspec.yaml`：版本更新为 0.7.17+40。

## 本次验证

- Windows，Flutter 3.47.4 / Dart 3.13.3：`flutter analyze` 通过，无问题。
- `flutter test --reporter expanded`：**163 个测试全部通过**。
- 新增 Swift 测试已纳入原有云端构建入口，但本机没有 macOS/Xcode，**本次未执行 Swift 测试或 iOS 编译，未生成新版 IPA，未完成修复后的 iPhone 验证**。

## 构建与验收

解压后，将完整源码目录（含 `.github`）更新到用于 iOS 构建的仓库。原有 Actions → Unsigned iOS IPA → Run workflow 入口保持可用。也可在 Mac 的源码根目录执行：

```sh
bash scripts/build-unsigned-ipa.sh
```

流程会先运行 Swift 原生测试、Flutter 分析和测试，再构建未签名 IPA。必须先通过云端编译，再完成签名和真机验证；源码修改完成不代表手机中的旧版已经更新。

真机先用“测试登录 / 查询（不签到）”确认票据交换、身份读取、课程查询均成功。日志应显示 CAS 与 acad 使用独立连接，不再在 CAS 的 HTTP/2 连接上收到 421；随后验证课表查询和正常使用流程。
