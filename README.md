# AutoSign-in iOS

从 AutoSign-in/mobile_app 0.7.11+34 独立复制并适配。原 Android 项目不修改。

已迁移：账号编辑及安全存储、课程查询、签到及记录核验、AC 课表、加密账号档案。iOS 使用 Keychain、系统文件选择器和导出窗口。加密档案沿用 PBKDF2-HMAC-SHA256（310000 次）、AES-256-GCM 和原 AAD，支持原 Android 格式。

iOS 校园网络流程：先在系统设置连接 Student/Student-5G，并通过学校认证页面登录当前账号，返回应用。提交前核验手机 Wi-Fi IPv4 与学校记录的账号。不会自动修改企业 Wi-Fi 配置或执行 Android 的断开重连。学校请求使用原生 URLSession 禁止蜂窝数据；教务会话分别隔离 Cookie，并由 Dart 校验每次重定向。VPN 路由及学校实际认可情况需要真机验证。

## 未签名 IPA

需要 macOS/Xcode，可使用 Mac 或 GitHub Actions 云端 macOS。Windows 可以编辑源码及运行 Dart/Flutter 测试，不能本机执行 Xcode 编译。

在项目根目录执行：

```sh
bash scripts/build-unsigned-ipa.sh
```

输出：`mobile_app/build/ios/ipa/AutoSign-in-unsigned.ipa`。脚本先测试，再编译 `Runner.app` 并打包 `Payload/Runner.app`，不配置签名。未签名 IPA 供后续签名使用，不能直接安装到普通 iPhone。

云端：将此目录作为仓库根目录上传到 GitHub，进入 Actions → Unsigned iOS IPA → Run workflow，完成后下载 AutoSign-in-unsigned-IPA artifact。工作流只手动触发，不发布 Release、不需要 Apple 证书。Flutter 版本与当前开发 SDK 固定为 3.47.4。

## 验证边界

Windows 上可验证 Flutter 静态分析、业务测试和独立密码学向量。Swift 编译、iPhone 文件窗口、Keychain 和实际校园网络需要 macOS 构建及真机验证。生成了 Xcode 项目和构建流程不代表已经生成 IPA。

## 已完成的云端构建

2026-10-14 已通过 GitHub Actions 的 macOS/Xcode 编译并下载未签名 ARM64 IPA，保存在本地 artifacts/AutoSign-in-unsigned.ipa。构建记录：https://github.com/I-Love-Firefly/AutoSign-in_iOS/actions/runs/38514606967 。该产物尚未签名，未进行 iPhone 实测。

