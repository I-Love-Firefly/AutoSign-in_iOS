# AutoSign-in iOS

当前修复版：**0.7.17+40**。修复 iOS 跨域复用 HTTP/2 连接导致教务登录返回 HTTP 421 的问题，详见 [HTTP421修复说明.md](HTTP421修复说明.md)。

从 AutoSign-in/mobile_app 0.7.11+34 独立复制并适配。原 Android 项目不修改。

已迁移：账号编辑及安全存储、课程查询、签到及记录核验、AC 课表、加密账号档案。iOS 使用 Keychain、系统文件选择器和导出窗口。加密档案沿用 PBKDF2-HMAC-SHA256（310000 次）、AES-256-GCM 和原 AAD，支持原 Android 格式。

iOS 校园网络流程的演进见下方各版本记录。学校请求使用原生 URLSession 禁止蜂窝数据；每个逻辑账号会话按目标域名分别建立连接池，Cookie 按账号会话隔离，并由 Dart 校验每次重定向。VPN 路由及学校实际认可情况需要真机验证。

## 未签名 IPA

需要 macOS/Xcode，可使用 Mac 或 GitHub Actions 云端 macOS。Windows 可以编辑源码及运行 Dart/Flutter 测试，不能本机执行 Xcode 编译。

在项目根目录执行：

```sh
bash scripts/build-unsigned-ipa.sh
```

输出：`mobile_app/build/ios/ipa/AutoSign-in-unsigned.ipa`。脚本先运行原生连接池测试、Flutter 静态分析及测试，再编译 `Runner.app` 并打包 `Payload/Runner.app`，不配置签名。未签名 IPA 供后续签名使用，不能直接安装到普通 iPhone。

云端：将此目录作为仓库根目录上传到 GitHub，进入 Actions → Unsigned iOS IPA → Run workflow，完成后下载 AutoSign-in-unsigned-IPA artifact。工作流只手动触发，不发布 Release、不需要 Apple 证书。Flutter 版本与当前开发 SDK 固定为 3.47.4。

## 验证边界

Windows 上可验证 Flutter 静态分析、业务测试和独立密码学向量。Swift 编译、iPhone 文件窗口、Keychain 和实际校园网络需要 macOS 构建及真机验证。生成了 Xcode 项目和构建流程不代表已经生成 IPA。

## 已完成的云端构建

2026-10-14 已通过 GitHub Actions 的 macOS/Xcode 编译并下载未签名 ARM64 IPA，保存在本地 artifacts/AutoSign-in-unsigned.ipa。构建记录：https://github.com/I-Love-Firefly/AutoSign-in_iOS/actions/runs/38514606967 。该产物尚未签名，未进行 iPhone 实测。


## iOS 0.7.12+35：首选 Student

iOS 默认改为 Student，先在系统设置手动连接。应用复用 Student 的网页认证协议注销当前手机会话、登录所选账号并核验；不调用 Android 的 Wi-Fi 断开重连。若校园网要求重连才能刷新绑定，需用户手动重连后重试。免费个人签名无法确认 SSID，连接网络由用户确认。Student 网页认证与真实学校签到认可情况尚未真机验证。Android 原项目保持 Student-5G。


## iOS 0.7.13+36：系统自动加入 Student

开始流程时调用 NEHotspotConfigurationManager 请求加入开放的 Student Wi-Fi，系统可能要求确认。配置结果并不直接视为连接成功；随后核验 SSID=Student 和校园 IPv4，再执行网页认证切换。加入失败或权限错误时停止，并显示系统错误域和代码。签名需保留 HotspotConfiguration 和 wifi-info 两项 entitlement（全能签的配置及最终有效权限需真机确认）。不强制断开重连，不自动修改 Student-5G 企业账号。


## iOS 0.7.14+37：首选 Student-5G

改用 NEHotspotEAPSettings 配置 PEAP（EAP 25）、当前 Campus ID（含外层身份）和校园网密码；校验服务器名称 *.xmu.edu.my / xmu.edu.my。不再使用 Student 网页注销或登录。连接后连续两次核验学校记录的手机 IP 与账号，身份不符停止。若 iOS 保留用户配置或旧会话，需要手动忽略旧网络/断开重连后重试。签名仍需 HotspotConfiguration 和 wifi-info；PEAP 参数、学校证书及实际账号更新尚待真机验证。


## iOS 0.7.15+38：移除校园网账号一致性核验

不再在 iOS 连接后或提交前调用 rad_user_info 比较网络账号与所选签到账号；移除连续两次身份核验。保留 Student-5G SSID、校园 IP 和地址变化检查。学校登录、课程条件及提交后记录核验保持不变。


## iOS 0.7.16+39：Student-5G 配置完整重建

修复策略：不再直接 apply 到应用已有的企业网络配置。先查询应用管理的 SSID，移除 Student-5G，等待配置移除且旧连接离开，再以新 NEHotspotEAPSettings 同时设置 username、outerIdentity、password。清理超时、无法读取已有连接或遇到系统手动保存的当前 Student-5G 时停止，不继续写新密码。新配置遇到 alreadyAssociated 也不视作成功。首次使用请先手动忽略系统保存的 Student-5G；应用无权删除用户或其他应用的配置。保留 0.7.15 移除校园网账号一致性检查的行为。实际用户名切换需用户真机验证。

