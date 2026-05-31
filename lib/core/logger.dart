import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Structured in-memory logger (Phase F2.2).
///
/// Keeps a bounded ring buffer of JSON log lines that the diagnostics screen can
/// export, and mirrors every entry to the debug console. Consistent tags make
/// the player's behaviour greppable end-to-end.
///
/// Tags: INIT, CONFIG, XMDS, DOWNLOAD, XLF, SCHEDULE, PLAYER, XMR, STATE, ERROR.
class PlayerLogger {
  PlayerLogger._();

  static const int _maxLines = 1000;
  static final List<String> _buffer = <String>[];

  static void log(String tag, String message, {Map<String, dynamic>? data}) {
    final entry = <String, dynamic>{
      'ts': DateTime.now().toIso8601String(),
      'tag': tag,
      'msg': message,
      if (data != null) ...data,
    };
    String line;
    try {
      line = jsonEncode(entry);
    } catch (_) {
      // Non-encodable data (e.g. an object) — fall back to a string form.
      line = jsonEncode({
        'ts': entry['ts'],
        'tag': tag,
        'msg': message,
        if (data != null) 'data': data.toString(),
      });
    }
    _buffer.add(line);
    if (_buffer.length > _maxLines) _buffer.removeAt(0);
    debugPrint('[$tag] $message${data != null ? ' $data' : ''}');
  }

  static void error(String tag, String message, dynamic error, [StackTrace? st]) {
    log(tag, message, data: {
      'error': error.toString(),
      if (st != null) 'stack': st.toString(),
    });
  }

  static List<String> getLogs() => List.unmodifiable(_buffer);

  /// Export logs for the diagnostics screen.
  static String exportLogs() => _buffer.join('\n');

  static void clear() => _buffer.clear();
}
