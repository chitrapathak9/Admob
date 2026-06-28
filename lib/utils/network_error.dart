import 'dart:io';

import 'package:dio/dio.dart';

/// Translates low-level network exceptions into human-readable messages
/// suitable for display in the UI.
class NetworkError {
  NetworkError._();

  static const _noInternet =
      'Unable to reach the server. Please check your internet connection and try again.';
  static const _timeout =
      'The connection timed out. The server may be busy — please try again.';
  static const _badUrl =
      'Could not connect to the server. Please verify the Server URL and try again.';

  /// Returns a friendly error string for any exception thrown by Dio or dart:io.
  /// Falls back to the raw message if the error type is not recognised.
  static String parse(Object e) {
    // Dio-level errors still unwrapped (e.g. thrown directly from a service).
    if (e is DioException) {
      return _fromDio(e);
    }

    // dart:io socket errors (can bubble up from web_socket_channel too).
    if (e is SocketException) {
      return _noInternet;
    }

    // Errors already converted to plain Exception by a service layer.
    final msg = e.toString().replaceFirst('Exception: ', '').trim();
    return _fromMessage(msg);
  }

  static String _fromDio(DioException e) {
    switch (e.type) {
      case DioExceptionType.connectionError:
        return _noInternet;
      case DioExceptionType.connectionTimeout:
      case DioExceptionType.sendTimeout:
      case DioExceptionType.receiveTimeout:
        return _timeout;
      case DioExceptionType.badResponse:
        // Server replied with a non-2xx; surface its message if available.
        final body = e.response?.data;
        if (body is Map && body['message'] != null) {
          return body['message'].toString();
        }
        return 'Server returned an error (HTTP ${e.response?.statusCode}). Please try again.';
      default:
        return _fromMessage(e.message ?? 'Network error');
    }
  }

  static String _fromMessage(String msg) {
    final lower = msg.toLowerCase();

    if (lower.contains('socketexception') ||
        lower.contains('failed host lookup') ||
        lower.contains('no address associated') ||
        lower.contains('network is unreachable') ||
        lower.contains('no route to host') ||
        lower.contains('connection refused') ||
        lower.contains('network error connecting')) {
      return _noInternet;
    }

    if (lower.contains('timed out') ||
        lower.contains('timeout') ||
        lower.contains('connection timed out')) {
      return _timeout;
    }

    if (lower.contains('invalid url') ||
        lower.contains('invalid host') ||
        lower.contains('bad url') ||
        lower.contains('no host specified')) {
      return _badUrl;
    }

    // Return the original message — it came from the server and is already
    // readable (e.g. "Device not found", "Invalid CMS key").
    return msg.isEmpty ? 'An unexpected error occurred. Please try again.' : msg;
  }
}
