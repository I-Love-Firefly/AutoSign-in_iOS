import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:attendance_assistant/main.dart';
import 'package:attendance_assistant/account_store.dart';
import 'package:attendance_assistant/domain.dart';
import 'package:attendance_assistant/enterprise_network.dart';
import 'package:attendance_assistant/flow_progress_page.dart';
import 'package:attendance_assistant/portable_archive.dart';
import 'package:attendance_assistant/timetable.dart';

import 'domain_test.dart' show FakeProvider, course;
import 'enterprise_network_test.dart' as parallel;
import 'timetable_test.dart' as timetable_fixture;

class MemoryStore implements AccountStore {
  List<Account> accounts = [];
  @override
  Future<List<Account>> load() async => accounts;
  @override
  Future<void> save(List<Account> a) async {
    accounts = a;
  }
}

class EmptyTimetableFetcher implements TimetableFetcher {
  @override
  Future<StudentTimetable> fetch(
    Account account,
    void Function(String) progress,
  ) async => StudentTimetable(
    campusId: account.campusId,
    semester: '202609',
    fetchedAt: DateTime.utc(2026, 10, 6),
    lessons: [],
  );
}

void main() {
  testWidgets(
    'parallel lanes preserve pending network step while academic steps finish',
    (t) async {
      final e = parallel.EnterpriseFake()..approvalGate = Completer<void>();
      final inner = parallel.InnerFake();
      final provider = AdaptiveNetworkProvider(
        inner,
        enterprise: e,
        campus: parallel.CampusFake(),
        identityPollInterval: Duration.zero,
      );
      await t.pumpWidget(
        MaterialApp(
          home: FlowProgressPage(
            account: parallel.account,
            code: '',
            inspectOnly: true,
            providerFactory: () => provider,
          ),
        ),
      );
      await t.pumpAndSettle();
      final scroll = t.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(0);
      await t.pumpAndSettle();
      expect(find.text('校园网：等待系统确认 Student-5G 配置'), findsOneWidget);
      expect(find.text('教务：教务登录与课程查询完成'), findsOneWidget);
      final pending = find.byKey(const ValueKey('flow-networkApproval'));
      await t.ensureVisible(pending);
      expect(
        find.descendant(of: pending, matching: find.text('进行中')),
        findsOneWidget,
      );
      expect(inner.reads, 1);
      expect(inner.submits, 0);
      e.approvalGate!.complete();
      await t.pumpAndSettle();
      expect(find.text('返回列表'), findsOneWidget);
      expect(inner.submits, 0);
      expect(inner.closes, 1);
    },
  );
  testWidgets(
    'verified flow updates homepage without resubmitting or stale query override',
    (t) async {
      await t.binding.setSurfaceSize(const Size(430, 920));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final record = course({
        'courseCode': 'SOF201',
        'arrangeDate': '2026-10-06',
        'startClassTime': '17:00:00',
        'endClassTime': '19:00:00',
        'attendanceMethod': '1',
      });
      final flow = FakeProvider()..list = [record];
      final query = FakeProvider()..list = [record];
      await t.pumpWidget(
        AttendanceAssistant(
          store: MemoryStore()..accounts = [timetable_fixture.account],
          timetableStore: MemoryTimetableStore()
            ..schedules = {'test-001': timetable_fixture.table()},
          timetableFetcher: EmptyTimetableFetcher(),
          providerFactory: () => flow,
          statusProviderFactory: () => query,
          clock: () => timetable_fixture.now,
        ),
      );
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('Test'));
      await t.tap(find.text('Test'));
      await t.pumpAndSettle();
      expect(flow.submissions, 1);
      t.widget<ListView>(find.byType(ListView)).controller!.jumpTo(0);
      await t.pumpAndSettle();
      expect(find.text('已签到'), findsOneWidget);
      final scroll = t.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await t.pumpAndSettle();
      await t.ensureVisible(find.text('返回列表'));
      await t.tap(find.text('返回列表'));
      await t.pumpAndSettle();
      expect(
        find.text('正在上课（已签到）\nOperating Systems (Lab)\n地点：A1#105'),
        findsOneWidget,
      );
      expect(flow.submissions, 1);
      expect(query.submissions, 0);
    },
  );
  for (final signed in [true, false]) {
    testWidgets(
      'homepage displays current attendance signed=$signed with correct color',
      (t) async {
        final store = MemoryStore()..accounts = [timetable_fixture.account];
        final cache = MemoryTimetableStore()
          ..schedules = {'test-001': timetable_fixture.table()};
        final query = FakeProvider()
          ..list = [
            course({
              'courseCode': 'SOF201',
              'arrangeDate': '2026-10-06',
              'startClassTime': '17:00:00',
              'endClassTime': '19:00:00',
              'attendanceStatus': signed ? '1' : '0',
            }),
          ];
        await t.pumpWidget(
          AttendanceAssistant(
            store: store,
            timetableStore: cache,
            timetableFetcher: EmptyTimetableFetcher(),
            statusProviderFactory: () => query,
            clock: () => timetable_fixture.now,
          ),
        );
        await t.pumpAndSettle();
        final label = find.text(
          '正在上课（${signed ? '已签到' : '未签到'}）\nOperating Systems (Lab)\n地点：A1#105',
        );
        expect(label, findsOneWidget);
        final text = t.widget<Text>(label);
        expect(text.style?.color, const Color(0xFF18733C));
        final span = (text.textSpan as TextSpan).children![1] as TextSpan;
        expect(
          span.style?.color,
          signed ? const Color(0xFF18733C) : Colors.red,
        );
        expect(query.submissions, 0);
        expect(query.closes, 1);
      },
    );
  }
  testWidgets(
    'outside class hours shows all returned courses and read-only detail',
    (t) async {
      final provider = FakeProvider()
        ..list = [
          course({'openGroupName': 'Past class', 'attendanceStatus': '1'}),
          course({
            'settingId': 'future-session',
            'openGroupName': 'Future class',
            'startClassTime': '20:00:00',
            'endClassTime': '21:00:00',
          }),
        ];
      await t.pumpWidget(
        MaterialApp(
          home: FlowProgressPage(
            account: const Account('Test', 'TEST-001', 'fictional-password'),
            code: '',
            inspectOnly: false,
            providerFactory: () => provider,
            clock: () => DateTime.parse('2026-10-05T19:30:00+08:00'),
          ),
        ),
      );
      await t.pumpAndSettle();
      final scroll = t.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(0);
      await t.pumpAndSettle();
      expect(find.text('当天课程签到状态'), findsOneWidget);
      expect(find.text('已签到'), findsOneWidget);
      expect(find.text('未签到'), findsOneWidget);
      await t.ensureVisible(find.text('Future class'));
      await t.tap(find.text('Future class'));
      await t.pumpAndSettle();
      expect(find.textContaining('签到状态：未签到'), findsOneWidget);
      expect(find.textContaining('本页面仅查看记录，不提交签到'), findsOneWidget);
      expect(provider.submissions, 0);
      expect(provider.closes, 1);
    },
  );
  testWidgets(
    'cached current lesson appears on account and updates when it ends',
    (t) async {
      await t.binding.setSurfaceSize(const Size(430, 920));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final store = MemoryStore()..accounts = [timetable_fixture.account];
      final cache = MemoryTimetableStore()
        ..schedules = {'test-001': timetable_fixture.table()};
      var current = timetable_fixture.now;
      await t.pumpWidget(
        AttendanceAssistant(
          store: store,
          timetableStore: cache,
          timetableFetcher: EmptyTimetableFetcher(),
          statusProviderFactory: () => FakeProvider()..list = [],
          clock: () => current,
        ),
      );
      await t.pumpAndSettle();
      final lesson = find.text(
        '正在上课（状态待确认）\nOperating Systems (Lab)\n地点：A1#105',
      );
      expect(lesson, findsOneWidget);
      expect(t.widget<Text>(lesson).style?.color, const Color(0xFF18733C));
      expect(find.text('TEST-001'), findsOneWidget);
      expect(find.text('签到优先使用 Student-5G；切换账号需系统确认或手动修改网络配置'), findsOneWidget);
      current = DateTime.parse('2026-10-06T19:00:00+08:00');
      await t.pump(const Duration(seconds: 30));
      expect(lesson, findsNothing);
      expect(find.textContaining('当前无课'), findsNothing);
      expect(find.textContaining('未填写'), findsNothing);
      expect(find.textContaining('点击本人姓名开始签到'), findsNothing);
      final tile = find.ancestor(
        of: find.text('Test'),
        matching: find.byType(ListTile),
      );
      expect(
        t
            .widgetList<Text>(
              find.descendant(of: tile, matching: find.byType(Text)),
            )
            .map((text) => text.data),
        ['T', 'Test', 'TEST-001'],
      );
      await t.ensureVisible(tile);
      await t.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('查看课表'));
      await t.pumpAndSettle();
      expect(find.text('课表 · Test'), findsOneWidget);
      expect(find.textContaining('SOF201 · 17:00–19:00'), findsOneWidget);
    },
  );
  testWidgets('editor toggles each password independently', (t) async {
    await t.binding.setSurfaceSize(const Size(430, 920));
    addTearDown(() => t.binding.setSurfaceSize(null));
    await t.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AccountEditor(
            original: Account(
              'Test',
              'TEST-001',
              'old-password',
              networkPassword: 'old-network',
              acPassword: 'old-ac-password',
            ),
          ),
        ),
      ),
    );
    final system = find.widgetWithText(TextFormField, '签到系统密码');
    final network = find.widgetWithText(TextFormField, '校园网密码');
    final ac = find.widgetWithText(TextFormField, 'AC系统密码');
    expect(t.widget<TextFormField>(system).controller!.text, 'old-password');
    expect(t.widget<TextFormField>(network).controller!.text, 'old-network');
    expect(t.widget<TextFormField>(ac).controller!.text, 'old-ac-password');
    bool obscured(Finder field) => t
        .widget<EditableText>(
          find.descendant(of: field, matching: find.byType(EditableText)),
        )
        .obscureText;
    expect(obscured(system), isTrue);
    expect(obscured(network), isTrue);
    expect(obscured(ac), isTrue);
    await t.tap(find.byTooltip('显示校园网密码'));
    await t.pump();
    expect(obscured(network), isFalse);
    expect(obscured(system), isTrue);
    await t.tap(find.byTooltip('显示签到系统密码'));
    await t.pump();
    expect(obscured(system), isFalse);
    await t.tap(find.byTooltip('隐藏校园网密码'));
    await t.pump();
    expect(obscured(network), isTrue);
    expect(obscured(system), isFalse);
    await t.ensureVisible(find.byTooltip('显示AC系统密码'));
    await t.tap(find.byTooltip('显示AC系统密码'));
    await t.pump();
    expect(obscured(ac), isFalse);
    expect(obscured(network), isTrue);
    expect(obscured(system), isFalse);
    await t.tap(find.byTooltip('隐藏AC系统密码'));
    await t.pump();
    expect(obscured(ac), isTrue);
    expect(t.widget<TextFormField>(system).controller!.text, 'old-password');
    expect(t.widget<TextFormField>(network).controller!.text, 'old-network');
    expect(t.widget<TextFormField>(ac).controller!.text, 'old-ac-password');
  });
  testWidgets('encrypted export and import preview update duplicate accounts', (
    t,
  ) async {
    await t.binding.setSurfaceSize(const Size(430, 920));
    addTearDown(() => t.binding.setSurfaceSize(null));
    final store = MemoryStore()
      ..accounts = [const Account('旧账号', 'A001', 'old-password')];
    final archive = FakeArchiveBridge()
      ..incoming = [
        const Account('更新账号', 'a001', 'new-password'),
        const Account('新增账号', 'A002', 'another-password'),
      ];
    await t.pumpWidget(
      AttendanceAssistant(store: store, archiveBridge: archive),
    );
    await t.pumpAndSettle();
    await t.tap(find.text('加密导出'));
    await t.pumpAndSettle();
    await t.enterText(
      find.widgetWithText(TextFormField, '传输密码'),
      'test-transfer-password-123',
    );
    await t.enterText(
      find.widgetWithText(TextFormField, '再次输入传输密码'),
      'test-transfer-password-123',
    );
    await t.tap(find.text('加密并选择保存位置'));
    await t.pumpAndSettle();
    expect(archive.savedName, endsWith('.xmumaccounts'));
    expect(utf8.decode(archive.saved!), isNot(contains('old-password')));
    await t.tap(find.text('导入账号'));
    await t.pumpAndSettle();
    await t.enterText(
      find.widgetWithText(TextFormField, '传输密码'),
      'test-transfer-password-123',
    );
    await t.tap(find.text('解密并预览'));
    await t.pumpAndSettle();
    expect(find.textContaining('新增 1 个，已有 1 个'), findsOneWidget);
    expect(store.accounts.length, 1);
    await t.tap(find.text('更新重复并导入'));
    await t.pumpAndSettle();
    expect(store.accounts.length, 2);
    expect(
      store.accounts
          .singleWhere((a) => a.campusId.toLowerCase() == 'a001')
          .password,
      'new-password',
    );
  });

  testWidgets(
    'progress page preserves completed steps and shows failure at its step',
    (t) async {
      await t.binding.setSurfaceSize(const Size(430, 920));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final provider = FailingLoginProvider();
      await t.pumpWidget(
        MaterialApp(
          home: FlowProgressPage(
            account: const Account('测试学生', 'EXAMPLE', 'dummy'),
            code: '1234',
            inspectOnly: false,
            providerFactory: () => provider,
          ),
        ),
      );
      await t.pump();
      expect(find.textContaining('进行中 · 提交账号并获取登录票据'), findsOneWidget);
      final login = find.byKey(const ValueKey('flow-authenticating'));
      expect(
        find.descendant(of: login, matching: find.text('成功')),
        findsOneWidget,
      );
      provider.gate.complete();
      await t.pumpAndSettle();
      final ticket = find.byKey(const ValueKey('flow-loginTicket'));
      expect(
        find.descendant(of: ticket, matching: find.text('失败')),
        findsOneWidget,
      );
      expect(find.textContaining('测试账号密码错误'), findsNWidgets(2));
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('flow-cleaning')),
          matching: find.text('成功'),
        ),
        findsOneWidget,
      );
      expect(provider.closes, 1);
      expect(find.text('返回列表'), findsOneWidget);
    },
  );

  for (final alreadySigned in [true, false]) {
    testWidgets('discovery distinguishes signed=$alreadySigned from failure', (
      t,
    ) async {
      final today = DateTime.now().toUtc().add(const Duration(hours: 8));
      final provider = FakeProvider()
        ..list = alreadySigned
            ? [
                course({
                  'arrangeDate': today.toIso8601String().split('T').first,
                  'startClassTime': '00:00:00',
                  'endClassTime': '23:59:59',
                  'attendanceStatus': '1',
                  'backGroundColor': '2',
                }),
              ]
            : [];
      await t.pumpWidget(
        MaterialApp(
          home: FlowProgressPage(
            account: const Account('测试学生', 'EXAMPLE', 'dummy'),
            code: '',
            inspectOnly: false,
            providerFactory: () => provider,
          ),
        ),
      );
      await t.pumpAndSettle();
      final scroll = t.widget<ListView>(find.byType(ListView)).controller!;
      scroll.jumpTo(0);
      await t.pumpAndSettle();
      expect(
        find.textContaining(
          alreadySigned ? '成功 · 学校记录显示已签到' : '无需签到 · 当前没有可签到课程',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('已停止 ·'), findsNothing);
      scroll.jumpTo(scroll.position.maxScrollExtent);
      await t.pumpAndSettle();
      final discovery = find.byKey(const ValueKey('flow-discovering'));
      expect(
        find.descendant(of: discovery, matching: find.text('失败')),
        findsNothing,
      );
      expect(
        find.descendant(of: discovery, matching: find.text('成功')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('flow-submitting')), findsNothing);
      expect(provider.submissions, 0);
      expect(provider.closes, 1);
    });
  }

  testWidgets('submitted but unconfirmed record is shown as pending', (
    t,
  ) async {
    final today = DateTime.now().toUtc().add(const Duration(hours: 8));
    final provider = FakeProvider()
      ..confirmed = false
      ..list = [
        course({
          'arrangeDate': today.toIso8601String().split('T').first,
          'startClassTime': '00:00:00',
          'endClassTime': '23:59:59',
          'attendanceMethod': '1',
        }),
      ];
    await t.pumpWidget(
      MaterialApp(
        home: FlowProgressPage(
          account: const Account('测试学生', 'EXAMPLE', 'dummy'),
          code: '',
          inspectOnly: false,
          providerFactory: () => provider,
        ),
      ),
    );
    await t.pumpAndSettle();
    final scroll = t.widget<ListView>(find.byType(ListView)).controller!;
    scroll.jumpTo(0);
    await t.pumpAndSettle();
    expect(find.textContaining('待确认 · 签到已提交'), findsOneWidget);
    expect(find.textContaining('已停止 ·'), findsNothing);
    scroll.jumpTo(scroll.position.maxScrollExtent);
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('flow-verifying')),
        matching: find.text('警告'),
      ),
      findsOneWidget,
    );
    expect(provider.submissions, 1);
    expect(provider.closes, 1);
  });

  testWidgets('cleanup failure is shown on cleanup step instead of hanging', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: FlowProgressPage(
          account: const Account('测试学生', 'EXAMPLE', 'dummy'),
          code: '',
          inspectOnly: true,
          providerFactory: () => CleanupFailureProvider(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(find.textContaining('清理登录会话时发生错误'), findsNWidgets(2));
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('flow-cleaning')),
        matching: find.text('失败'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('sync warning stays visible while course inspection succeeds', (
    t,
  ) async {
    await t.pumpWidget(
      MaterialApp(
        home: FlowProgressPage(
          account: const Account('测试学生', 'EXAMPLE', 'dummy'),
          code: '',
          inspectOnly: true,
          providerFactory: () => SyncWarningProvider(),
        ),
      ),
    );
    await t.pumpAndSettle();
    expect(
      find.descendant(
        of: find.byKey(const ValueKey('flow-syncing')),
        matching: find.text('警告'),
      ),
      findsOneWidget,
    );
    await t.drag(find.byType(ListView).first, const Offset(0, 1000));
    await t.pumpAndSettle();
    expect(find.textContaining('登录成功；查询到'), findsOneWidget);
  });

  testWidgets(
    'add, persist in store, search, inspect, edit and delete account',
    (t) async {
      await t.binding.setSurfaceSize(const Size(430, 920));
      addTearDown(() => t.binding.setSurfaceSize(null));
      final store = MemoryStore();
      final p = FakeProvider()..list = [];
      await t.pumpWidget(
        AttendanceAssistant(
          store: store,
          providerFactory: () => p,
          timetableFetcher: EmptyTimetableFetcher(),
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('增加账号'), findsOneWidget);
      await t.tap(find.text('增加账号'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextFormField, '学生姓名 / 备注'),
        'Test Student',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, 'Campus ID'),
        'tEsT-001',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, '签到系统密码'),
        'private-test-password',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, '校园网密码'),
        'private-network-password',
      );
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.accounts.single.campusId, 'TEST-001');
      expect(store.accounts.single.networkPassword, 'private-network-password');
      expect(store.accounts.single.acPassword, '');
      expect(find.text('Test Student'), findsOneWidget);
      final tile = find.ancestor(
        of: find.text('Test Student'),
        matching: find.byType(ListTile),
      );
      expect(t.widget<ListTile>(tile).onTap, isNotNull);
      await t.enterText(find.byKey(const ValueKey('attendance-code')), '12');
      await t.pump();
      expect(t.widget<ListTile>(tile).onTap, isNull);
      await t.enterText(find.byKey(const ValueKey('attendance-code')), '1234');
      await t.pump();
      expect(t.widget<ListTile>(tile).onTap, isNotNull);
      await t.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('测试登录 / 查询（不签到）'));
      await t.pumpAndSettle();
      expect(p.submissions, 0);
      expect(find.textContaining('未提交签到'), findsOneWidget);
      await t.tap(find.text('返回列表'));
      await t.pumpAndSettle();
      await t.tap(
        find.descendant(
          of: tile,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('编辑账号'));
      await t.pumpAndSettle();
      await t.enterText(
        find.widgetWithText(TextFormField, '学生姓名 / 备注'),
        'Renamed',
      );
      await t.enterText(
        find.widgetWithText(TextFormField, 'AC系统密码'),
        'private-ac-password',
      );
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.accounts.single.password, 'private-test-password');
      expect(store.accounts.single.networkPassword, 'private-network-password');
      expect(store.accounts.single.acPassword, 'private-ac-password');
      final renamed = find.ancestor(
        of: find.text('Renamed'),
        matching: find.byType(ListTile),
      );
      await t.tap(
        find.descendant(
          of: renamed,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('编辑账号'));
      await t.pumpAndSettle();
      await t.tap(find.text('保存'));
      await t.pumpAndSettle();
      expect(store.accounts.single.acPassword, 'private-ac-password');
      await t.tap(
        find.descendant(
          of: renamed,
          matching: find.byType(PopupMenuButton<String>),
        ),
      );
      await t.pumpAndSettle();
      await t.tap(find.text('删除账号'));
      await t.pumpAndSettle();
      expect(store.accounts, isNotEmpty);
      await t.tap(find.text('删除'));
      await t.pumpAndSettle();
      expect(store.accounts, isEmpty);
    },
  );
  testWidgets('storage load failure does not permit overwriting accounts', (
    t,
  ) async {
    await t.pumpWidget(AttendanceAssistant(store: BrokenStore()));
    await t.pumpAndSettle();
    expect(find.textContaining('无法读取安全存储'), findsOneWidget);
    expect(
      t
          .widget<FilledButton>(find.widgetWithText(FilledButton, '增加账号'))
          .onPressed,
      isNull,
    );
  });
}

class FailingLoginProvider implements AttendanceProvider {
  final gate = Completer<void>();
  int closes = 0;
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    progress(Stage.loginConfig);
    progress(Stage.loginTicket);
    await gate.future;
    throw const AttendanceError('AUTH_FAILED', '测试账号密码错误');
  }

  @override
  Future<List<Course>> courses() async => throw StateError('not reached');
  @override
  Future<void> submit(Course course, String code) async =>
      throw StateError('not reached');
  @override
  Future<bool> verify(Course course) async => throw StateError('not reached');
  @override
  Future<void> close() async {
    closes++;
  }
}

class BrokenStore implements AccountStore {
  @override
  Future<List<Account>> load() async => throw Exception('unavailable');
  @override
  Future<void> save(List<Account> accounts) async =>
      throw StateError('must not overwrite');
}

class FakeArchiveBridge implements ArchiveBridge {
  List<Account> incoming = [];
  Uint8List? saved;
  String? savedName;
  @override
  Future<Uint8List> encrypt(Uint8List plaintext, String passphrase) async {
    expect(passphrase, 'test-transfer-password-123');
    expect(PortableAccounts.decode(plaintext).length, 1);
    return Uint8List.fromList(utf8.encode('encrypted-fixture'));
  }

  @override
  Future<Uint8List> decrypt(Uint8List archive, String passphrase) async {
    expect(passphrase, 'test-transfer-password-123');
    return PortableAccounts.encode(incoming);
  }

  @override
  Future<Uint8List?> open() async =>
      Uint8List.fromList(utf8.encode('encrypted-fixture'));
  @override
  Future<bool> save(Uint8List archive, String filename) async {
    saved = archive;
    savedName = filename;
    return true;
  }
}

class CleanupFailureProvider implements AttendanceProvider {
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {}
  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<void> submit(Course course, String code) async =>
      throw StateError('not reached');
  @override
  Future<bool> verify(Course course) async => throw StateError('not reached');
  @override
  Future<void> close() async => throw StateError('cleanup unavailable');
}

class SyncWarningProvider implements AttendanceProvider {
  @override
  Future<void> login(Account account, void Function(Stage) progress) async {
    progress(Stage.syncing);
    progress(Stage.syncWarning);
    progress(Stage.semester);
  }

  @override
  Future<List<Course>> courses() async => [];
  @override
  Future<void> submit(Course course, String code) async =>
      throw StateError('not reached');
  @override
  Future<bool> verify(Course course) async => throw StateError('not reached');
  @override
  Future<void> close() async {}
}
