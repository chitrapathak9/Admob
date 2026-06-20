import 'package:flutter/services.dart';

class BatteryOptimizationService {
  static const MethodChannel _channel = MethodChannel('com.theadbook.player/battery');

  static Future<bool> isIgnoringBatteryOptimizations() async {
    try {
      final bool result = await _channel.invokeMethod('isIgnoringBatteryOptimizations');
      return result;
    } catch (e) {
      // Default to true if not supported to avoid false alarms
      return true;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimizations() async {
    try {
      final bool result = await _channel.invokeMethod('requestIgnoreBatteryOptimizations');
      return result;
    } catch (e) {
      return false;
    }
  }
}
