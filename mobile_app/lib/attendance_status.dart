import 'dart:async';

import 'package:flutter/foundation.dart';

import 'domain.dart';
import 'timetable.dart';

/// Read-only academic sessions, separate from campus Wi-Fi switching.
class AttendanceStatusController extends ChangeNotifier {
  final AttendanceProvider Function() createProvider;
  final DateTime Function() clock;
  final Map<String, List<Course>> _records = {};
  final Map<String, DateTime> _readAt = {}, _attemptAt = {};
  Map<String, Account> _accounts = {};
  final Set<String> _queued = {};
  Future<void> _tail = Future.value();
  bool _paused = false, _disposed = false;
  AttendanceStatusController({
    required this.createProvider,
    required this.clock,
  });

  String _id(Account a) => a.campusId.toLowerCase();
  void _emit() {
    if (!_disposed) notifyListeners();
  }

  void updateAccounts(List<Account> accounts) {
    final next = {for (final a in accounts) _id(a): a};
    for (final key in _accounts.keys) {
      if (next[key]?.password != _accounts[key]?.password) {
        _records.remove(key);
        _readAt.remove(key);
        _attemptAt.remove(key);
      }
    }
    _accounts = next;
  }

  void record(Account a, List<Course> courses) {
    if (_disposed || _accounts[_id(a)]?.password != a.password) return;
    _records[_id(a)] = List.unmodifiable(courses);
    _readAt[_id(a)] = clock();
    _attemptAt[_id(a)] = clock();
    _emit();
  }

  Course? forLesson(Account a, Lesson lesson) {
    final key = _id(a), read = _readAt[_id(a)], now = clock();
    if (read == null ||
        now.isBefore(read) ||
        now.difference(read) > const Duration(minutes: 3)) {
      return null;
    }
    final matches = (_records[key] ?? []).where((c) {
      final start = c.startsAt, end = c.endsAt;
      if (start == null || end == null || !c.current(now)) return false;
      final localStart = malaysiaTime(start), localEnd = malaysiaTime(end);
      return c.code.trim().toLowerCase() == lesson.code.trim().toLowerCase() &&
          localStart.hour * 60 + localStart.minute == lesson.start &&
          localEnd.hour * 60 + localEnd.minute == lesson.end;
    }).toList();
    return matches.length == 1 ? matches.single : null;
  }

  void refresh(Account a) {
    final key = _id(a), last = _attemptAt[_id(a)], now = clock();
    if (_disposed ||
        _paused ||
        _queued.contains(key) ||
        (last != null &&
            !now.isBefore(last) &&
            now.difference(last) < const Duration(minutes: 2))) {
      return;
    }
    _attemptAt[key] = now;
    _queued.add(key);
    _tail = _tail.then((_) async {
      AttendanceProvider? provider;
      try {
        if (_disposed || _paused || _accounts[key]?.password != a.password) {
          _attemptAt.remove(key);
          return;
        }
        provider = createProvider();
        await provider.login(a, (_) {});
        final courses = await provider.courses();
        record(a, courses);
      } catch (_) {
        // A failed query is not evidence that attendance is incomplete.
        if (_accounts[key]?.password == a.password) {
          _records.remove(key);
          _readAt.remove(key);
        }
      } finally {
        try {
          await provider?.close();
        } catch (_) {}
        _queued.remove(key);
        _emit();
      }
    });
  }

  Future<void> pause() async {
    _paused = true;
    await _tail;
  }

  void resume() => _paused = false;

  void applyResult(Account a, RunResult result) {
    final c = result.course;
    if (result.code == 'SUCCESS' && c != null) {
      final existing = _records[_id(a)] ?? [];
      record(a, [
        for (final item in existing)
          if (item.id != c.id) item,
        Course({
          ...c.data,
          'attendanceStatus': '1',
          'studentOtherStatus': null,
        }),
      ]);
    } else if (const ['UNKNOWN', 'CLEANUP_FAILED'].contains(result.code)) {
      _records.remove(_id(a));
      _readAt.remove(_id(a));
      _emit();
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _paused = true;
    super.dispose();
  }
}
