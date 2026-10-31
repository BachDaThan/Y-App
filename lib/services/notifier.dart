// notifier.dart - thông báo hệ thống (khi AI trả lời xong / tải cập nhật xong lúc app đang ở nền). Mọi lỗi đều bị nuốt: thông báo hỏng không được làm hỏng chat.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

class Notifier {
  static final FlutterLocalNotificationsPlugin _p = FlutterLocalNotificationsPlugin();
  static bool _ready = false;

  static Future<void> init() async {
    if (_ready || !Platform.isAndroid) return;
    try {
      await _p.initialize(const InitializationSettings(android: AndroidInitializationSettings('@mipmap/ic_launcher')));
      await _p.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()?.requestNotificationsPermission();
      _ready = true;
    } catch (e) {
      debugPrint('Notifier.init: $e');
    }
  }

  /// Thông báo một lần (đã xong / lỗi). [id] cố định theo loại để lần sau ghi đè thay vì chất đống.
  static Future<void> show(int id, String title, String body) async {
    if (!_ready) await init();
    if (!_ready) return;
    try {
      await _p.show(
        id,
        title,
        body,
        const NotificationDetails(
          android: AndroidNotificationDetails('yui_done', 'Yui đã xong việc',
              channelDescription: 'Báo khi Yui trả lời xong hoặc tải xong cập nhật', importance: Importance.defaultImportance, priority: Priority.defaultPriority),
        ),
      );
    } catch (e) {
      debugPrint('Notifier.show: $e');
    }
  }
}
