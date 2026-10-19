import 'dart:convert';
import 'dart:io';

import 'package:attendance_assistant/domain.dart';

import 'campus_network_test.dart' show PortalFake;
import 'domain_test.dart' show FakeProvider, course;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/ios_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'Wi-Fi rejection stops before portal mutations or academic login',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(IosArchiveBridge.files, (call) async {
        throw PlatformException(
          code: 'IOS_WIFI_CONFIGURATION',
          message: 'denied',
        );
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(IosArchiveBridge.files, null),
      );
      final campus = PortalFake();
      final inner = FakeProvider();
      final provider = IosAttendanceProvider(inner, campus: campus);
      await expectLater(
        provider.login(
          const Account(
            'Example',
            'example',
            'cas',
            networkPassword: 'password',
          ),
          (_) {},
        ),
        throwsA(
          isA<AttendanceError>().having(
            (e) => e.code,
            'code',
            'IOS_WIFI_CONFIGURATION',
          ),
        ),
      );
      expect(campus.calls, isEmpty);
      expect(inner.submissions, 0);
    },
  );
  test('unexpected Wi-Fi network stops before portal mutations', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
      IosArchiveBridge.files,
      (call) async => {'ssid': 'Student', 'ip': '10.72.88.93'},
    );
    addTearDown(
      () => messenger.setMockMethodCallHandler(IosArchiveBridge.files, null),
    );
    final campus = PortalFake();
    final provider = IosAttendanceProvider(FakeProvider(), campus: campus);
    await expectLater(
      provider.login(
        const Account('Example', 'example', 'cas', networkPassword: 'password'),
        (_) {},
      ),
      throwsA(
        isA<AttendanceError>().having(
          (e) => e.code,
          'code',
          'IOS_WIFI_NOT_CONFIRMED',
        ),
      ),
    );
    expect(campus.calls, isEmpty);
  });
  test('Student-5G credentials preserve password case and skip Student portal mutations', () async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(IosArchiveBridge.files, (call) async {
      expect(call.method, 'connectStudent5g');
      expect(call.arguments, {
        'username': 'EXAMPLE',
        'password': 'Case-Sensitive-Password',
      });
      return {'ssid': 'Student-5G', 'ip': '10.72.88.93'};
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(IosArchiveBridge.files, null),
    );
    final campus = PortalFake()..user = 'EXAMPLE';
    final provider = IosAttendanceProvider(FakeProvider(), campus: campus);
    await provider.login(
      const Account(
        'Example',
        'example',
        'cas',
        networkPassword: 'Case-Sensitive-Password',
      ),
      (_) {},
    );
    expect(campus.calls, isEmpty);
    expect(campus.requests.every((p) => p['action'] == null), isTrue);
  });
  test(
    'Student-5G does not query or compare portal account identity',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        IosArchiveBridge.files,
        (call) async => {'ssid': 'Student-5G', 'ip': '10.72.88.93'},
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(IosArchiveBridge.files, null),
      );
      final campus =
          PortalFake(); // Its school account is deliberately different.
      final inner = FakeProvider();
      final provider = IosAttendanceProvider(inner, campus: campus);
      await provider.login(
        const Account('Example', 'example', 'cas', networkPassword: 'password'),
        (_) {},
      );
      expect(campus.calls, isEmpty);
      await provider.submit(course(), '1234');
      expect(inner.submissions, 1);
      expect(campus.requests, isEmpty);
    },
  );
  for (final code in [
    'IOS_WIFI_MANUAL_PROFILE',
    'IOS_WIFI_OLD_PROFILE',
    'IOS_WIFI_STATE_UNAVAILABLE',
  ]) {
    test(
      'native profile replacement failure $code stops login and preserves message',
      () async {
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(IosArchiveBridge.files, (
          call,
        ) async {
          throw PlatformException(code: code, message: '请先忽略旧 Student-5G');
        });
        addTearDown(
          () =>
              messenger.setMockMethodCallHandler(IosArchiveBridge.files, null),
        );
        final campus = PortalFake();
        final provider = IosAttendanceProvider(FakeProvider(), campus: campus);
        await expectLater(
          provider.login(
            const Account(
              'Example',
              'example',
              'cas',
              networkPassword: 'password',
            ),
            (_) {},
          ),
          throwsA(
            isA<AttendanceError>()
                .having((e) => e.code, 'code', code)
                .having((e) => e.message, 'message', '请先忽略旧 Student-5G'),
          ),
        );
        expect(campus.calls, isEmpty);
      },
    );
  }
  test(
    'switching students sends a complete new identity/password pair each time',
    () async {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final sent = <Map<dynamic, dynamic>>[];
      messenger.setMockMethodCallHandler(IosArchiveBridge.files, (call) async {
        expect(call.method, 'connectStudent5g');
        sent.add(Map<dynamic, dynamic>.from(call.arguments as Map));
        return {'ssid': 'Student-5G', 'ip': '10.72.88.93'};
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(IosArchiveBridge.files, null),
      );
      for (final account in [
        const Account('A', 'dummy-a', 'cas', networkPassword: 'Password-A'),
        const Account('B', 'dummy-b', 'cas', networkPassword: 'Password-B'),
      ]) {
        final provider = IosAttendanceProvider(
          FakeProvider(),
          campus: PortalFake(),
        );
        await provider.login(account, (_) {});
        await provider.close();
      }
      expect(sent, [
        {'username': 'DUMMY-A', 'password': 'Password-A'},
        {'username': 'DUMMY-B', 'password': 'Password-B'},
      ]);
    },
  );
  const password = 'offline-transfer-passphrase-123';
  test('iOS decrypts independent Android compatible crypto vector', () async {
    final bridge = IosArchiveBridge();
    final fixture = Uint8List.fromList(
      await File('test/fixtures/ios-archive.json').readAsBytes(),
    );
    expect(
      utf8.decode(await bridge.decrypt(fixture, password)),
      'Android-compatible archive fixture',
    );
    await expectLater(
      bridge.decrypt(fixture, 'incorrect-passphrase'),
      throwsFormatException,
    );
    final envelope = jsonDecode(utf8.decode(fixture)) as Map<String, dynamic>;
    final data = base64Decode(envelope['data'] as String);
    data[0] ^= 1;
    envelope['data'] = base64Encode(data);
    await expectLater(
      bridge.decrypt(
        Uint8List.fromList(utf8.encode(jsonEncode(envelope))),
        password,
      ),
      throwsFormatException,
    );
  });
  test('iOS encrypted archives are randomized and round trip', () async {
    final bridge = IosArchiveBridge();
    final payload = Uint8List.fromList(utf8.encode('fictional-account-data'));
    final first = await bridge.encrypt(payload, password);
    final second = await bridge.encrypt(payload, password);
    expect(first, isNot(orderedEquals(second)));
    expect(await bridge.decrypt(first, password), payload);
    expect(utf8.decode(first), isNot(contains('fictional-account-data')));
  });
}
