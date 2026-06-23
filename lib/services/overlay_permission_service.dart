import 'package:flutter/services.dart';

class OverlayPermissionService {
  static const MethodChannel _channel = MethodChannel('com.theadbook.player/overlay');

  static Future<bool> canDrawOverlays() async {
    try {
      final bool result = await _channel.invokeMethod('canDrawOverlays');
      return result;
    } catch (_) {
      return true;
    }
  }

  static Future<bool> requestOverlayPermission() async {
    try {
      final bool result = await _channel.invokeMethod('requestOverlayPermission');
      return result;
    } catch (_) {
      return false;
    }
  }
}
