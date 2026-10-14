import 'dart:async';

enum Stage {
  idle,
  statusPreparing,
  networkReady,
  networkFailed,
  academicReady,
  waitingNetwork,
  networkRouting,
  refreshingCourses,
  retryAcademic,
  networkChecking,
  networkConfiguring,
  networkApproval,
  networkEnterpriseReconnect,
  networkLogout,
  networkReconnect,
  networkLogin,
  networkVerifying,
  authenticating,
  loginConfig,
  loginTicket,
  navigating,
  identity,
  syncing,
  syncWarning,
  semester,
  discovering,
  choosing,
  opening,
  filling,
  submitting,
  verifying,
  cleaning,
  success,
  failed,
}

const stageLabels = {
  Stage.idle: '等待选择账号',
  Stage.statusPreparing: '等待后台状态查询结束',
  Stage.networkReady: '校园网准备完成',
  Stage.networkFailed: '校园网准备失败',
  Stage.academicReady: '教务登录与课程查询完成',
  Stage.waitingNetwork: '等待校园网与教务准备完成',
  Stage.networkRouting: '核验提交网络与校园网账号',
  Stage.refreshingCourses: '刷新签到课程状态',
  Stage.retryAcademic: '网络切换后恢复教务登录',
  Stage.networkChecking: '检查校园网准备状态',
  Stage.networkConfiguring: '准备 Student-5G 账号配置',
  Stage.networkApproval: '等待系统确认 Student-5G 配置',
  Stage.networkEnterpriseReconnect: '等待 Student-5G 重新认证',
  Stage.networkLogout: '注销当前校园网账号',
  Stage.networkReconnect: '等待重连并重新认证 Student Wi-Fi',
  Stage.networkLogin: '登录学生校园网账号',
  Stage.networkVerifying: '核验校园网账号',
  Stage.authenticating: '初始化 CAS 登录会话',
  Stage.loginConfig: '检查登录验证要求',
  Stage.loginTicket: '提交账号并获取登录票据',
  Stage.navigating: '建立教务登录会话',
  Stage.identity: '获取当前学生身份',
  Stage.syncing: '同步教务登录状态',
  Stage.syncWarning: '教务登录状态同步未完成',
  Stage.semester: '获取当前学期',
  Stage.discovering: '正在查找可签到课程',
  Stage.choosing: '选择本次课程',
  Stage.opening: '正在核对课程',
  Stage.filling: '核对签到方式与到场声明',
  Stage.submitting: '正在提交签到',
  Stage.verifying: '等待学校同步并核验签到记录',
  Stage.cleaning: '正在清理账号会话',
  Stage.success: '已完成',
  Stage.failed: '流程已停止',
};

const networkStages = {
  Stage.networkChecking,
  Stage.networkConfiguring,
  Stage.networkApproval,
  Stage.networkEnterpriseReconnect,
  Stage.networkLogout,
  Stage.networkReconnect,
  Stage.networkLogin,
  Stage.networkVerifying,
  Stage.networkReady,
  Stage.networkFailed,
};

const academicStages = {
  Stage.authenticating,
  Stage.loginConfig,
  Stage.loginTicket,
  Stage.navigating,
  Stage.identity,
  Stage.syncing,
  Stage.semester,
  Stage.discovering,
  Stage.academicReady,
  Stage.retryAcademic,
};

class Account {
  final String name, password;
  final String _campusId;
  String get campusId => _campusId.toUpperCase();
  final String networkPassword;
  final String acPassword;
  const Account(
    this.name,
    String campusId,
    this.password, {
    this.networkPassword = '',
    this.acPassword = '',
  }) : _campusId = campusId;
  Map<String, dynamic> toJson() => {
    'name': name,
    'campusId': campusId,
    'password': password,
    if (networkPassword.isNotEmpty) 'networkPassword': networkPassword,
    if (acPassword.isNotEmpty) 'acPassword': acPassword,
  };
  factory Account.fromJson(Map<String, dynamic> j) => Account(
    j['name'] as String,
    j['campusId'] as String,
    j['password'] as String,
    networkPassword: j['networkPassword'] as String? ?? '',
    acPassword: j['acPassword'] as String? ?? '',
  );
}

abstract interface class CampusPreparedProvider {}

class AttendanceError implements Exception {
  final String code, message;
  final Stage? stage;
  const AttendanceError(this.code, this.message, {this.stage});
  @override
  String toString() => message;
}

class Course {
  final Map<String, dynamic> data;
  Course(Map<String, dynamic> data) : data = Map.unmodifiable(data);
  String value(String key) => data[key]?.toString() ?? '';
  String get id =>
      '${value('settingId')}|${value('arrangeDate')}|${value('startClassTime')}|${value('courseCode')}';
  String get name => value('openGroupName');
  String get code => value('courseCode');
  String get room => value('roomName');
  String get time => '${value('startClassTime')}–${value('endClassTime')}';
  bool get signed =>
      value('attendanceStatus') == '1' && value('studentOtherStatus').isEmpty;
  bool get unsigned =>
      value('studentOtherStatus').isEmpty &&
      const ['0', 'pending'].contains(value('attendanceStatus'));
  String get attendanceLabel => signed
      ? '已签到'
      : value('studentOtherStatus').isNotEmpty
      ? '其他出勤状态'
      : unsigned
      ? '未签到'
      : '状态待确认';
  DateTime? get startsAt => _time('startClassTime');
  DateTime? get endsAt => _time('endClassTime');
  bool get codeMode => value('attendanceMethod') != '1';
  DateTime? _time(String key) {
    final date = value('arrangeDate').split('T').first.split(' ').first;
    final time = value(key);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(date) ||
        !RegExp(r'^\d{2}:\d{2}(:\d{2})?$').hasMatch(time)) {
      return null;
    }
    return DateTime.tryParse('${date}T$time+08:00');
  }

  bool current(DateTime now) {
    final start = _time('startClassTime'), end = _time('endClassTime');
    return start != null &&
        end != null &&
        !now.isBefore(start) &&
        now.isBefore(end) &&
        value('settingId').isNotEmpty &&
        code.isNotEmpty &&
        name.isNotEmpty;
  }

  bool eligible(DateTime now) {
    return current(now) &&
        value('backGroundColor') == '1' &&
        const ['0', 'pending'].contains(value('attendanceStatus')) &&
        value('studentOtherStatus').isEmpty &&
        value('studentCourseSign') != '2' &&
        !const ['true', '1'].contains(value('teacherMarkedAbsentLocked'));
  }
}

abstract interface class AttendanceProvider {
  Future<void> login(Account account, void Function(Stage) progress);
  Future<List<Course>> courses();
  Future<void> submit(Course course, String attendanceCode);
  Future<bool> verify(Course course);
  Future<void> close();
}

abstract interface class ParallelAttendanceProvider
    implements AttendanceProvider {
  Future<void> waitForNetwork();
  Future<void> activateSubmissionRoute();
}

abstract interface class SubmissionRouteAware {
  Future<void> resetConnections();
}

abstract interface class RetryableAcademicProvider {
  bool get canRestart;
  Future<void> restartLogin(Account account, void Function(Stage) progress);
}

class RunResult {
  final bool success, submitted;
  final String code, message;
  final Course? course;
  final Stage? failedStage;
  const RunResult(
    this.success,
    this.code,
    this.message, {
    this.course,
    this.submitted = false,
    this.failedStage,
  });
}

class AttendanceOrchestrator {
  bool busy = false;
  final AttendanceProvider Function() createProvider;
  final DateTime Function() clock;
  AttendanceOrchestrator(this.createProvider, {DateTime Function()? clock})
    : clock = clock ?? DateTime.now;

  RunResult _alreadySigned(List<Course> courses) => RunResult(
    true,
    'ALREADY_SIGNED',
    '学校记录显示已签到：${courses.map((c) => '${c.code} · ${c.name}').join('；')}。无需重复提交',
    course: courses.length == 1 ? courses.single : null,
  );
  Future<RunResult> run(
    Account account,
    String code, {
    required void Function(Stage) progress,
    required Future<Course?> Function(List<Course>) choose,
    bool inspectOnly = false,
    void Function(List<Course>)? onCourses,
    void Function(Stage, String)? onStepError,
  }) async {
    if (busy) {
      return const RunResult(false, 'BUSY', '请等待当前学生处理完成');
    }
    if (!inspectOnly && code.isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(code)) {
      return const RunResult(false, 'INVALID_CODE', '验证码请填写四位数字，或留空');
    }
    busy = true;
    AttendanceProvider? provider;
    var submitted = false;
    var verifying = false;
    Course? selectedCourse;
    Stage? academicStage;
    void advance(Stage stage) {
      if (!networkStages.contains(stage)) academicStage = stage;
      progress(stage);
    }

    try {
      provider = createProvider();
      advance(
        provider is CampusPreparedProvider
            ? Stage.networkChecking
            : Stage.authenticating,
      );
      await provider.login(account, advance);
      advance(Stage.discovering);
      academicStage = Stage.discovering;
      var all = await provider.courses();
      onCourses?.call(List.unmodifiable(all));
      if (provider is ParallelAttendanceProvider) {
        advance(Stage.academicReady);
        advance(Stage.waitingNetwork);
        await provider.waitForNetwork();
        advance(Stage.networkRouting);
        await provider.activateSubmissionRoute();
        advance(Stage.refreshingCourses);
        all = await provider.courses();
        onCourses?.call(List.unmodifiable(all));
      }
      final discoveredAt = clock();
      final active = all.where((c) => c.eligible(discoveredAt)).toList();
      if (inspectOnly) {
        return RunResult(
          true,
          'INSPECTED',
          '登录成功；查询到 ${all.length} 门当日课程，其中 ${active.length} 门符合签到条件。未提交签到。',
        );
      }
      if (active.isEmpty) {
        final signed = all
            .where((c) => c.current(discoveredAt) && c.signed)
            .toList();
        if (signed.isNotEmpty) return _alreadySigned(signed);
        return const RunResult(
          false,
          'NO_ACTIVE_CLASS',
          '当前没有可签到课程；本轮未提交签到。如已在学校页面签到，请以学校记录为准',
        );
      }
      advance(Stage.choosing);
      final course = active.length == 1 ? active.single : await choose(active);
      if (course == null) {
        throw const AttendanceError('CANCELLED', '已取消课程选择；未提交签到');
      }
      if (!active.any((c) => c.id == course.id)) {
        throw const AttendanceError('INVALID_SELECTION', '课程选择已失效');
      }
      advance(Stage.opening);
      final refreshed = await provider.courses();
      onCourses?.call(List.unmodifiable(refreshed));
      final current = refreshed.where((c) => c.id == course.id).toList();
      if (current.length != 1) {
        throw const AttendanceError('CLASS_CHANGED', '课程状态已变化；未提交签到');
      }
      final fresh = current.single;
      selectedCourse = fresh;
      if (fresh.signed) return _alreadySigned([fresh]);
      if (!fresh.eligible(clock())) {
        throw const AttendanceError('CLASS_CHANGED', '课程状态已变化；未提交签到');
      }
      advance(Stage.filling);
      if (fresh.codeMode && code.isEmpty) {
        throw const AttendanceError(
          'CODE_REQUIRED',
          '该课程要求四位验证码，请返回列表填写后重试；未提交签到',
        );
      }
      if (provider is ParallelAttendanceProvider) {
        advance(Stage.networkRouting);
        await provider.activateSubmissionRoute();
      }
      advance(Stage.submitting);
      submitted = true;
      await provider.submit(fresh, fresh.codeMode ? code : '');
      verifying = true;
      advance(Stage.verifying);
      if (!await provider.verify(fresh)) {
        throw const AttendanceError(
          'UNKNOWN',
          '签到已提交，学校记录暂未确认，请在学校页面核验后再决定是否重试',
        );
      }
      return RunResult(true, 'SUCCESS', '签到成功', course: fresh, submitted: true);
    } on AttendanceError catch (e) {
      if (submitted &&
          (verifying ||
              !const ['SERVER_REJECTED', 'CLASS_CHANGED'].contains(e.code))) {
        return RunResult(
          false,
          'UNKNOWN',
          verifying
              ? '签到已提交，学校记录暂未确认，请在学校页面核验后再决定是否重试'
              : '结果未确认，请在学校页面核验后再决定是否重试',
          submitted: true,
          course: selectedCourse,
        );
      }
      final failedStage =
          e.stage ??
          (provider is ParallelAttendanceProvider ? academicStage : null);
      if (failedStage != null) onStepError?.call(failedStage, e.message);
      return RunResult(
        false,
        e.code,
        e.message,
        submitted: submitted,
        course: selectedCourse,
        failedStage: failedStage,
      );
    } catch (_) {
      if (!submitted && academicStage != null) {
        onStepError?.call(academicStage!, '连接失败或服务不可用，请检查网络后重试');
      }
      return RunResult(
        false,
        submitted ? 'UNKNOWN' : 'NETWORK_ERROR',
        submitted ? '结果未确认：提交期间连接异常，请在学校页面核验' : '连接失败或服务不可用，请检查网络后重试',
        submitted: submitted,
        course: selectedCourse,
        failedStage: !submitted ? academicStage : null,
      );
    } finally {
      if (provider is ParallelAttendanceProvider) {
        try {
          await provider.waitForNetwork();
        } on AttendanceError catch (e) {
          if (e.stage != null) onStepError?.call(e.stage!, e.message);
        } catch (_) {}
      }
      advance(Stage.cleaning);
      try {
        await provider?.close();
      } finally {
        busy = false;
      }
    }
  }
}
