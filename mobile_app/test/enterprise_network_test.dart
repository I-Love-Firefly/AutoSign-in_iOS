import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/campus_network.dart';
import 'package:attendance_assistant/enterprise_network.dart';

import 'domain_test.dart' as fixture;

const account = Account('test', 'example', 'cas', networkPassword: 'wifi');

class EnterpriseFake implements EnterpriseTransport {
  String mode = 'student5g';
  final calls = <String>[];
  Object? prepareError;
  Object? legacyError;
  int result = 0;
  Completer<void>? approvalGate;
  Map<String, dynamic> link = {
    'ip': '10.0.0.10',
    'handle': 2,
    'ssid': 'Student-5G',
    'enterprise': true,
  };
  @override
  Future<void> checkLegacy() async {
    if (legacyError != null) throw legacyError!;
  }

  @override
  Future<Map<String, dynamic>> preferences() async => {'mode': mode};
  @override
  Future<void> permissions() async {
    calls.add('permissions');
  }

  @override
  Future<int> currentHandle() async => 1;
  @override
  Future<Map<String, dynamic>> prepare(Account a) async {
    calls.add('prepare');
    if (approvalGate != null) await approvalGate!.future;
    if (prepareError != null) throw prepareError!;
    return {'previousHandle': 1, 'result': result};
  }

  @override
  Future<Map<String, dynamic>> connect(int p, {required bool manual}) async {
    calls.add(manual ? 'manual' : 'connect');
    return link;
  }

  @override
  Future<Map<String, dynamic>> state() async => link;
  @override
  Future<void> release() async {
    calls.add('release');
  }
}

class CampusFake implements CampusTransport, CampusSubmissionTransport {
  final paths = <String>[];
  String user = 'example', ip = '10.0.0.10';
  int releases = 0;
  int activations = 0;
  @override
  Future<void> activate() async {
    activations++;
  }

  @override
  Future<String> bind() async => ip;
  @override
  Future<String> reconnect() async =>
      throw StateError('portal reconnect must not be used');
  @override
  Future<String> portalPage() async =>
      throw StateError('portal config must not be used');
  @override
  Future<Map<String, dynamic>> get(String path, Map<String, String> p) async {
    paths.add(path);
    return {'error': 'ok', 'online_ip': ip, 'user_name': user};
  }

  @override
  Future<void> release() async {
    releases++;
  }
}

class InnerFake implements AttendanceProvider, SubmissionRouteAware {
  int logins = 0, closes = 0;
  int reads = 0, submits = 0, resets = 0;
  Object? loginError;
  Completer<void>? loginGate;
  List<Course> list = [];
  @override
  Future<void> resetConnections() async {
    resets++;
  }

  @override
  Future<void> login(Account a, void Function(Stage) p) async {
    logins++;
    if (loginGate != null) await loginGate!.future;
    if (loginError != null) throw loginError!;
  }

  @override
  Future<List<Course>> courses() async {
    reads++;
    return list;
  }

  @override
  Future<void> submit(Course c, String code) async {
    submits++;
  }

  @override
  Future<bool> verify(Course c) async => true;
  @override
  Future<void> close() async {
    closes++;
  }
}

class RetryInnerFake extends InnerFake implements RetryableAcademicProvider {
  int restarts = 0;
  @override
  bool get canRestart => true;
  @override
  Future<void> restartLogin(
    Account account,
    void Function(Stage) progress,
  ) async {
    restarts++;
    loginError = null;
    await login(account, progress);
  }
}

Future<void> completePreparation(AdaptiveNetworkProvider p) async {
  await p.login(account, (_) {});
  await p.waitForNetwork();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('enterprise configuration receives uppercase Campus ID and unchanged password', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(AndroidEnterpriseTransport.channel, (
      call,
    ) async {
      expect(call.method, 'prepare');
      expect(call.arguments['username'], 'SWE1234567');
      expect(call.arguments['password'], 'MiXeD-WiFi-password');
      return {'previousHandle': 1, 'result': 0};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        AndroidEnterpriseTransport.channel,
        null,
      ),
    );
    await AndroidEnterpriseTransport().prepare(
      const Account(
        'Test',
        'sWe1234567',
        'fictional-cas-password',
        networkPassword: 'MiXeD-WiFi-password',
      ),
    );
  });
  test('courses load during pending approval, and submission waits for both lanes and route checks', () async {
    final e = EnterpriseFake()..approvalGate = Completer<void>();
    final c = CampusFake();
    final inner = InnerFake()
      ..list = [
        fixture.course({'attendanceMethod': '1'}),
      ];
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: e,
      campus: c,
      identityPollInterval: Duration.zero,
    );
    final stages = <Stage>[];
    final run = AttendanceOrchestrator(
      () => p,
      clock: () => fixture.now,
    ).run(account, '', progress: stages.add, choose: (all) async => all.first);
    await Future<void>.delayed(Duration.zero);
    expect(inner.logins, 1);
    expect(inner.reads, 1);
    expect(inner.submits, 0);
    expect(c.activations, 0);
    expect(stages, contains(Stage.academicReady));
    expect(stages, contains(Stage.waitingNetwork));
    e.approvalGate!.complete();
    expect((await run).code, 'SUCCESS');
    expect(inner.submits, 1);
    expect(inner.reads, 3);
    expect(inner.resets, 2);
    expect(c.activations, 2);
    expect(c.releases, 1);
  });
  test(
    'ready network cannot submit while academic login is still pending',
    () async {
      final inner = InnerFake()
        ..loginGate = Completer<void>()
        ..list = [
          fixture.course({'attendanceMethod': '1'}),
        ];
      final c = CampusFake();
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: EnterpriseFake(),
        campus: c,
        identityPollInterval: Duration.zero,
      );
      final run = AttendanceOrchestrator(
        () => p,
        clock: () => fixture.now,
      ).run(account, '', progress: (_) {}, choose: (all) async => all.first);
      await Future<void>.delayed(Duration.zero);
      await p.waitForNetwork();
      expect(inner.submits, 0);
      inner.loginGate!.complete();
      expect((await run).code, 'SUCCESS');
      expect(inner.submits, 1);
    },
  );
  test('cancelled front lane never submits even after academic preparation succeeds', () async {
    final inner = InnerFake()
      ..list = [
        fixture.course({'attendanceMethod': '1'}),
      ];
    final e = EnterpriseFake()
      ..prepareError = PlatformException(code: 'ENTERPRISE_CANCELLED');
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: e,
      campus: CampusFake(),
      identityPollInterval: Duration.zero,
    );
    final result = await AttendanceOrchestrator(
      () => p,
      clock: () => fixture.now,
    ).run(account, '', progress: (_) {}, choose: (all) async => all.first);
    expect(result.code, 'ENTERPRISE_CANCELLED');
    expect(result.failedStage, Stage.networkApproval);
    expect(inner.logins, 1);
    expect(inner.submits, 0);
    expect(inner.closes, 1);
  });
  test('academic password rejection does not retry or submit and waits for safe cleanup', () async {
    final inner = RetryInnerFake()
      ..loginError = const AttendanceError(
        'AUTH_FAILED',
        'fixture invalid password',
      );
    final e = EnterpriseFake()..approvalGate = Completer<void>();
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: e,
      campus: CampusFake(),
      identityPollInterval: Duration.zero,
    );
    final errors = <Stage>[];
    final run = AttendanceOrchestrator(() => p, clock: () => fixture.now).run(
      account,
      '',
      progress: (_) {},
      onStepError: (stage, _) => errors.add(stage),
      choose: (all) async => all.first,
    );
    await Future<void>.delayed(Duration.zero);
    expect(errors, contains(Stage.authenticating));
    expect(inner.closes, 0);
    e.approvalGate!.complete();
    expect((await run).code, 'AUTH_FAILED');
    expect(inner.restarts, 0);
    expect(inner.submits, 0);
    expect(inner.closes, 1);
  });
  test('transient login connection failure recovers only after network identity is verified', () async {
    final inner = RetryInnerFake()
      ..loginError = const SocketException('fixture disconnected')
      ..list = [
        fixture.course({'attendanceMethod': '1'}),
      ];
    final c = CampusFake();
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: EnterpriseFake(),
      campus: c,
      identityPollInterval: Duration.zero,
    );
    final result = await AttendanceOrchestrator(
      () => p,
      clock: () => fixture.now,
    ).run(account, '', progress: (_) {}, choose: (all) async => all.first);
    expect(result.code, 'SUCCESS');
    expect(inner.restarts, 1);
    expect(inner.submits, 1);
    expect(c.activations, 3);
  });
  test(
    'account changes after preparation are rejected before submission',
    () async {
      final c = CampusFake();
      final inner = InnerFake()
        ..list = [
          fixture.course({'attendanceMethod': '1'}),
        ];
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: EnterpriseFake(),
        campus: c,
        identityPollInterval: Duration.zero,
      );
      final result =
          await AttendanceOrchestrator(() => p, clock: () => fixture.now).run(
            account,
            '',
            progress: (s) {
              if (s == Stage.filling) c.user = 'other';
            },
            choose: (all) async => all.first,
          );
      expect(result.code, 'NETWORK_IDENTITY');
      expect(result.submitted, isFalse);
      expect(inner.submits, 0);
    },
  );
  test('academic login starts independently of system confirmation and network identity checks', () async {
    final e = EnterpriseFake(), c = CampusFake(), inner = InnerFake();
    final stages = <Stage>[];
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: e,
      campus: c,
      identityPollInterval: Duration.zero,
    );
    await p.login(account, stages.add);
    await p.waitForNetwork();
    await p.close();
    expect(e.calls, ['permissions', 'prepare', 'connect', 'release']);
    expect(c.paths, ['/cgi-bin/rad_user_info', '/cgi-bin/rad_user_info']);
    expect(inner.logins, 1);
    expect(inner.closes, 1);
    expect(c.releases, 1);
    expect(stages, [
      Stage.authenticating,
      Stage.networkConfiguring,
      Stage.networkApproval,
      Stage.networkEnterpriseReconnect,
      Stage.networkVerifying,
      Stage.networkReady,
    ]);
  });
  test(
    'manual mode never prepares or changes credentials through portal',
    () async {
      final e = EnterpriseFake()..mode = 'manual5g';
      final c = CampusFake();
      await Student5gNetwork(
        e,
        c,
        interval: Duration.zero,
      ).switchAccount(account, (_) {}, manual: true);
      expect(e.calls, ['permissions', 'manual']);
      expect(c.paths, everyElement('/cgi-bin/rad_user_info'));
    },
  );
  test(
    'cancelled confirmation blocks academic login and allows cleanup',
    () async {
      final e = EnterpriseFake()
        ..prepareError = PlatformException(
          code: 'ENTERPRISE_CANCELLED',
          message: 'cancelled',
        );
      final inner = InnerFake();
      final c = CampusFake();
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: e,
        campus: c,
        identityPollInterval: Duration.zero,
      );
      await expectLater(
        completePreparation(p),
        throwsA(
          isA<AttendanceError>().having(
            (x) => x.code,
            'code',
            'ENTERPRISE_CANCELLED',
          ),
        ),
      );
      await p.close();
      expect(inner.logins, 1);
      expect(e.calls, isNot(contains('connect')));
      expect(c.releases, 1);
    },
  );
  test(
    'saved configuration alone cannot credit another network account',
    () async {
      final e = EnterpriseFake();
      final c = CampusFake()..user = 'other';
      final inner = InnerFake();
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: e,
        campus: c,
        identityPollInterval: Duration.zero,
      );
      await expectLater(
        completePreparation(p),
        throwsA(
          isA<AttendanceError>().having(
            (x) => x.code,
            'code',
            'ENTERPRISE_IDENTITY',
          ),
        ),
      );
      expect(inner.logins, 1);
      expect(c.paths, everyElement('/cgi-bin/rad_user_info'));
    },
  );
  test(
    'missing Wi-Fi password stops before configuration or permission request',
    () async {
      final e = EnterpriseFake();
      await expectLater(
        Student5gNetwork(e, CampusFake()).switchAccount(
          const Account('test', 'example', 'cas'),
          (_) {},
          manual: false,
        ),
        throwsA(isA<AttendanceError>()),
      );
      expect(e.calls, isEmpty);
    },
  );
  test('open Student or unchanged handle cannot proceed', () async {
    for (final values in [
      {'ssid': 'Student'},
      {'handle': 1},
      {'enterprise': false},
    ]) {
      final e = EnterpriseFake();
      e.link.addAll(values);
      final inner = InnerFake();
      final p = AdaptiveNetworkProvider(
        inner,
        enterprise: e,
        campus: CampusFake(),
        identityPollInterval: Duration.zero,
      );
      await expectLater(
        completePreparation(p),
        throwsA(isA<AttendanceError>()),
      );
      expect(inner.logins, 1);
    }
  });
  test('system save rejection cannot proceed to reconnect', () async {
    final e = EnterpriseFake()..result = 1;
    await expectLater(
      Student5gNetwork(
        e,
        CampusFake(),
      ).switchAccount(account, (_) {}, manual: false),
      throwsA(isA<AttendanceError>()),
    );
    expect(e.calls, isNot(contains('connect')));
  });
  test('address mismatch blocks academic login', () async {
    final e = EnterpriseFake();
    final c = CampusFake()..ip = '10.0.0.11';
    final inner = InnerFake();
    final p = AdaptiveNetworkProvider(
      inner,
      enterprise: e,
      campus: c,
      identityPollInterval: Duration.zero,
    );
    await expectLater(
      completePreparation(p),
      throwsA(
        isA<AttendanceError>().having((x) => x.code, 'code', 'NETWORK_ADDRESS'),
      ),
    );
    expect(inner.logins, 1);
  });
  test(
    'legacy mode blocks an enterprise connection before portal requests',
    () async {
      final e = EnterpriseFake()
        ..mode = 'student'
        ..legacyError = PlatformException(code: 'LEGACY_NETWORK_TYPE');
      final c = CampusFake();
      final inner = InnerFake();
      final p = AdaptiveNetworkProvider(inner, enterprise: e, campus: c);
      await expectLater(
        completePreparation(p),
        throwsA(
          isA<AttendanceError>().having(
            (x) => x.code,
            'code',
            'LEGACY_NETWORK_TYPE',
          ),
        ),
      );
      expect(c.paths, isEmpty);
      expect(inner.logins, 1);
    },
  );
}
