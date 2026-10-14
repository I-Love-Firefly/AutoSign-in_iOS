import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/attendance_status.dart';
import 'package:attendance_assistant/domain.dart';

import 'domain_test.dart' show FakeProvider, course;
import 'timetable_test.dart' as fixture;

Course record([Map<String, dynamic> changes = const {}]) => course({
  'courseCode': 'SOF201',
  'arrangeDate': '2026-10-06',
  'startClassTime': '17:00:00',
  'endClassTime': '19:00:00',
  ...changes,
});

void main() {
  test(
    'failed refresh clears prior unsigned status instead of guessing',
    () async {
      final p = FakeProvider()
        ..loginError = const AttendanceError('AUTH_FAILED', 'fixture failure');
      var now = fixture.now;
      final c = AttendanceStatusController(
        createProvider: () => p,
        clock: () => now,
      );
      addTearDown(c.dispose);
      c.updateAccounts([fixture.account]);
      c.record(fixture.account, [record()]);
      now = now.add(const Duration(minutes: 2));
      c.refresh(fixture.account);
      await Future<void>.delayed(Duration.zero);
      await c.pause();
      expect(
        c.forLesson(fixture.account, fixture.table().lessons.single),
        isNull,
      );
      expect(p.closes, 1);
      expect(p.submissions, 0);
    },
  );
  test(
    'queries are throttled and deleted accounts cannot regain cached status',
    () async {
      var now = fixture.now;
      var queries = 0;
      final c = AttendanceStatusController(
        createProvider: () {
          queries++;
          return FakeProvider()..list = [record()];
        },
        clock: () => now,
      );
      addTearDown(c.dispose);
      c.updateAccounts([fixture.account]);
      c.refresh(fixture.account);
      await Future<void>.delayed(Duration.zero);
      await c.pause();
      c.resume();
      now = now.add(const Duration(seconds: 30));
      c.refresh(fixture.account);
      await Future<void>.delayed(Duration.zero);
      expect(queries, 1);
      now = now.add(const Duration(minutes: 2));
      c.refresh(fixture.account);
      await Future<void>.delayed(Duration.zero);
      await c.pause();
      expect(queries, 2);
      c.updateAccounts([]);
      c.record(fixture.account, [
        record({'attendanceStatus': '1'}),
      ]);
      expect(
        c.forLesson(fixture.account, fixture.table().lessons.single),
        isNull,
      );
    },
  );
  test('read-only refresh isolates accounts and never submits', () async {
    final p = FakeProvider()
      ..list = [
        record({'attendanceStatus': '1'}),
      ];
    final c = AttendanceStatusController(
      createProvider: () => p,
      clock: () => fixture.now,
    );
    addTearDown(c.dispose);
    const other = Account('Other', 'TEST-002', 'fictional-password');
    c.updateAccounts([fixture.account, other]);
    c.refresh(fixture.account);
    await Future<void>.delayed(Duration.zero);
    await c.pause();
    final lesson = fixture.table().lessons.single;
    expect(c.forLesson(fixture.account, lesson)?.signed, isTrue);
    expect(c.forLesson(other, lesson), isNull);
    expect(p.submissions, 0);
    expect(p.closes, 1);
  });
  test(
    'different day, period or ambiguous activity never supplies a status',
    () {
      final c = AttendanceStatusController(
        createProvider: () => FakeProvider(),
        clock: () => fixture.now,
      );
      addTearDown(c.dispose);
      c.updateAccounts([fixture.account]);
      final lesson = fixture.table().lessons.single;
      for (final records in [
        [
          record({'arrangeDate': '2026-10-05', 'attendanceStatus': '1'}),
        ],
        [
          record({'startClassTime': '16:00:00', 'attendanceStatus': '1'}),
        ],
        [
          record({'courseCode': 'OTHER', 'attendanceStatus': '1'}),
        ],
        [
          record(),
          record({'settingId': 'another-session'}),
        ],
      ]) {
        c.record(fixture.account, records);
        expect(c.forLesson(fixture.account, lesson), isNull);
      }
    },
  );
  test('stale status and changed credentials are not reused', () {
    var now = fixture.now;
    final c = AttendanceStatusController(
      createProvider: () => FakeProvider(),
      clock: () => now,
    );
    addTearDown(c.dispose);
    c.updateAccounts([fixture.account]);
    final lesson = fixture.table().lessons.single;
    c.record(fixture.account, [record()]);
    expect(c.forLesson(fixture.account, lesson)?.unsigned, isTrue);
    now = now.add(const Duration(minutes: 4));
    expect(c.forLesson(fixture.account, lesson), isNull);
    now = fixture.now;
    c.updateAccounts([
      const Account('Test', 'TEST-001', 'changed-fictional-password'),
    ]);
    expect(c.forLesson(fixture.account, lesson), isNull);
  });
  test('unknown submission invalidates unsigned status, verified success updates it', () {
    final c = AttendanceStatusController(
      createProvider: () => FakeProvider(),
      clock: () => fixture.now,
    );
    addTearDown(c.dispose);
    c.updateAccounts([fixture.account]);
    final lesson = fixture.table().lessons.single;
    c.record(fixture.account, [record()]);
    c.applyResult(
      fixture.account,
      RunResult(false, 'UNKNOWN', 'pending', course: record(), submitted: true),
    );
    expect(c.forLesson(fixture.account, lesson), isNull);
    c.applyResult(
      fixture.account,
      RunResult(
        true,
        'SUCCESS',
        'confirmed',
        course: record(),
        submitted: true,
      ),
    );
    expect(c.forLesson(fixture.account, lesson)?.signed, isTrue);
  });
  test(
    'pause waits for running query and skips queued network logins',
    () async {
      final p = FakeProvider()..gate = Completer<void>();
      var created = 0;
      final c = AttendanceStatusController(
        createProvider: () {
          created++;
          return p;
        },
        clock: () => fixture.now,
      );
      addTearDown(c.dispose);
      const other = Account('Other', 'TEST-002', 'fictional-password');
      c.updateAccounts([fixture.account, other]);
      c.refresh(fixture.account);
      await Future<void>.delayed(Duration.zero);
      c.refresh(other);
      final paused = c.pause();
      p.gate!.complete();
      await paused;
      expect(created, 1);
      expect(p.closes, 1);
      expect(p.submissions, 0);
    },
  );
}
