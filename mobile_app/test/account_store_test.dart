import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/account_store.dart';
import 'package:attendance_assistant/domain.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('mixed-case model and JSON normalize only Campus ID letters', () {
    const account = Account(
      'Mixed Name',
      'sWe1234567',
      'SiGnPaSs',
      networkPassword: 'WiFiPaSs',
      acPassword: 'AcPaSs',
    );
    expect(account.campusId, 'SWE1234567');
    final decoded = Account.fromJson(account.toJson());
    expect(decoded.campusId, 'SWE1234567');
    expect(decoded.name, 'Mixed Name');
    expect(decoded.password, 'SiGnPaSs');
    expect(decoded.networkPassword, 'WiFiPaSs');
    expect(decoded.acPassword, 'AcPaSs');
  });
  test('loading legacy secure records persists uppercase IDs and keeps credentials', () async {
    final original = {
      'name': 'Fixture',
      'campusId': 'sWe1234567',
      'password': 'SiGnPaSs',
      'networkPassword': 'WiFiPaSs',
      'acPassword': 'AcPaSs',
      'legacyMetadata': {'marker': 'keep'},
    };
    FlutterSecureStorage.setMockInitialValues({
      SecureAccountStore.key: jsonEncode([original]),
    });
    final store = SecureAccountStore();
    expect((await store.load()).single.campusId, 'SWE1234567');
    final saved = jsonDecode(
      (await store.storage.read(key: SecureAccountStore.key))!,
    ) as List;
    expect(saved.single, {...original, 'campusId': 'SWE1234567'});
    expect((await store.load()).single.password, 'SiGnPaSs');
  });
}
