import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import 'domain.dart';

enum StepStatus { waiting, running, success, warning, failed }

class FlowStep {
  final Stage stage;
  StepStatus status;
  DateTime? startedAt, finishedAt;
  String? detail;
  FlowStep(this.stage) : status = StepStatus.waiting;
}

class FlowProgressPage extends StatefulWidget {
  final Account account;
  final String code;
  final bool inspectOnly;
  final AttendanceProvider Function() providerFactory;
  final DateTime Function()? clock;
  final void Function(List<Course>)? onCourses;
  final void Function(RunResult)? onResult;
  final Future<void> Function()? beforeStart;
  const FlowProgressPage({
    super.key,
    required this.account,
    required this.code,
    required this.inspectOnly,
    required this.providerFactory,
    this.clock,
    this.onCourses,
    this.onResult,
    this.beforeStart,
  });

  @override
  State<FlowProgressPage> createState() => _FlowProgressPageState();
}

class _FlowProgressPageState extends State<FlowProgressPage> {
  final ScrollController _scroll = ScrollController();
  static const _order = [
    Stage.statusPreparing,
    Stage.networkChecking,
    Stage.networkConfiguring,
    Stage.networkApproval,
    Stage.networkEnterpriseReconnect,
    Stage.networkLogout,
    Stage.networkReconnect,
    Stage.networkLogin,
    Stage.networkVerifying,
    Stage.networkReady,
    Stage.authenticating,
    Stage.retryAcademic,
    Stage.loginConfig,
    Stage.loginTicket,
    Stage.navigating,
    Stage.identity,
    Stage.syncing,
    Stage.semester,
    Stage.discovering,
    Stage.academicReady,
    Stage.waitingNetwork,
    Stage.networkRouting,
    Stage.refreshingCourses,
    Stage.choosing,
    Stage.opening,
    Stage.filling,
    Stage.submitting,
    Stage.verifying,
    Stage.cleaning,
  ];
  static const _details = {
    Stage.statusPreparing: '暂停后台签到状态查询，等待已开始的查询完成并清理会话，再进行本轮流程',
    Stage.networkChecking: '读取校园网方式并核对账号资料；Student 旧版另查询当前认证账号和接入参数',
    Stage.networkConfiguring: '检查校园网密码、连接识别权限与共用认证设置；Student-5G 使用企业网络认证',
    Stage.networkApproval: '在系统页面确认保存当前学生的 Student-5G 配置；取消时停止，不继续签到',
    Stage.networkEnterpriseReconnect: '先等待系统自动重连；若弹出 Wi-Fi 设置，请关闭再开启 Wi-Fi、连接 Student-5G 并返回。手动模式需先修改身份和密码；最多等待 3 分钟',
    Stage.networkLogout: '读取本机实际在线账号，先解除设备绑定，再注销该账号的网络会话；连续确认离线后才重连',
    Stage.networkReconnect: '关闭再开启 Wi-Fi，重新连接 Student 并返回本页，无需等待“需要登录”提示。应用会通过学校接口连续确认已离线，再登录当前学生；不要在网页手动登录，最多等待 3 分钟',
    Stage.networkLogin: '重新读取当前接入点认证参数、获取挑战值，使用独立校园网密码登录',
    Stage.networkVerifying: '确认在线账号与所选学生一致；教务登录在另一条流程中并行进行',
    Stage.networkReady: '校园网切换和身份核验已完成，等待教务准备完成',
    Stage.academicReady: '后台已完成教务登录和首次课程读取，等待前台校园网操作完成',
    Stage.waitingNetwork: '两条流程均成功后才继续；任何一条失败都不会提交签到',
    Stage.networkRouting: '固定请求到已核验的校园网，再次检查账号并重建 HTTP 连接，保留教务会话',
    Stage.refreshingCourses: '网络操作完成后重新读取课程，避免使用等待期间已变化的状态',
    Stage.retryAcademic: '切换网络时连接中断，仅在网络就绪后恢复一次教务登录和课程读取；不重试签到提交',
    Stage.authenticating: 'GET /lyuapServer/login · 建立 CAS Cookie',
    Stage.loginConfig: 'GET /lyuapServer/loginType · 检查额外验证',
    Stage.loginTicket: 'POST /lyuapServer/v1/tickets · 获取票据',
    Stage.navigating: 'GET /mobile/shiro-cas · 交换票据',
    Stage.identity: 'POST /mobile/tryLoginUserInfo · 取得身份',
    Stage.syncing: 'POST /login-user/sync-list · 同步身份',
    Stage.semester: 'GET /semester/selectCurrentXnXq',
    Stage.discovering: 'POST /attendanceStudent/query/opt · 查询今日课程',
    Stage.choosing: '若有多门课程，选择本次课程',
    Stage.opening: '再次查询课程状态，确认仍可签到',
    Stage.filling: '核对课程签到方式；需要验证码时检查四位数字',
    Stage.submitting:
        'POST /attendanceStudent/updateStuAttendance · 只提交一次；响应返回后仍需核验学校记录',
    Stage.verifying: '先等待 5 秒再查询签到记录；尚未同步时每隔 5 秒查询一次，最多查询 5 次',
    Stage.cleaning: '退出教务与 CAS 会话，清除本轮身份',
  };

  late final List<FlowStep> _steps = _order
      .where(
        (s) =>
            !widget.inspectOnly ||
            !const [
              Stage.choosing,
              Stage.opening,
              Stage.filling,
              Stage.submitting,
              Stage.verifying,
            ].contains(s),
      )
      .map(FlowStep.new)
      .toList();
  late final AttendanceOrchestrator _flow = AttendanceOrchestrator(
    widget.providerFactory,
    clock: widget.clock,
  );
  List<Course> _courses = const [];
  bool _queried = false;
  RunResult? _result;
  Stage? _active, _lastWork;
  final Map<String, Stage> _lanes = {};

  String _lane(Stage stage) => networkStages.contains(stage)
      ? 'network'
      : academicStages.contains(stage)
      ? 'academic'
      : 'shared';

  void _stepError(Stage stage, String message) {
    if (!mounted) return;
    setState(() {
      final step = _step(stage);
      if (step != null) {
        step.status = StepStatus.failed;
        step.finishedAt = DateTime.now();
        step.detail = message;
      }
    });
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  void _showLatestStep() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _scroll.hasClients) {
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    });
  }

  FlowStep? _step(Stage stage) {
    for (final step in _steps) {
      if (step.stage == stage) return step;
    }
    return null;
  }

  void _advance(Stage stage) {
    if (!mounted) return;
    if (stage == Stage.networkFailed) {
      final failed = _lanes['network'];
      if (failed != null) _stepError(failed, '校园网准备失败；两条流程结束后显示具体原因，不会提交签到');
      return;
    }
    if (stage == Stage.syncWarning) {
      setState(() {
        final sync = _step(Stage.syncing);
        if (sync != null) {
          sync.status = StepStatus.warning;
          sync.finishedAt = DateTime.now();
          sync.detail = '学校未确认登录状态同步；继续检查学期和课程读取权限';
        }
      });
      return;
    }
    setState(() {
      final lane = _lane(stage);
      if (lane == 'shared' &&
          stage != Stage.waitingNetwork &&
          stage != Stage.statusPreparing) {
        for (final step in _steps.where(
          (s) => s.status == StepStatus.running,
        )) {
          step.status = StepStatus.success;
          step.finishedAt = DateTime.now();
        }
      }
      final previousStage = _lanes[lane];
      if (previousStage != null && previousStage != stage) {
        final previous = _step(previousStage);
        if (previous != null && previous.status == StepStatus.running) {
          previous.status = StepStatus.success;
          previous.finishedAt = DateTime.now();
        }
      }
      if (stage == Stage.cleaning) {
        _lastWork = _active;
        for (final step in _steps.where(
          (s) => s.status == StepStatus.running,
        )) {
          step.status = StepStatus.success;
          step.finishedAt = DateTime.now();
        }
      }
      final current = _step(stage);
      if (current != null) {
        current.status = StepStatus.running;
        current.startedAt ??= DateTime.now();
        if (const [Stage.networkReady, Stage.academicReady].contains(stage)) {
          current.status = StepStatus.success;
          current.finishedAt = DateTime.now();
        }
      }
      _lanes[lane] = stage;
      _active = stage;
    });
    _showLatestStep();
  }

  Future<Course?> _choose(List<Course> courses) async {
    if (!mounted) return null;
    return showDialog<Course>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('请选择本次课程'),
        content: SizedBox(
          width: 420,
          child: ListView(
            shrinkWrap: true,
            children: courses
                .map(
                  (course) => ListTile(
                    title: Text('${course.code} · ${course.name}'),
                    subtitle: Text('${course.time} · ${course.room}'),
                    onTap: () => Navigator.pop(ctx, course),
                  ),
                )
                .toList(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }

  Future<void> _start() async {
    late final RunResult result;
    try {
      if (widget.beforeStart != null) {
        _advance(Stage.statusPreparing);
        await widget.beforeStart!();
      }
      result = await _flow.run(
        widget.account,
        widget.code,
        inspectOnly: widget.inspectOnly,
        choose: _choose,
        progress: _advance,
        onStepError: _stepError,
        onCourses: (courses) {
          if (mounted) {
            setState(() {
              _courses = courses;
              _queried = true;
            });
          }
          widget.onCourses?.call(courses);
        },
      );
    } catch (_) {
      result = const RunResult(
        false,
        'CLEANUP_FAILED',
        '清理登录会话时发生错误，请关闭应用并在学校页面核验结果',
      );
    }
    if (!mounted) return;
    setState(() {
      if (result.course != null &&
          const ['SUCCESS', 'UNKNOWN'].contains(result.code)) {
        _courses = [
          for (final c in _courses)
            if (c.id == result.course!.id)
              Course({
                ...c.data,
                'attendanceStatus': result.success ? '1' : '',
                'studentOtherStatus': null,
              })
            else
              c,
        ];
      }
      final work = result.code == 'CLEANUP_FAILED'
          ? Stage.cleaning
          : result.failedStage ?? _lastWork ?? _active;
      if (work != null &&
          (!result.success || result.code == 'ALREADY_SIGNED')) {
        final failed = _step(work);
        if (failed != null) {
          failed.status = switch (result.code) {
            'ALREADY_SIGNED' || 'NO_ACTIVE_CLASS' => StepStatus.success,
            'UNKNOWN' => StepStatus.warning,
            _ => StepStatus.failed,
          };
          failed.finishedAt = DateTime.now();
          failed.detail = result.message;
        }
      }
      final cleanup = _step(Stage.cleaning);
      if (cleanup?.status == StepStatus.running &&
          result.code != 'CLEANUP_FAILED') {
        cleanup!.status = StepStatus.success;
        cleanup.finishedAt = DateTime.now();
      }
      _result = result;
    });
    widget.onResult?.call(result);
    _showLatestStep();
  }

  Future<void> _openPortal() async {
    final uri = Uri.parse(
      'https://acad.xmu.edu.my/mobile/#/student/myAttendance',
    );
    try {
      if (!await launchUrl(uri, mode: LaunchMode.externalApplication) &&
          mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开学校页面')));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(const SnackBar(content: Text('无法打开学校页面')));
      }
    }
  }

  String _time(DateTime? value) => value == null
      ? ''
      : '${value.hour.toString().padLeft(2, '0')}:'
            '${value.minute.toString().padLeft(2, '0')}:'
            '${value.second.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final result = _result;
    final noActiveClass = result?.code == 'NO_ACTIVE_CLASS';
    return PopScope(
      canPop: result != null,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.inspectOnly ? '登录与查询记录' : '本次签到记录'),
          automaticallyImplyLeading: result != null,
          leading: result == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.arrow_back),
                  tooltip: '返回账号列表',
                  onPressed: () => Navigator.pop(context, result),
                ),
        ),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 720),
              child: ListView(
                controller: _scroll,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(18),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.account.name,
                            style: Theme.of(context).textTheme.titleLarge,
                          ),
                          const SizedBox(height: 4),
                          Text(
                            widget.inspectOnly
                                ? '仅检查登录与课程，不提交签到'
                                : '正在处理本人的课堂签到',
                          ),
                          const SizedBox(height: 12),
                          if (result == null &&
                              _lanes.containsKey('network') &&
                              _lanes.containsKey('academic')) ...[
                            Text('校园网：${stageLabels[_lanes['network']]}'),
                            Text('教务：${stageLabels[_lanes['academic']]}'),
                            const SizedBox(height: 8),
                          ],
                          Row(
                            children: [
                              Icon(
                                result == null
                                    ? Icons.timelapse
                                    : result.success
                                    ? Icons.check_circle
                                    : noActiveClass
                                    ? Icons.info_outline
                                    : Icons.error_outline,
                                color: result == null
                                    ? Colors.blue
                                    : result.success
                                    ? Colors.green
                                    : noActiveClass
                                    ? Colors.blueGrey
                                    : Colors.deepOrange,
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  result == null
                                      ? '进行中 · ${stageLabels[_active] ?? '正在准备'}'
                                      : result.success
                                      ? '成功 · ${result.message}'
                                      : result.code == 'UNKNOWN'
                                      ? '待确认 · ${result.message}'
                                      : noActiveClass
                                      ? '无需签到 · ${result.message}'
                                      : '已停止 · ${result.message}',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (result?.course != null) ...[
                            const SizedBox(height: 8),
                            Text(
                              '${result!.course!.code} · ${result.course!.name}',
                            ),
                          ],
                          if (result != null &&
                              !result.success &&
                              !noActiveClass) ...[
                            const SizedBox(height: 8),
                            Text(
                              '结果代码：${result.code}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (result != null && _queried) ...[
                    Text(
                      '当天课程签到状态',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    const Text('以下为学校本轮查询返回的记录；点击课程查看详情'),
                    if (_courses.isEmpty) const Text('学校本轮查询未返回当天课程'),
                    for (final course in _courses)
                      Card(
                        child: ListTile(
                          title: Text(course.name),
                          subtitle: Text(
                            '${course.code} · ${course.time}\n${course.room}',
                          ),
                          trailing: Text(
                            course.attendanceLabel,
                            style: TextStyle(
                              color: course.signed
                                  ? Colors.green
                                  : course.unsigned
                                  ? Colors.red
                                  : Colors.blueGrey,
                            ),
                          ),
                          onTap: () => showDialog<void>(
                            context: context,
                            builder: (ctx) => AlertDialog(
                              title: Text(course.name),
                              content: Text(
                                '${course.code}\n${course.value('arrangeDate')} · ${course.time}\n地点：${course.room}\n签到状态：${course.attendanceLabel}\n本页面仅查看记录，不提交签到',
                              ),
                              actions: [
                                TextButton(
                                  onPressed: () => Navigator.pop(ctx),
                                  child: const Text('关闭'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 12),
                  ],
                  Text('步骤记录', style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 8),
                  ..._steps.where((s) => s.status != StepStatus.waiting).map((
                    step,
                  ) {
                    final color = switch (step.status) {
                      StepStatus.waiting => Colors.grey,
                      StepStatus.running => Colors.blue,
                      StepStatus.success => Colors.green,
                      StepStatus.warning => Colors.amber,
                      StepStatus.failed => Colors.deepOrange,
                    };
                    final icon = switch (step.status) {
                      StepStatus.waiting => Icons.radio_button_unchecked,
                      StepStatus.running => Icons.pending_outlined,
                      StepStatus.success => Icons.check_circle_outline,
                      StepStatus.warning => Icons.warning_amber_outlined,
                      StepStatus.failed => Icons.error_outline,
                    };
                    final status = switch (step.status) {
                      StepStatus.waiting => '等待',
                      StepStatus.running => '进行中',
                      StepStatus.success =>
                        step.stage == Stage.submitting ? '已返回' : '成功',
                      StepStatus.warning => '警告',
                      StepStatus.failed => '失败',
                    };
                    return Card(
                      key: ValueKey('flow-${step.stage.name}'),
                      child: ListTile(
                        leading: Icon(icon, color: color),
                        title: Text(stageLabels[step.stage] ?? step.stage.name),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(_details[step.stage] ?? ''),
                            if (step.detail != null)
                              Text(
                                step.detail!,
                                style: TextStyle(color: color),
                              ),
                          ],
                        ),
                        trailing: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              status,
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            if (step.startedAt != null)
                              Text(
                                _time(step.startedAt),
                                style: Theme.of(context).textTheme.bodySmall,
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                  if (result != null) ...[
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      onPressed: () => Navigator.pop(context, result),
                      icon: const Icon(Icons.arrow_back),
                      label: const Text('返回列表'),
                    ),
                    if (!result.success)
                      TextButton.icon(
                        onPressed: _openPortal,
                        icon: const Icon(Icons.open_in_browser),
                        label: const Text('学校页面核验'),
                      ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
