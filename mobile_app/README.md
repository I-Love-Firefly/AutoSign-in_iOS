# AutoSign-in iOS mobile app

当前版本：**0.7.17+40**。完整说明见仓库根目录 [README](../README.md)。

- 首选 Student-5G，使用账号中的 Campus ID 和校园网密码配置 PEAP 企业 Wi-Fi；切换前移除应用自己创建的旧配置并等待断开，再完整写入用户名、外层身份和密码。
- 请求系统加入网络并检查 SSID、校园 IPv4 和地址变化；不再比较校园网账号与所选签到账号。
- 签名需包含 `com.apple.developer.networking.HotspotConfiguration` 和 `com.apple.developer.networking.wifi-info`。
- 保留学校登录、课程条件检查和提交后签到记录核验。

## 开发验证

```sh
flutter pub get
flutter analyze
flutter test
```

## 构建未签名 IPA

在 macOS/Xcode 环境，从仓库根目录运行：

```sh
bash scripts/build-unsigned-ipa.sh
```

也可以在 GitHub Actions 手动运行 **Unsigned iOS IPA** 工作流。产物需另行签名安装。

历史版本已通过测试和云端 Xcode 编译；本次构建结果见 GitHub Actions。Wi-Fi 配置更新、签名权限及实际校园网络行为仍需在目标 iPhone 验证。
