import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/ios_adapters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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
