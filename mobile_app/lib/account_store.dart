import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'domain.dart';

abstract interface class AccountStore {
  Future<List<Account>> load();
  Future<void> save(List<Account> accounts);
}

class SecureAccountStore implements AccountStore {
  final FlutterSecureStorage storage;
  SecureAccountStore({FlutterSecureStorage? storage})
    : storage =
          storage ??
          const FlutterSecureStorage(
            aOptions: AndroidOptions(resetOnError: false),
          );
  static const key = 'xmum_accounts_v1';
  @override
  Future<List<Account>> load() async {
    final raw = await storage.read(key: key);
    if (raw == null) {
      return [];
    }
    final rows = (jsonDecode(raw) as List)
        .map((e) => Map<String, dynamic>.from(e))
        .toList();
    final accounts = rows.map(Account.fromJson).toList();
    if (rows.asMap().entries.any(
      (entry) => entry.value['campusId'] != accounts[entry.key].campusId,
    )) {
      // Migrate only the ID, retaining credentials and any legacy metadata.
      await storage.write(
        key: key,
        value: jsonEncode([
          for (var i = 0; i < rows.length; i++)
            {...rows[i], 'campusId': accounts[i].campusId},
        ]),
      );
    }
    return accounts;
  }

  @override
  Future<void> save(List<Account> accounts) => storage.write(
    key: key,
    value: jsonEncode(accounts.map((a) => a.toJson()).toList()),
  );
}
