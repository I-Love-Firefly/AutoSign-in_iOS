import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'enterprise_network.dart';

class NetworkSettingsDialog extends StatefulWidget {
  final String mode;
  const NetworkSettingsDialog({super.key, required this.mode});
  @override
  State<NetworkSettingsDialog> createState() => _NetworkSettingsDialogState();
}

class _NetworkSettingsDialogState extends State<NetworkSettingsDialog> {
  late String mode = widget.mode;
  String phase2 = 'MSCHAPV2';
  String? error;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final p = await AndroidEnterpriseTransport().preferences();
      if (mounted) {
        setState(() => phase2 = p['phase2'] == 'GTC' ? 'GTC' : 'MSCHAPV2');
      }
    } on PlatformException catch (_) {}
  }

  Future<void> save() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      await AndroidEnterpriseTransport.saveSettings(mode, phase2);
      if (mounted) Navigator.pop(context, mode);
    } on PlatformException catch (e) {
      if (mounted) {
        setState(() {
          busy = false;
          error = e.message ?? '设置保存失败';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) => Platform.isIOS
      ? AlertDialog(
          title: const Text('iPhone 校园网络'),
          content: const Text(
            'iPhone 首选 Student-5G。应用使用当前账号的 Campus ID 和校园网密码配置 PEAP 企业 Wi-Fi，请确认系统加入提示。签名须保留热点配置及访问 Wi-Fi 信息权限。连接后连续核验学校网络账号，不使用 Student 网页切换。若系统仍使用旧身份，请在设置中忽略旧网络或断开重连后重试。',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('关闭'),
            ),
          ],
        )
      : PopScope(
          canPop: !busy,
          child: AlertDialog(
            title: const Text('校园网方式'),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: mode,
                    isExpanded: true,
                    items: const [
                      DropdownMenuItem(
                        value: 'student5g',
                        child: Text('Student-5G · 系统确认'),
                      ),
                      DropdownMenuItem(
                        value: 'manual5g',
                        child: Text('Student-5G · 手动切换'),
                      ),
                      DropdownMenuItem(
                        value: 'student',
                        child: Text('Student · 旧版流程'),
                      ),
                    ],
                    onChanged: busy
                        ? null
                        : (v) {
                            if (v != null) setState(() => mode = v);
                          },
                  ),
                  const SizedBox(height: 12),
                  Text(
                    mode == 'student5g'
                        ? '应用填写当前学生的配置，你在系统页面确认；重新连接并核验账号后继续。需要 Android 11 或以上。'
                        : mode == 'manual5g'
                        ? '在系统设置修改 Student-5G 的身份和密码，断开重连后返回；应用核验账号后继续。'
                        : '使用之前的 Student 网页认证切换。连接成功不保证签到系统认可此网络。',
                  ),
                  const SizedBox(height: 8),
                  const Text('使用账号中的“校园网密码”，无需每个学生分别设置认证参数。'),
                  ExpansionTile(
                    title: const Text('共用认证设置'),
                    children: [
                      const Text('PEAP · 系统可信证书 · xmu.edu.my'),
                      DropdownButtonFormField<String>(
                        key: ValueKey(phase2),
                        initialValue: phase2,
                        decoration: const InputDecoration(labelText: '第二阶段认证'),
                        items: const [
                          DropdownMenuItem(
                            value: 'MSCHAPV2',
                            child: Text('MSCHAPV2'),
                          ),
                          DropdownMenuItem(value: 'GTC', child: Text('GTC')),
                        ],
                        onChanged: busy
                            ? null
                            : (v) {
                                if (v != null) setState(() => phase2 = v);
                              },
                      ),
                    ],
                  ),
                  if (error != null)
                    Text(error!, style: const TextStyle(color: Colors.red)),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: busy ? null : () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: busy ? null : save,
                child: const Text('保存'),
              ),
            ],
          ),
        );
}
