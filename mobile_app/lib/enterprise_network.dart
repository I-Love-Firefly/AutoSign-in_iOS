import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

import 'campus_network.dart';
import 'domain.dart';

abstract class EnterpriseTransport {
  Future<Map<String, dynamic>> preferences();
  Future<void> permissions();
  Future<int> currentHandle();
  Future<Map<String, dynamic>> prepare(Account account);
  Future<Map<String, dynamic>> connect(int previous, {required bool manual});
  Future<Map<String, dynamic>> state();
  Future<void> release();
  Future<void> checkLegacy() async {}
}

class AndroidEnterpriseTransport implements EnterpriseTransport {
  static const channel = MethodChannel(
    'com.xmum.attendance_assistant/enterprise',
  );
  Future<Map<String, dynamic>> _map(
    String method, [
    Map<String, dynamic>? args,
  ]) async => Map<String, dynamic>.from(
    await channel.invokeMapMethod<String, dynamic>(method, args) ?? {},
  );
  @override
  Future<Map<String, dynamic>> preferences() => _map('preferences');
  @override
  Future<void> checkLegacy() => channel.invokeMethod('legacyGuard');
  static Future<void> saveSettings(String mode, String phase2) =>
      channel.invokeMethod('setPreferences', {'mode': mode, 'phase2': phase2});
  @override
  Future<void> permissions() => channel.invokeMethod('permissions');
  @override
  Future<int> currentHandle() async =>
      (await channel.invokeMethod<num>('currentHandle'))?.toInt() ?? -1;
  @override
  Future<Map<String, dynamic>> prepare(Account account) => _map('prepare', {
    'username': account.campusId.trim(),
    'password': account.networkPassword,
  });
  @override
  Future<Map<String, dynamic>> connect(int previous, {required bool manual}) =>
      _map('connect', {'previousHandle': previous, 'manual': manual});
  @override
  Future<Map<String, dynamic>> state() => _map('state');
  @override
  Future<void> release() => channel.invokeMethod('release');
}

class Student5gNetwork {
  final EnterpriseTransport enterprise;
  final CampusTransport campus;
  final Duration interval;
  Student5gNetwork(
    this.enterprise,
    this.campus, {
    this.interval = const Duration(seconds: 1),
  });
  Future<void> switchAccount(
    Account account,
    void Function(Stage) progress, {
    required bool manual,
  }) async {
    if (account.networkPassword.isEmpty) {
      throw const AttendanceError(
        'NETWORK_PASSWORD_MISSING',
        '请先在编辑账号中填写校园网密码',
      );
    }
    progress(Stage.networkConfiguring);
    await enterprise.permissions();
    var previous = await enterprise.currentHandle();
    if (!manual) {
      progress(Stage.networkApproval);
      final saved = await enterprise.prepare(account);
      if (saved['previousHandle'] is! num ||
          ![0, 2].contains(saved['result'])) {
        throw const AttendanceError(
          'ENTERPRISE_SAVE_FAILED',
          '系统未确认 Student-5G 配置，已停止',
        );
      }
      previous = (saved['previousHandle'] as num).toInt();
    }
    progress(Stage.networkEnterpriseReconnect);
    final link = await enterprise.connect(previous, manual: manual);
    final ip = link['ip'];
    if (ip is! String ||
        !ip.startsWith('10.') ||
        link['ssid'] != 'Student-5G' ||
        link['enterprise'] != true ||
        link['handle'] == previous) {
      throw const AttendanceError(
        'ENTERPRISE_CONNECTION',
        '未确认新的 Student-5G 企业网络连接，已停止',
      );
    }
    if (await campus.bind() != ip) {
      throw const AttendanceError('NETWORK_ADDRESS', '连接地址已变化，请重新开始流程');
    }
    progress(Stage.networkVerifying);
    var confirmations = 0;
    String? lastUser;
    for (var i = 0; i < 20; i++) {
      final now = await enterprise.state();
      if (now['handle'] != link['handle'] ||
          now['ip'] != ip ||
          now['ssid'] != 'Student-5G' ||
          now['enterprise'] != true) {
        throw const AttendanceError(
          'ENTERPRISE_CONNECTION_CHANGED',
          'Student-5G 连接已变化，已停止',
        );
      }
      final status = await campus.get('/cgi-bin/rad_user_info', {'ip': ip});
      if ((status['client_ip'] ?? status['online_ip']) != ip) {
        throw const AttendanceError('NETWORK_ADDRESS', '学校返回的设备地址不匹配，已停止');
      }
      if (status['error'] != 'ok' && status['error'] != 'not_online_error') {
        throw const AttendanceError(
          'ENTERPRISE_STATUS',
          '学校未提供可核验的网络身份，已停止；请在官方页面核验',
        );
      }
      lastUser = status['user_name'] is String
          ? status['user_name'] as String
          : null;
      if (status['error'] == 'ok' &&
          lastUser?.toLowerCase() == account.campusId.trim().toLowerCase()) {
        if (++confirmations >= 2) return;
      } else {
        confirmations = 0;
      }
      if (i < 19) await Future<void>.delayed(interval);
    }
    final actual =
        lastUser != null &&
            RegExp(r'^[A-Za-z0-9@._-]{1,100}$').hasMatch(lastUser)
        ? '，当前学校记录账号为 $lastUser'
        : '';
    throw AttendanceError(
      'ENTERPRISE_IDENTITY',
      '未确认校园网账号与所选学生一致$actual。请检查系统保存的身份、密码和认证设置；未提交签到',
    );
  }
}

class AdaptiveNetworkProvider
    implements ParallelAttendanceProvider, CampusPreparedProvider {
  final AttendanceProvider inner;
  final EnterpriseTransport enterprise;
  final CampusTransport campus;
  bool _useEnterprise = false;
  Future<void>? _networkTask;
  AttendanceError? _networkError;
  Account? _account;
  String? _networkIp;
  Stage _networkStage = Stage.networkChecking;
  bool _routeReady = false;
  bool _recovered = false;
  void Function(Stage)? _progress;
  final Duration identityPollInterval;
  AdaptiveNetworkProvider(
    this.inner, {
    EnterpriseTransport? enterprise,
    CampusTransport? campus,
    this.identityPollInterval = const Duration(seconds: 1),
  }) : enterprise = enterprise ?? AndroidEnterpriseTransport(),
       campus = campus ?? AndroidCampusTransport();
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    _account = account;
    _progress = progress;
    _networkTask =
        _prepareNetwork(account, (stage) {
          _networkStage = stage;
          progress(stage);
        }).then(
          (_) {
            progress(Stage.networkReady);
          },
          onError: (Object error) {
            _networkError = error is AttendanceError
                ? AttendanceError(
                    error.code,
                    error.message,
                    stage: _networkStage,
                  )
                : error is PlatformException
                ? AttendanceError(
                    error.code,
                    error.message ?? '校园网切换失败',
                    stage: _networkStage,
                  )
                : AttendanceError(
                    'NETWORK_PREPARATION',
                    '校园网准备失败，请检查网络后重试',
                    stage: _networkStage,
                  );
            progress(Stage.networkFailed);
          },
        );
    progress(Stage.authenticating);
    try {
      await inner.login(account, progress);
    } catch (e) {
      if (!_canRecover(e)) rethrow;
      await _recover();
    }
  }

  bool _canRecover(Object e) =>
      !_recovered &&
      inner is RetryableAcademicProvider &&
      (inner as RetryableAcademicProvider).canRestart &&
      (e is SocketException ||
          e is HttpException ||
          e is TimeoutException ||
          (e is AttendanceError && e.code == 'NETWORK_ERROR'));

  Future<void> _recover() async {
    _recovered = true;
    _progress?.call(Stage.waitingNetwork);
    await waitForNetwork();
    _progress?.call(Stage.networkRouting);
    await activateSubmissionRoute();
    _progress?.call(Stage.retryAcademic);
    await (inner as RetryableAcademicProvider).restartLogin(
      _account!,
      _progress!,
    );
  }

  Future<void> _prepareNetwork(
    Account account,
    void Function(Stage) progress,
  ) async {
    try {
      final mode = (await enterprise.preferences())['mode'];
      if (mode == 'student') {
        await enterprise.permissions();
        await enterprise.checkLegacy();
        await CampusNetwork(campus).switchAccount(account, progress);
      } else if (mode == 'student5g' || mode == 'manual5g') {
        _useEnterprise = true;
        await Student5gNetwork(
          enterprise,
          campus,
          interval: identityPollInterval,
        ).switchAccount(account, progress, manual: mode == 'manual5g');
      } else {
        throw const AttendanceError('ENTERPRISE_SETTINGS', '校园网方式不受支持，请重新设置');
      }
      _networkIp = await campus.bind();
    } on PlatformException catch (e) {
      // Native messages never echo credentials or complete request URLs.
      throw AttendanceError(e.code, e.message ?? '校园网切换失败');
    }
  }

  @override
  Future<void> waitForNetwork() async {
    await _networkTask;
    if (_networkError != null) throw _networkError!;
  }

  @override
  Future<void> activateSubmissionRoute() async {
    _routeReady = false;
    await waitForNetwork();
    try {
      final selected = _account;
      final ip = _networkIp;
      if (selected == null || ip == null) {
        throw const AttendanceError('NETWORK_PREPARATION', '校园网尚未准备完成');
      }
      if (campus is CampusSubmissionTransport) {
        await (campus as CampusSubmissionTransport).activate();
      }
      if (_useEnterprise) {
        final state = await enterprise.state();
        if (state['ssid'] != 'Student-5G' ||
            state['ip'] != ip ||
            state['enterprise'] != true) {
          throw const AttendanceError(
            'NETWORK_ADDRESS',
            'Student-5G连接已变化，未提交签到',
          );
        }
      }
      final status = await campus.get('/cgi-bin/rad_user_info', {'ip': ip});
      if (status['error'] != 'ok' ||
          (status['online_ip'] ?? status['client_ip']) != ip ||
          '${status['user_name']}'.toLowerCase() !=
              selected.campusId.trim().toLowerCase()) {
        throw const AttendanceError(
          'NETWORK_IDENTITY',
          '提交前未确认校园网账号与所选学生一致，未提交签到',
        );
      }
      if (inner is SubmissionRouteAware) {
        await (inner as SubmissionRouteAware).resetConnections();
      }
      _routeReady = true;
    } on AttendanceError catch (e) {
      throw AttendanceError(e.code, e.message, stage: Stage.networkRouting);
    } on PlatformException catch (e) {
      throw AttendanceError(
        e.code,
        e.message ?? '提交网络核验失败',
        stage: Stage.networkRouting,
      );
    }
  }

  @override
  Future<List<Course>> courses() async {
    try {
      return await inner.courses();
    } catch (e) {
      if (!_canRecover(e)) rethrow;
      await _recover();
      return inner.courses();
    }
  }

  @override
  Future<void> submit(Course course, String code) {
    if (!_routeReady) {
      throw const AttendanceError('CLASS_CHANGED', '提交网络尚未核验，未提交签到');
    }
    return inner.submit(course, code);
  }

  @override
  Future<bool> verify(Course course) => inner.verify(course);
  @override
  Future<void> close() async {
    await _networkTask;
    try {
      await inner.close();
    } finally {
      try {
        await campus.release();
      } finally {
        if (_useEnterprise) await enterprise.release();
      }
    }
  }
}
