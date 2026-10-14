import 'dart:convert';
import 'dart:io';

import 'package:attendance_assistant/domain.dart';

import 'campus_network_test.dart' show PortalFake;
import 'domain_test.dart' show FakeProvider;

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
      (call) async => {'ssid': 'Student-5G', 'ip': '10.72.88.93'},
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
