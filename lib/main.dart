import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:timezone/data/latest.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

const String _tasksKey = 'injaz_tasks_v1';
const String _settingsKey = 'injaz_settings_v1';
const String _listsKey = 'injaz_lists_v1';
const String _defaultListId = 'injaz_default_list';
const Color _purple = Color(0xFF6750A4);

enum TaskStatus { pending, done, notDone }

class PlannerTask {
  PlannerTask({
    required this.id,
    required this.dayKey,
    required this.text,
    required this.hour,
    required this.minute,
    required this.colorValue,
    this.status = TaskStatus.pending,
    this.repeatDaily = false,
    this.listId = _defaultListId,
  });

  final String id;
  final String dayKey;
  String text;
  int hour;
  int minute;
  int colorValue;
  TaskStatus status;
  bool repeatDaily;
  String listId;

  Map<String, dynamic> toJson() => {
        'id': id,
        'dayKey': dayKey,
        'text': text,
        'hour': hour,
        'minute': minute,
        'colorValue': colorValue,
        'status': status.name,
        'repeatDaily': repeatDaily,
        'listId': listId,
      };

  factory PlannerTask.fromJson(Map<String, dynamic> json) {
    return PlannerTask(
      id: json['id'] as String,
      dayKey: json['dayKey'] as String,
      text: json['text'] as String? ?? '',
      hour: json['hour'] as int? ?? 9,
      minute: json['minute'] as int? ?? 0,
      colorValue: json['colorValue'] as int? ?? _purple.value,
      status: TaskStatus.values.firstWhere(
        (value) => value.name == json['status'],
        orElse: () => TaskStatus.pending,
      ),
      repeatDaily: json['repeatDaily'] as bool? ?? false,
      listId: json['listId'] as String? ?? _defaultListId,
    );
  }

  int get notificationId {
    var hash = 17;
    for (final unit in id.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return 1000 + (hash % 800000000);
  }

  String get timeLabel =>
      '${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}';

  String timeLabelFor(bool english) {
    final hour12 = hour % 12 == 0 ? 12 : hour % 12;
    final suffix = english ? (hour < 12 ? 'AM' : 'PM') : (hour < 12 ? 'ص' : 'م');
    return '${hour12.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')} $suffix';
  }
}

class TaskGroup {
  TaskGroup({
    required this.id,
    required this.name,
    this.collapsed = false,
  });

  final String id;
  String name;
  bool collapsed;

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'collapsed': collapsed,
      };

  factory TaskGroup.fromJson(Map<String, dynamic> json) => TaskGroup(
        id: json['id'] as String,
        name: json['name'] as String? ?? 'قائمة جديدة',
        collapsed: json['collapsed'] as bool? ?? false,
      );
}

class PlannerSettings {
  bool darkMode;
  bool english;
  bool notificationsEnabled;
  int reminderHour;
  int reminderMinute;

  PlannerSettings({
    this.darkMode = false,
    this.english = false,
    this.notificationsEnabled = true,
    this.reminderHour = 8,
    this.reminderMinute = 0,
  });

  Map<String, dynamic> toJson() => {
        'darkMode': darkMode,
        'english': english,
        'notificationsEnabled': notificationsEnabled,
        'reminderHour': reminderHour,
        'reminderMinute': reminderMinute,
      };

  factory PlannerSettings.fromJson(Map<String, dynamic> json) =>
      PlannerSettings(
        darkMode: json['darkMode'] as bool? ?? false,
        english: json['english'] as bool? ?? false,
        notificationsEnabled:
            json['notificationsEnabled'] as bool? ?? true,
        reminderHour: json['reminderHour'] as int? ?? 8,
        reminderMinute: json['reminderMinute'] as int? ?? 0,
      );
}

String dayKeyOf(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

DateTime dateFromKey(String key) {
  final parts = key.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts[2]);
}

String formatDate(DateTime date, bool english) {
  const arDays = ['الاثنين', 'الثلاثاء', 'الأربعاء', 'الخميس', 'الجمعة', 'السبت', 'الأحد'];
  const enDays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
  const arMonths = ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
  const enMonths = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  final day = english ? enDays[date.weekday - 1] : arDays[date.weekday - 1];
  final month = english ? enMonths[date.month - 1] : arMonths[date.month - 1];
  return english
      ? '$day, $month ${date.day}, ${date.year}'
      : '$day، ${date.day} $month ${date.year}';
}

class PlannerController extends ChangeNotifier {
  PlannerController._(this.prefs);

  final SharedPreferences prefs;
  final List<PlannerTask> tasks = [];
  final List<TaskGroup> groups = [];
  PlannerSettings settings = PlannerSettings();

  static Future<PlannerController> create() async {
    final prefs = await SharedPreferences.getInstance();
    final controller = PlannerController._(prefs);
    await controller.load();
    await controller.prepareNewDay();
    return controller;
  }

  Future<void> load() async {
    tasks
      ..clear()
      ..addAll((prefs.getStringList(_tasksKey) ?? []).map((item) {
        return PlannerTask.fromJson(jsonDecode(item) as Map<String, dynamic>);
      }));
    final rawSettings = prefs.getString(_settingsKey);
    if (rawSettings != null) {
      settings = PlannerSettings.fromJson(
        jsonDecode(rawSettings) as Map<String, dynamic>,
      );
    }
    groups
      ..clear()
      ..addAll((prefs.getStringList(_listsKey) ?? []).map((item) {
        return TaskGroup.fromJson(jsonDecode(item) as Map<String, dynamic>);
      }));
    if (groups.isEmpty) {
      groups.add(TaskGroup(id: _defaultListId, name: 'قائمتي'));
      await prefs.setStringList(
        _listsKey,
        groups.map((group) => jsonEncode(group.toJson())).toList(),
      );
    }
  }

  Future<void> _save() async {
    await prefs.setStringList(
      _tasksKey,
      tasks.map((task) => jsonEncode(task.toJson())).toList(),
    );
    await prefs.setString(_settingsKey, jsonEncode(settings.toJson()));
    await prefs.setStringList(
      _listsKey,
      groups.map((group) => jsonEncode(group.toJson())).toList(),
    );
  }

  Future<void> prepareNewDay() async {
    final today = dayKeyOf(DateTime.now());
    final lastDay = prefs.getString('injaz_last_open_day');
    if (lastDay != null && lastDay != today) {
      final previousRecurring = tasks
          .where((task) => task.dayKey == lastDay && task.repeatDaily)
          .toList();
      for (final old in previousRecurring) {
        tasks.add(PlannerTask(
          id: '${DateTime.now().microsecondsSinceEpoch}_${old.id}',
          dayKey: today,
          text: old.text,
          hour: old.hour,
          minute: old.minute,
          colorValue: old.colorValue,
          status: TaskStatus.pending,
          repeatDaily: true,
          listId: old.listId,
        ));
      }
    }
    await prefs.setString('injaz_last_open_day', today);
    await _save();
  }

  List<PlannerTask> get todayTasks {
    final key = dayKeyOf(DateTime.now());
    final result = tasks.where((task) => task.dayKey == key).toList();
    result.sort((a, b) {
      final first = a.hour * 60 + a.minute;
      final second = b.hour * 60 + b.minute;
      return first.compareTo(second);
    });
    return result;
  }

  List<TaskGroup> get activeGroups => List.unmodifiable(groups);

  List<PlannerTask> tasksForGroup(String groupId) =>
      todayTasks.where((task) => task.listId == groupId).toList();

  int remainingForGroup(String groupId) => tasksForGroup(groupId)
      .where((task) => task.status != TaskStatus.done)
      .length;

  Future<void> addGroup(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    groups.add(TaskGroup(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      name: clean,
    ));
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> toggleGroup(String groupId) async {
    final group = groups.firstWhere((item) => item.id == groupId);
    group.collapsed = !group.collapsed;
    await _save();
    notifyListeners();
  }

  Future<void> renameGroup(TaskGroup group, String name) async {
    if (name.trim().isEmpty) return;
    group.name = name.trim();
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> deleteGroup(TaskGroup group) async {
    if (groups.length <= 1) return;
    final fallback = groups.firstWhere((item) => item.id != group.id);
    for (final task in tasks.where((item) => item.listId == group.id)) {
      task.listId = fallback.id;
    }
    groups.removeWhere((item) => item.id == group.id);
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  List<String> get historyDays {
    return tasks.map((task) => task.dayKey).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
  }

  Future<void> addTask({
    required String text,
    required TimeOfDay time,
    required int color,
    required bool repeatDaily,
    String listId = _defaultListId,
  }) async {
    if (text.trim().isEmpty) return;
    tasks.add(PlannerTask(
      id: DateTime.now().microsecondsSinceEpoch.toString(),
      dayKey: dayKeyOf(DateTime.now()),
      text: text.trim(),
      hour: time.hour,
      minute: time.minute,
      colorValue: color,
      repeatDaily: repeatDaily,
      listId: listId,
    ));
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> updateTask(
    PlannerTask task, {
    required String text,
    required TimeOfDay time,
    required int color,
    required bool repeatDaily,
  }) async {
    task
      ..text = text.trim()
      ..hour = time.hour
      ..minute = time.minute
      ..colorValue = color
      ..repeatDaily = repeatDaily;
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> setStatus(PlannerTask task, TaskStatus status) async {
    task.status = status;
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> deleteTask(PlannerTask task) async {
    tasks.removeWhere((item) => item.id == task.id);
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> saveSettings() async {
    await _save();
    notifyListeners();
    await NotificationService.refresh(this);
  }

  Future<void> reloadFromBackground() async {
    await load();
    notifyListeners();
  }

  List<PlannerTask> tasksForDay(String key) =>
      tasks.where((task) => task.dayKey == key).toList()
        ..sort((a, b) => (a.hour * 60 + a.minute)
            .compareTo(b.hour * 60 + b.minute));
}

class NotificationService {
  static final FlutterLocalNotificationsPlugin plugin =
      FlutterLocalNotificationsPlugin();
  static const String groupKeyPrefix = 'injaz_group_';

  static int _summaryId(String listId, String dayKey) {
    var hash = 23;
    for (final unit in '$listId|$dayKey'.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return 900000000 + (hash % 90000000);
  }

  static String _groupKey(String listId, String dayKey) =>
      '$groupKeyPrefix${listId}_$dayKey';

  static Future<void> initialize() async {
    tzdata.initializeTimeZones();
    try {
      final zone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(zone.identifier));
    } catch (_) {
      tz.setLocalLocation(tz.getLocation('Asia/Aden'));
    }

    const android = AndroidInitializationSettings('ic_notification');
    const settings = InitializationSettings(android: android);
    await plugin.initialize(
      settings,
      onDidReceiveNotificationResponse: _handleForegroundResponse,
      onDidReceiveBackgroundNotificationResponse: notificationTapBackground,
    );

    final androidPlugin =
        plugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();
    await androidPlugin?.requestNotificationsPermission();
    await androidPlugin?.requestExactAlarmsPermission();
  }

  static Future<void> _handleForegroundResponse(
      NotificationResponse response) async {
    await notificationTapBackground(response);
  }

  static String _groupBody(List<PlannerTask> pending, bool english) {
    final lines = pending
        .map((task) => '${task.timeLabelFor(english)}  ${task.text.replaceAll('\n', ' ')}')
        .join('\n');
    return lines.length > 3000 ? '${lines.substring(0, 3000)}…' : lines;
  }

  static AndroidNotificationDetails _summaryDetails(
    bool english,
    String groupKey,
    String body,
  ) =>
      AndroidNotificationDetails(
        'injaz_list_summary_channel',
        english ? 'Task list reminders' : 'تذكيرات قوائم المهام',
        channelDescription: english
            ? 'One grouped reminder for each task list'
            : 'إشعار مجمع لكل قائمة مهام',
        importance: Importance.max,
        priority: Priority.max,
        playSound: true,
        ongoing: true,
        autoCancel: false,
        groupKey: groupKey,
        setAsGroupSummary: true,
        styleInformation: BigTextStyleInformation(body),
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'open_list',
            english ? 'View more' : 'عرض المزيد',
            showsUserInterface: true,
            cancelNotification: false,
          ),
        ],
      );

  static AndroidNotificationDetails _taskDetails(
    bool english,
    String groupKey,
  ) =>
      AndroidNotificationDetails(
        'injaz_list_tasks_channel',
        english ? 'Tasks in a list' : 'مهام القائمة',
        channelDescription: english
            ? 'Task actions grouped under each list'
            : 'إجراءات المهام ضمن كل قائمة',
        importance: Importance.max,
        priority: Priority.max,
        playSound: false,
        ongoing: true,
        autoCancel: false,
        groupKey: groupKey,
        actions: <AndroidNotificationAction>[
          AndroidNotificationAction(
            'done',
            english ? 'Done' : 'تم',
            showsUserInterface: false,
            cancelNotification: true,
          ),
          AndroidNotificationAction(
            'not_done',
            english ? 'Not done' : 'لم يتم',
            showsUserInterface: false,
            cancelNotification: true,
          ),
        ],
      );

  static Future<void> refresh(PlannerController controller) async {
    await plugin.cancelAll();
    if (!controller.settings.notificationsEnabled) return;

    final today = dayKeyOf(DateTime.now());
    final now = tz.TZDateTime.now(tz.local);
    final english = controller.settings.english;

    for (final group in controller.groups) {
      final pending = controller.tasksForGroup(group.id)
          .where((task) => task.status == TaskStatus.pending)
          .toList()
        ..sort((a, b) =>
            (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));
      if (pending.isEmpty) continue;

      final first = pending.first;
      var trigger = tz.TZDateTime(
        tz.local,
        now.year,
        now.month,
        now.day,
        first.hour,
        first.minute,
      );
      if (trigger.isBefore(now)) trigger = now.add(const Duration(seconds: 2));

      final key = _groupKey(group.id, today);
      final summaryId = _summaryId(group.id, today);
      final summaryDetails = NotificationDetails(
        android: _summaryDetails(english, key, _groupBody(pending, english)),
      );
      final summaryPayload = jsonEncode({
        'listId': group.id,
        'dayKey': today,
        'summary': true,
      });

      final taskDetails = NotificationDetails(
        android: _taskDetails(english, key),
      );

      if (!trigger.isAfter(now.add(const Duration(seconds: 3)))) {
        await plugin.show(
          summaryId,
          group.name,
          _groupBody(pending, english),
          summaryDetails,
          payload: summaryPayload,
        );
        for (final task in pending) {
          await plugin.show(
            task.notificationId,
            task.text.replaceAll('\n', ' '),
            '${group.name} • ${task.timeLabelFor(english)}',
            taskDetails,
            payload: jsonEncode({
              'taskId': task.id,
              'dayKey': task.dayKey,
              'listId': group.id,
            }),
          );
        }
      } else {
        try {
          await plugin.zonedSchedule(
            summaryId,
            group.name,
            _groupBody(pending, english),
            trigger,
            summaryDetails,
            androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
            payload: summaryPayload,
          );
          for (final task in pending) {
            await plugin.zonedSchedule(
              task.notificationId,
              task.text.replaceAll('\n', ' '),
              '${group.name} • ${task.timeLabelFor(english)}',
              trigger,
              taskDetails,
              androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
              payload: jsonEncode({
                'taskId': task.id,
                'dayKey': task.dayKey,
                'listId': group.id,
              }),
            );
          }
        } catch (_) {
          await plugin.zonedSchedule(
            summaryId,
            group.name,
            _groupBody(pending, english),
            trigger,
            summaryDetails,
            androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
            payload: summaryPayload,
          );
          for (final task in pending) {
            await plugin.zonedSchedule(
              task.notificationId,
              task.text.replaceAll('\n', ' '),
              '${group.name} • ${task.timeLabelFor(english)}',
              trigger,
              taskDetails,
              androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
              payload: jsonEncode({
                'taskId': task.id,
                'dayKey': task.dayKey,
                'listId': group.id,
              }),
            );
          }
        }
      }
    }
  }
}

@pragma('vm:entry-point')
Future<void> notificationTapBackground(NotificationResponse response) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (response.actionId != 'done' && response.actionId != 'not_done') return;

  Map<String, dynamic>? payload;
  try {
    payload = jsonDecode(response.payload ?? '') as Map<String, dynamic>;
  } catch (_) {
    return;
  }
  final taskId = payload['taskId'] as String?;
  final dayKey = payload['dayKey'] as String?;
  final listId = payload['listId'] as String?;
  if (taskId == null || dayKey == null || listId == null) return;

  final prefs = await SharedPreferences.getInstance();
  final raw = prefs.getStringList(_tasksKey) ?? [];
  final decoded = raw
      .map((item) => PlannerTask.fromJson(
          jsonDecode(item) as Map<String, dynamic>))
      .toList();

  PlannerTask? changed;
  for (final task in decoded) {
    if (task.id == taskId && task.dayKey == dayKey) {
      task.status =
          response.actionId == 'done' ? TaskStatus.done : TaskStatus.notDone;
      changed = task;
      break;
    }
  }
  if (changed == null) return;

  await prefs.setStringList(
    _tasksKey,
    decoded.map((task) => jsonEncode(task.toJson())).toList(),
  );

  final groups = (prefs.getStringList(_listsKey) ?? [])
      .map((item) => TaskGroup.fromJson(
          jsonDecode(item) as Map<String, dynamic>))
      .toList();
  TaskGroup? group;
  for (final item in groups) {
    if (item.id == listId) {
      group = item;
      break;
    }
  }
  final groupName = group?.name ?? 'قائمة المهام';
  final pending = decoded
      .where((task) =>
          task.dayKey == dayKey &&
          task.listId == listId &&
          task.status == TaskStatus.pending)
      .toList()
    ..sort((a, b) =>
        (a.hour * 60 + a.minute).compareTo(b.hour * 60 + b.minute));

  final notifications = FlutterLocalNotificationsPlugin();
  await notifications.initialize(
    const InitializationSettings(
      android: AndroidInitializationSettings('ic_notification'),
    ),
  );
  await notifications.cancel(changed.notificationId);

  var hash = 23;
  for (final unit in '$listId|$dayKey'.codeUnits) {
    hash = (hash * 31 + unit) & 0x7fffffff;
  }
  final summaryId = 900000000 + (hash % 90000000);
  if (pending.isEmpty) {
    await notifications.cancel(summaryId);
    for (final task in decoded.where(
        (item) => item.dayKey == dayKey && item.listId == listId)) {
      await notifications.cancel(task.notificationId);
    }
    return;
  }

  final settings = jsonDecode(prefs.getString(_settingsKey) ?? '{}')
      as Map<String, dynamic>;
  final english = settings['english'] as bool? ?? false;
  final groupKey = 'injaz_group_${listId}_$dayKey';
  final body = pending
      .map((task) => '${task.timeLabelFor(english)}  ${task.text.replaceAll('\n', ' ')}')
      .join('\n');
  await notifications.show(
    summaryId,
    groupName,
    body.length > 3000 ? '${body.substring(0, 3000)}…' : body,
    NotificationDetails(
      android: AndroidNotificationDetails(
        'injaz_list_summary_channel',
        english ? 'Task list reminders' : 'تذكيرات قوائم المهام',
        channelDescription: english
            ? 'One grouped reminder for each task list'
            : 'إشعار مجمع لكل قائمة مهام',
        importance: Importance.max,
        priority: Priority.max,
        ongoing: true,
        autoCancel: false,
        groupKey: groupKey,
        setAsGroupSummary: true,
        styleInformation: BigTextStyleInformation(body),
      ),
    ),
    payload: jsonEncode({'listId': listId, 'dayKey': dayKey, 'summary': true}),
  );
}

class InjazApp extends StatelessWidget {
  const InjazApp({super.key, required this.controller});
  final PlannerController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final dark = controller.settings.darkMode;
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Injaz',
          themeMode: dark ? ThemeMode.dark : ThemeMode.light,
          theme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: _purple,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: const Color(0xFFF8F7FB),
            cardTheme: CardThemeData(
              elevation: 0,
              color: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            colorScheme: ColorScheme.fromSeed(
              seedColor: _purple,
              brightness: Brightness.dark,
            ),
            cardTheme: CardThemeData(
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
            ),
          ),
          home: PlannerHome(controller: controller),
        );
      },
    );
  }
}

class PlannerHome extends StatefulWidget {
  const PlannerHome({super.key, required this.controller});
  final PlannerController controller;

  @override
  State<PlannerHome> createState() => _PlannerHomeState();
}

class _PlannerHomeState extends State<PlannerHome> with WidgetsBindingObserver {
  int selectedTab = 0;
  final Map<String, TextEditingController> _inlineControllers = {};
  final Map<String, FocusNode> _inlineFocusNodes = {};
  final Map<String, TimeOfDay> _inlineTimes = {};
  final Map<String, bool> _inlineRepeats = {};
  final Map<String, int> _inlineColors = {};
  final Set<String> _addingForGroup = {};
  PlannerController get c => widget.controller;
  bool get en => c.settings.english;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    for (final controller in _inlineControllers.values) {
      controller.dispose();
    }
    for (final node in _inlineFocusNodes.values) {
      node.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      c.reloadFromBackground().then((_) => NotificationService.refresh(c));
    }
  }

  String tr(String ar, String english) => en ? english : ar;

  @override
  Widget build(BuildContext context) {
    final pages = [
      _homePage(),
      _historyPage(),
      _statisticsPage(),
      _settingsPage(),
    ];
    return Directionality(
      textDirection: en ? TextDirection.ltr : TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(tr('إنجاز', 'Injaz'),
              style: const TextStyle(fontWeight: FontWeight.w800)),
          centerTitle: false,
          actions: [
            Padding(
              padding: const EdgeInsetsDirectional.only(end: 16),
              child: Center(
                child: Text(
                  _shortDate(DateTime.now(), en),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          ],
        ),
        body: IndexedStack(index: selectedTab, children: pages),
        bottomNavigationBar: NavigationBar(
          selectedIndex: selectedTab,
          onDestinationSelected: (value) =>
              setState(() => selectedTab = value),
          destinations: [
            NavigationDestination(
                icon: const Icon(Icons.checklist_rounded),
                label: tr('الرئيسية', 'Home')),
            NavigationDestination(
                icon: const Icon(Icons.history_rounded),
                label: tr('السجل', 'History')),
            NavigationDestination(
                icon: const Icon(Icons.bar_chart_rounded),
                label: tr('الإحصائيات', 'Stats')),
            NavigationDestination(
                icon: const Icon(Icons.settings_rounded),
                label: tr('الإعدادات', 'Settings')),
          ],
        ),
      ),
    );
  }

  String _shortDate(DateTime date, bool english) {
    final months = english
        ? ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
        : ['يناير', 'فبراير', 'مارس', 'أبريل', 'مايو', 'يونيو', 'يوليو', 'أغسطس', 'سبتمبر', 'أكتوبر', 'نوفمبر', 'ديسمبر'];
    return '${date.day} ${months[date.month - 1]}';
  }

  Widget _homePage() {
    final tasks = c.todayTasks;
    final total = tasks.length;
    final remaining =
        tasks.where((task) => task.status != TaskStatus.done).length;

    return ListView(
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 28),
      children: [
        Row(
          children: [
            Expanded(
              child: _counterCard(
                tr('كل المهام', 'All tasks'),
                total,
                Icons.checklist_rounded,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _counterCard(
                tr('المتبقية', 'Remaining'),
                remaining,
                Icons.hourglass_bottom_rounded,
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Row(
          children: [
            Expanded(
              child: Text(
                tr('قوائم مهامي', 'My lists'),
                style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
              ),
            ),
            FilledButton.tonalIcon(
              onPressed: _createGroup,
              icon: const Icon(Icons.create_new_folder_outlined, size: 18),
              label: Text(tr('قائمة جديدة', 'New list')),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (c.groups.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(28),
              child: Text(tr('أنشئ قائمتك الأولى للبدء.', 'Create your first list to begin.')),
            ),
          )
        else
          ...c.groups.map(_groupCard),
      ],
    );
  }

  Widget _counterCard(String label, int value, IconData icon) {
    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        child: Row(
          children: [
            Icon(icon, color: _purple, size: 22),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$value',
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _groupCard(TaskGroup group) {
    final items = c.tasksForGroup(group.id);
    final pending = items.where((t) => t.status != TaskStatus.done).length;
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          InkWell(
            onTap: () => c.toggleGroup(group.id),
            child: Padding(
              padding: const EdgeInsetsDirectional.fromSTEB(14, 13, 8, 13),
              child: Row(
                children: [
                  Icon(
                    group.collapsed
                        ? Icons.folder_outlined
                        : Icons.folder_open_rounded,
                    color: _purple,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '$pending ${tr('متبقية من', 'remaining of')} ${items.length} ${tr('مهام', 'tasks')}',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ),
                  ),
                  PopupMenuButton<String>(
                    onSelected: (value) {
                      if (value == 'rename') _renameGroup(group);
                      if (value == 'delete') _deleteGroup(group);
                    },
                    itemBuilder: (context) => [
                      PopupMenuItem(
                        value: 'rename',
                        child: Text(tr('إعادة تسمية', 'Rename')),
                      ),
                      if (c.groups.length > 1)
                        PopupMenuItem(
                          value: 'delete',
                          child: Text(tr('حذف القائمة', 'Delete list')),
                        ),
                    ],
                  ),
                  Icon(
                    group.collapsed
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_up_rounded,
                  ),
                ],
              ),
            ),
          ),
          if (!group.collapsed) ...[
            const Divider(height: 1),
            if (items.isEmpty)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  tr('لا توجد مهام في هذه القائمة بعد.', 'No tasks in this list yet.'),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              )
            else
              ...items.map((task) => _taskCard(task)),
            if (_addingForGroup.contains(group.id))
              _inlineTaskComposer(group),
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
              child: SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () => _startInlineAdd(group),
                  icon: const Icon(Icons.add_rounded),
                  label: Text(tr('إضافة مهمة هنا', 'Add task here')),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  void _startInlineAdd(TaskGroup group) {
    if (!_addingForGroup.contains(group.id)) {
      _inlineControllers[group.id] = TextEditingController();
      _inlineFocusNodes[group.id] = FocusNode();
      _inlineTimes[group.id] = const TimeOfDay(hour: 9, minute: 0);
      _inlineRepeats[group.id] = false;
      _inlineColors[group.id] = _purple.value;
      _addingForGroup.add(group.id);
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _inlineFocusNodes[group.id]?.requestFocus();
    });
  }

  Widget _inlineTaskComposer(TaskGroup group) {
    final controller = _inlineControllers[group.id]!;
    final focusNode = _inlineFocusNodes[group.id]!;
    final time = _inlineTimes[group.id] ?? const TimeOfDay(hour: 9, minute: 0);
    final repeat = _inlineRepeats[group.id] ?? false;
    final color = _inlineColors[group.id] ?? _purple.value;
    const palette = <int>[
      0xFF6750A4, 0xFF287A72, 0xFF3478C8, 0xFFE18A32,
      0xFFD45C78, 0xFF607D8B, 0xFF7B8D35,
    ];
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 10, 12, 4),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: .45),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _purple.withValues(alpha: .35)),
      ),
      child: Column(
        children: [
          TextField(
            controller: controller,
            focusNode: focusNode,
            autofocus: true,
            minLines: 1,
            maxLines: 4,
            keyboardType: TextInputType.multiline,
            textInputAction: TextInputAction.newline,
            decoration: InputDecoration(
              hintText: tr('اكتب المهمة الجديدة...', 'Write a new task...'),
              border: InputBorder.none,
              isDense: true,
            ),
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              TextButton.icon(
                onPressed: () async {
                  final picked = await showTimePicker(
                    context: context,
                    initialTime: time,
                    builder: (context, child) => MediaQuery(
                      data: MediaQuery.of(context).copyWith(
                        alwaysUse24HourFormat: false,
                      ),
                      child: child!,
                    ),
                  );
                  if (picked != null) {
                    setState(() => _inlineTimes[group.id] = picked);
                  }
                },
                icon: const Icon(Icons.schedule_rounded, size: 18),
                label: Text(_formatTwelveHour(context, time)),
              ),
              const SizedBox(width: 4),
              IconButton(
                tooltip: tr('تغيير اللون', 'Change color'),
                onPressed: () {
                  final current = palette.indexOf(color);
                  setState(() => _inlineColors[group.id] =
                      palette[(current + 1) % palette.length]);
                },
                icon: Icon(Icons.circle, color: Color(color), size: 20),
              ),
              const Spacer(),
            ],
          ),
          Row(
            children: [
              Checkbox(
                value: repeat,
                onChanged: (value) => setState(
                  () => _inlineRepeats[group.id] = value ?? false,
                ),
                visualDensity: VisualDensity.compact,
              ),
              Text(tr('تكرار يومي', 'Daily'), style: Theme.of(context).textTheme.bodySmall),
              const Spacer(),
              TextButton(
                onPressed: () {
                  setState(() {
                    _addingForGroup.remove(group.id);
                    _inlineControllers.remove(group.id)?.dispose();
                    _inlineFocusNodes.remove(group.id)?.dispose();
                    _inlineTimes.remove(group.id);
                    _inlineRepeats.remove(group.id);
                    _inlineColors.remove(group.id);
                  });
                },
                child: Text(tr('إلغاء', 'Cancel')),
              ),
              FilledButton(
                onPressed: () => _submitInlineTask(group),
                child: Text(tr('حفظ', 'Save')),
              ),
            ],
          ),
        ],
      ),
    );
  }

  String _formatTwelveHour(BuildContext context, TimeOfDay time) {
    return MaterialLocalizations.of(context).formatTimeOfDay(
      time,
      alwaysUse24HourFormat: false,
    );
  }

  Future<void> _submitInlineTask(TaskGroup group) async {
    final controller = _inlineControllers[group.id];
    if (controller == null || controller.text.trim().isEmpty) return;
    await c.addTask(
      text: controller.text,
      time: _inlineTimes[group.id] ?? const TimeOfDay(hour: 9, minute: 0),
      color: _inlineColors[group.id] ?? _purple.value,
      repeatDaily: _inlineRepeats[group.id] ?? false,
      listId: group.id,
    );
    controller.clear();
    if (mounted) {
      _inlineFocusNodes[group.id]?.requestFocus();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(tr('تمت إضافة المهمة. يمكنك كتابة المهمة التالية.', 'Task added. You can enter the next one.')),
          duration: const Duration(seconds: 1),
        ),
      );
    }
  }

  Future<void> _createGroup() async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('قائمة جديدة', 'New list')),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            hintText: tr('اسم القائمة', 'List name'),
          ),
          onSubmitted: (value) => Navigator.pop(dialogContext, value),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(tr('إنشاء', 'Create')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await c.addGroup(name);
  }

  Future<void> _renameGroup(TaskGroup group) async {
    final controller = TextEditingController(text: group.name);
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('إعادة تسمية القائمة', 'Rename list')),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: InputDecoration(hintText: tr('اسم القائمة', 'List name')),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: Text(tr('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, controller.text),
            child: Text(tr('حفظ', 'Save')),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name != null) await c.renameGroup(group, name);
  }

  Future<void> _deleteGroup(TaskGroup group) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(tr('حذف القائمة؟', 'Delete list?')),
        content: Text(tr(
          'سيتم نقل مهامها إلى قائمة أخرى بدلاً من حذفها.',
          'Its tasks will be moved to another list instead of being deleted.',
        )),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(tr('إلغاء', 'Cancel')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(tr('حذف', 'Delete')),
          ),
        ],
      ),
    );
    if (yes == true) await c.deleteGroup(group);
  }

  Widget _taskCard(PlannerTask task) {
    final color = Color(task.colorValue);
    final isDone = task.status == TaskStatus.done;
    final isNotDone = task.status == TaskStatus.notDone;
    final card = Container(
      margin: const EdgeInsets.fromLTRB(10, 7, 10, 0),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        borderRadius: BorderRadius.circular(15),
        border: Border.all(color: color.withValues(alpha: .28)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Container(
            width: 4,
            height: 52,
            decoration: BoxDecoration(
              color: color,
              borderRadius: BorderRadius.circular(6),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: InkWell(
              onTap: () => _openTaskEditor(task),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    task.text,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      decoration: isDone ? TextDecoration.lineThrough : null,
                      color: isDone
                          ? Theme.of(context).colorScheme.onSurfaceVariant
                          : null,
                    ),
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      const Icon(Icons.access_time_rounded, size: 14),
                      const SizedBox(width: 4),
                      Text(
                        _formatTwelveHour(
                          context,
                          TimeOfDay(hour: task.hour, minute: task.minute),
                        ),
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                      if (task.repeatDaily) ...[
                        const SizedBox(width: 8),
                        const Icon(Icons.repeat_rounded, size: 13),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _taskStatusButton(
                label: tr('تم', 'Done'),
                icon: Icons.check_rounded,
                selected: isDone,
                onPressed: () => c.setStatus(task, TaskStatus.done),
              ),
              const SizedBox(height: 5),
              _taskStatusButton(
                label: tr('لم يتم', 'Not done'),
                icon: Icons.close_rounded,
                selected: isNotDone,
                onPressed: () => c.setStatus(task, TaskStatus.notDone),
              ),
            ],
          ),
        ],
      ),
    );
    return GestureDetector(
      onLongPress: () => _confirmDelete(task),
      child: card,
    );
  }

  Widget _taskStatusButton({
    required String label,
    required IconData icon,
    required bool selected,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: 88,
      height: 34,
      child: selected
          ? FilledButton.tonalIcon(
              onPressed: onPressed,
              icon: Icon(icon, size: 16),
              label: Text(label, style: const TextStyle(fontSize: 11)),
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 5),
              ),
            )
          : OutlinedButton.icon(
              onPressed: onPressed,
              icon: Icon(icon, size: 15),
              label: Text(label, style: const TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 5),
              ),
            ),
    );
  }

  Future<void> _openTaskEditor(PlannerTask task) async {
    final textController = TextEditingController(text: task.text);
    TimeOfDay time = TimeOfDay(hour: task.hour, minute: task.minute);
    int color = task.colorValue;
    bool repeat = task.repeatDaily;
    final colors = <Color>[
      const Color(0xFF6750A4),
      const Color(0xFF287A72),
      const Color(0xFF3478C8),
      const Color(0xFFE18A32),
      const Color(0xFFD45C78),
      const Color(0xFF607D8B),
      const Color(0xFF7B8D35),
    ];

    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            return Padding(
              padding: EdgeInsets.fromLTRB(
                  20, 8, 20, MediaQuery.of(context).viewInsets.bottom + 20),
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      tr('تعديل المهمة', 'Edit task'),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                    ),
                    const SizedBox(height: 14),
                    TextField(
                      controller: textController,
                      autofocus: true,
                      minLines: 2,
                      maxLines: 6,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                      decoration: InputDecoration(
                        hintText: tr('اكتب المهمة هنا...', 'Write your task here...'),
                        border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(16)),
                        alignLabelWithHint: true,
                      ),
                    ),
                    const SizedBox(height: 14),
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      leading: const Icon(Icons.access_time_rounded),
                      title: Text(tr('وقت البداية', 'Start time')),
                      trailing: Text(time.format(context),
                          style: const TextStyle(fontWeight: FontWeight.w700)),
                      onTap: () async {
                        final picked = await showTimePicker(
                            context: context, initialTime: time);
                        if (picked != null) setSheetState(() => time = picked);
                      },
                    ),
                    const SizedBox(height: 6),
                    Text(tr('لون المهمة', 'Task color'),
                        style: const TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Wrap(
                      spacing: 12,
                      children: colors.map((item) {
                        return InkWell(
                          onTap: () => setSheetState(() => color = item.value),
                          borderRadius: BorderRadius.circular(30),
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: item,
                              shape: BoxShape.circle,
                              border: color == item.value
                                  ? Border.all(
                                      color: Theme.of(context).colorScheme.onSurface,
                                      width: 3)
                                  : null,
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 10),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      value: repeat,
                      onChanged: (value) => setSheetState(() => repeat = value),
                      title: Text(tr('تكرار يومي', 'Repeat daily')),
                      subtitle: Text(tr('إنشاء نسخة جديدة غداً لهذه المهمة.',
                          'Create a fresh copy of this task tomorrow.')),
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton(
                        onPressed: () async {
                          if (textController.text.trim().isEmpty) return;
                          await c.updateTask(
                            task,
                            text: textController.text,
                            time: time,
                            color: color,
                            repeatDaily: repeat,
                          );
                          if (sheetContext.mounted) Navigator.pop(sheetContext);
                        },
                        child: Text(tr('حفظ المهمة', 'Save task')),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
    textController.dispose();
  }

  Future<void> _confirmDelete(PlannerTask task) async {
    final yes = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(tr('حذف المهمة؟', 'Delete task?')),
        content: Text(tr('لن يمكن استعادة هذه المهمة بعد حذفها.',
            'This task cannot be restored after deletion.')),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(tr('إلغاء', 'Cancel'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(tr('حذف', 'Delete'))),
        ],
      ),
    );
    if (yes == true) await c.deleteTask(task);
  }

  Widget _historyPage() {
    final days = c.historyDays;
    if (days.isEmpty) {
      return Center(child: Text(tr('لا يوجد سجل سابق بعد.', 'No history yet.')));
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: days.map((key) {
        final date = dateFromKey(key);
        final dayTasks = c.tasksForDay(key);
        final done = dayTasks.where((task) => task.status == TaskStatus.done).length;
        return Card(
          child: ExpansionTile(
            title: Text(formatDate(date, en),
                style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('$done / ${dayTasks.length} ${tr('مكتملة', 'completed')}'),
            children: dayTasks.isEmpty
                ? [ListTile(title: Text(tr('لا توجد مهام', 'No tasks')))]
                : dayTasks
                    .map((task) => ListTile(
                          leading: Icon(
                            task.status == TaskStatus.done
                                ? Icons.check_circle
                                : task.status == TaskStatus.notDone
                                    ? Icons.cancel_outlined
                                    : Icons.radio_button_unchecked,
                            color: Color(task.colorValue),
                          ),
                          title: Text(task.text),
                          subtitle: Text(_formatTwelveHour(context, TimeOfDay(hour: task.hour, minute: task.minute))),
                          trailing: Text(_statusLabel(task.status)),
                        ))
                    .toList(),
          ),
        );
      }).toList(),
    );
  }

  String _statusLabel(TaskStatus status) {
    switch (status) {
      case TaskStatus.done:
        return tr('تم', 'Done');
      case TaskStatus.notDone:
        return tr('لم يتم', 'Not done');
      case TaskStatus.pending:
        return tr('لم تُحدد', 'Not set');
    }
  }

  Widget _statisticsPage() {
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day)
        .subtract(Duration(days: now.weekday - 1));
    final days = List.generate(7, (i) => start.add(Duration(days: i)));
    var total = 0;
    var done = 0;
    final bars = <Widget>[];
    for (final day in days) {
      final items = c.tasksForDay(dayKeyOf(day));
      final completed = items.where((t) => t.status == TaskStatus.done).length;
      total += items.length;
      done += completed;
      final ratio = items.isEmpty ? 0.0 : completed / items.length;
      bars.add(Expanded(
        child: Column(
          children: [
            Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: ratio == 0 ? .025 : ratio,
                  child: Container(
                    width: 22,
                    decoration: BoxDecoration(
                      color: _purple,
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(en
                ? ['M', 'T', 'W', 'T', 'F', 'S', 'S'][day.weekday - 1]
                : ['ن', 'ث', 'ر', 'خ', 'ج', 'س', 'ح'][day.weekday - 1]),
          ],
        ),
      ));
    }
    final ratio = total == 0 ? 0.0 : done / total;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(tr('إحصائيات هذا الأسبوع', 'This week'),
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                const SizedBox(height: 18),
                SizedBox(height: 150, child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: bars)),
                const SizedBox(height: 18),
                Text('${(ratio * 100).round()}% ${tr('نسبة الإنجاز', 'completion rate')}',
                    style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 18)),
                const SizedBox(height: 8),
                LinearProgressIndicator(value: ratio, minHeight: 8),
                const SizedBox(height: 12),
                Text('$done ${tr('مكتملة من أصل', 'completed out of')} $total ${tr('مهمة', 'tasks')}'),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _settingsPage() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: Column(
            children: [
              SwitchListTile(
                secondary: const Icon(Icons.dark_mode_outlined),
                title: Text(tr('الوضع الداكن', 'Dark mode')),
                value: c.settings.darkMode,
                onChanged: (value) {
                  c.settings.darkMode = value;
                  c.saveSettings();
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.language_rounded),
                title: Text(tr('اللغة الإنجليزية', 'English language')),
                subtitle: Text(tr('إيقاف الخيار يعيد العربية.', 'Turn off to use Arabic.')),
                value: c.settings.english,
                onChanged: (value) {
                  c.settings.english = value;
                  c.saveSettings();
                },
              ),
              const Divider(height: 1),
              SwitchListTile(
                secondary: const Icon(Icons.notifications_active_outlined),
                title: Text(tr('إشعارات القوائم', 'Task list notifications')),
                value: c.settings.notificationsEnabled,
                onChanged: (value) {
                  c.settings.notificationsEnabled = value;
                  c.saveSettings();
                },
              ),
              ListTile(
                leading: const Icon(Icons.schedule_rounded),
                title: Text(tr('موعد إشعار القائمة', 'List notification time')),
                subtitle: Text(tr(
                  'يُحدد تلقائياً حسب أقرب مهمة متبقية في كل قائمة.',
                  'Automatically uses the earliest pending task in each list.',
                )),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.copy_all_rounded),
            title: Text(tr('نسخ قائمة مهام اليوم', 'Copy today tasks')),
            subtitle: Text(tr('نسخ المهام وأوقاتها وحالاتها.', 'Copy tasks, times and statuses.')),
            onTap: _copyToday,
          ),
        ),
        const SizedBox(height: 12),
        Card(
          child: ListTile(
            leading: const Icon(Icons.info_outline_rounded),
            title: Text(tr('حول التطبيق', 'About')),
            subtitle: Text(tr('تطبيق لتنظيم المهام اليومية دون إنترنت.',
                'An offline daily task planner.')),
          ),
        ),
      ],
    );
  }

  Future<void> _copyToday() async {
    final items = c.todayTasks;
    final buffer = StringBuffer();
    for (var i = 0; i < items.length; i++) {
      final task = items[i];
      final group = c.groups.where((item) => item.id == task.listId);
      final groupName = group.isEmpty ? '' : ' — ${group.first.name}';
      buffer.writeln('${i + 1}. ${task.text.replaceAll('\n', ' ')} — ${_formatTwelveHour(context, TimeOfDay(hour: task.hour, minute: task.minute))}$groupName — ${_statusLabel(task.status)}');
    }
    await Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(tr('تم نسخ قائمة اليوم.', 'Today list copied.'))),
    );
  }
}

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = await PlannerController.create();
  await NotificationService.initialize();
  await NotificationService.refresh(controller);
  runApp(InjazApp(controller: controller));
}