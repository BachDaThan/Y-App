// background_guard.dart - GIỮ APP SỐNG khi người dùng thoát ra màn hình chính / dùng app khác trong lúc Yui làm việc nặng (trả lời, tải cập nhật).
// Android: dịch vụ nền (foreground service, loại dataSync) + thông báo thường trực có NÚT "Dừng". Bấm Dừng -> gọi mọi hàm đã đăng ký bằng addStopHandler
// (chat: app.stop(); cập nhật: huỷ tải) => CPU/RAM được giải phóng ngay, hết nóng máy/hao pin. Nền tảng khác: không làm gì.
// Dịch vụ chỉ để giữ tiến trình; model vẫn chạy trong isolate của app như bình thường (engine.dart), nên không cần chuyển code engine sang isolate khác.
// Dùng đếm tham chiếu: có nhiều việc cùng lúc thì dịch vụ chỉ tắt khi việc cuối cùng xong.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_foreground_task/flutter_foreground_task.dart';
import 'package:shared_preferences/shared_preferences.dart';

@pragma('vm:entry-point')
void yuiForegroundEntry() => FlutterForegroundTask.setTaskHandler(_YuiTaskHandler());

class _YuiTaskHandler extends TaskHandler {
  @override
  Future<void> onStart(DateTime timestamp, TaskStarter starter) async {}
  @override
  void onRepeatEvent(DateTime timestamp) {}
  @override
  Future<void> onDestroy(DateTime timestamp) async {}
  @override
  void onNotificationButtonPressed(String id) => FlutterForegroundTask.sendDataToMain(id);
}

class BackgroundGuard {
  static const _kEnabled = 'bg_enabled';
  static bool enabled = true; // công tắc "Chạy ngầm khi thoát app" trong Cài đặt
  static bool _inited = false;
  static int _users = 0;
  static final List<VoidCallback> _stopHandlers = [];

  static bool get _android => !kIsWeb && Platform.isAndroid;

  static Future<void> init() async {
    if (_inited) return;
    _inited = true;
    try {
      enabled = (await SharedPreferences.getInstance()).getBool(_kEnabled) ?? true;
      if (!_android) return;
      FlutterForegroundTask.init(
        androidNotificationOptions: AndroidNotificationOptions(
          channelId: 'yui_work',
          channelName: 'Yui đang làm việc',
          channelDescription: 'Hiện khi Yui đang chạy ngầm, có nút Dừng',
          channelImportance: NotificationChannelImportance.LOW,
          priority: NotificationPriority.LOW,
        ),
        iosNotificationOptions: const IOSNotificationOptions(showNotification: false),
        foregroundTaskOptions: ForegroundTaskOptions(eventAction: ForegroundTaskEventAction.nothing(), autoRunOnBoot: false, allowWakeLock: true, allowWifiLock: true),
      );
      FlutterForegroundTask.addTaskDataCallback((data) {
        if (data == 'stop') stopAll();
      });
    } catch (e) {
      debugPrint('BackgroundGuard.init: $e');
    }
  }

  static Future<void> setEnabled(bool v) async {
    enabled = v;
    try {
      await (await SharedPreferences.getInstance()).setBool(_kEnabled, v);
    } catch (_) {}
  }

  /// Đăng ký hàm sẽ chạy khi người dùng bấm "Dừng" trên thông báo.
  static void addStopHandler(VoidCallback f) {
    if (!_stopHandlers.contains(f)) _stopHandlers.add(f);
  }

  static void stopAll() {
    for (final f in List.of(_stopHandlers)) {
      try {
        f();
      } catch (e) {
        debugPrint('stop handler: $e');
      }
    }
  }

  static const _buttons = [NotificationButton(id: 'stop', text: 'Dừng')];

  static Future<void> begin(String title, String text) async {
    _users++;
    if (!enabled || !_android) return;
    try {
      if (await FlutterForegroundTask.checkNotificationPermission() != NotificationPermission.granted) {
        await FlutterForegroundTask.requestNotificationPermission();
      }
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text, notificationButtons: _buttons);
      } else {
        await FlutterForegroundTask.startService(
            serviceId: 7001, notificationTitle: title, notificationText: text, notificationButtons: _buttons, callback: yuiForegroundEntry);
      }
    } catch (e) {
      debugPrint('BackgroundGuard.begin: $e'); // không có dịch vụ nền thì app vẫn chạy bình thường khi đang mở
    }
  }

  /// Cập nhật dòng chữ/tiến độ trên thông báo thường trực.
  static Future<void> update(String text, {String? title}) async {
    if (!enabled || !_android || _users == 0) return;
    try {
      if (await FlutterForegroundTask.isRunningService) {
        await FlutterForegroundTask.updateService(notificationTitle: title, notificationText: text);
      }
    } catch (_) {}
  }

  static Future<void> end() async {
    if (_users > 0) _users--;
    if (_users > 0 || !_android) return;
    try {
      if (await FlutterForegroundTask.isRunningService) await FlutterForegroundTask.stopService();
    } catch (e) {
      debugPrint('BackgroundGuard.end: $e');
    }
  }
}
