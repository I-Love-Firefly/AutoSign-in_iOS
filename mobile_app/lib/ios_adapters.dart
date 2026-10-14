import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/services.dart';
import 'package:file_selector/file_selector.dart';

import 'campus_network.dart';
import 'domain.dart';
import 'portable_archive.dart';

/// Matches the Android archive envelope, including its authenticated data.
class IosArchiveBridge implements ArchiveBridge {
  static const files = MethodChannel('com.xmum.attendance_assistant/ios');
  final cipher = AesGcm.with256bits();
  final kdf = Pbkdf2(
    macAlgorithm: Hmac.sha256(),
    iterations: 310000,
    bits: 256,
  );
  final aad = utf8.encode('XMUM_ACCOUNT_ARCHIVE_V1');
  Future<SecretKey> key(String password, List<int> salt) =>
      kdf.deriveKey(secretKey: SecretKey(utf8.encode(password)), nonce: salt);
  void validate(Uint8List data, String password) {
    if (data.length > PortableAccounts.maxBytes || password.length < 12) {
      throw const FormatException('文件或传输密码无效');
    }
  }

  @override
  Future<Uint8List> encrypt(Uint8List plaintext, String passphrase) async {
    validate(plaintext, passphrase);
    final salt = SecretKeyData.random(length: 16).bytes;
    final box = await cipher.encrypt(
      plaintext,
      secretKey: await key(passphrase, salt),
      aad: aad,
    );
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'format': 'xmum-attendance-accounts-encrypted',
          'version': 1,
          'kdf': 'PBKDF2-HMAC-SHA256',
          'iterations': 310000,
          'cipher': 'AES-256-GCM',
          'salt': base64Encode(salt),
          'nonce': base64Encode(box.nonce),
          'data': base64Encode([...box.cipherText, ...box.mac.bytes]),
        }),
      ),
    );
  }

  @override
  Future<Uint8List> decrypt(Uint8List archive, String passphrase) async {
    validate(archive, passphrase);
    try {
      final m = jsonDecode(utf8.decode(archive)) as Map;
      if (m['format'] != 'xmum-attendance-accounts-encrypted' ||
          m['version'] != 1 ||
          m['kdf'] != 'PBKDF2-HMAC-SHA256' ||
          m['iterations'] != 310000 ||
          m['cipher'] != 'AES-256-GCM') {
        throw const FormatException();
      }
      final salt = base64Decode(m['salt'] as String);
      final nonce = base64Decode(m['nonce'] as String);
      final data = base64Decode(m['data'] as String);
      if (salt.length != 16 || nonce.length != 12 || data.length < 16) {
        throw const FormatException();
      }
      return Uint8List.fromList(
        await cipher.decrypt(
          SecretBox(
            data.sublist(0, data.length - 16),
            nonce: nonce,
            mac: Mac(data.sublist(data.length - 16)),
          ),
          secretKey: await key(passphrase, salt),
          aad: aad,
        ),
      );
    } catch (_) {
      throw const FormatException('传输密码错误或文件已损坏');
    }
  }

  @override
  Future<bool> save(Uint8List archive, String filename) async =>
      await files.invokeMethod<bool>('save', {
        'bytes': archive,
        'name': filename,
      }) ==
      true;
  @override
  Future<Uint8List?> open() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: '账号档案',
          uniformTypeIdentifiers: ['public.data'],
        ),
      ],
    );
    if (file == null) return null;
    if (await file.length() > PortableAccounts.maxBytes) {
      throw const FormatException('账号文件过大');
    }
    return file.readAsBytes();
  }
}

/// iOS users join Student in Settings; portal credentials switch in-app.
/// The school identity must match before any attendance submission.
class IosAttendanceProvider
    implements AttendanceProvider, CampusPreparedProvider {
  final AttendanceProvider inner;
  final CampusTransport campus;
  Account? _account;
  String? _ip;
  IosAttendanceProvider(this.inner, {CampusTransport? campus})
    : campus = campus ?? AndroidCampusTransport();
  Future<void> check() async {
    final ip = await campus.bind();
    if (_ip != null && ip != _ip) {
      throw const AttendanceError('NETWORK_ADDRESS', 'Wi-Fi 地址已变化，请重新开始');
    }
    final status = await campus.get('/cgi-bin/rad_user_info', {'ip': ip});
    if (status['error'] != 'ok' ||
        (status['online_ip'] ?? status['client_ip']) != ip ||
        '${status['user_name']}'.toUpperCase() !=
            _account!.campusId.toUpperCase()) {
      throw const AttendanceError(
        'NETWORK_IDENTITY',
        '请在 iPhone 设置连接 Student；校园网身份未确认，未提交签到',
      );
    }
    _ip = ip;
  }

  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    _account = account;
    progress(Stage.networkConfiguring);
    try {
      final link = await IosArchiveBridge.files
          .invokeMapMethod<String, dynamic>('connectStudent');
      if (link?['ssid'] != 'Student' ||
          link?['ip'] is! String ||
          !(link!['ip'] as String).startsWith('10.')) {
        throw const AttendanceError(
          'IOS_WIFI_NOT_CONFIRMED',
          '尚未确认 Student 连接，未切换账号或提交签到',
        );
      }
      if (await campus.bind() != link['ip']) {
        throw const AttendanceError('NETWORK_ADDRESS', '连接地址已变化，未切换账号或提交签到');
      }
    } on PlatformException catch (e) {
      throw AttendanceError(e.code, e.message ?? '自动连接 Student 失败');
    }
    await CampusNetwork(campus)
        .switchAccount(account, progress, reconnectWifi: false);
    await check();
    progress(Stage.authenticating);
    await inner.login(account, progress);
  }

  @override
  Future<List<Course>> courses() => inner.courses();
  @override
  Future<void> submit(Course course, String code) async {
    await check();
    await inner.submit(course, code);
  }

  @override
  Future<bool> verify(Course course) => inner.verify(course);
  @override
  Future<void> close() async {
    try {
      await inner.close();
    } finally {
      await campus.release();
    }
  }
}
