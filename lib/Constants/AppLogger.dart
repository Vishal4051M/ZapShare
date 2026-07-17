import 'dart:developer' as developer;

enum LogLevel { debug, info, warn, error }

class AppLogger {
  static void log(
    LogLevel level,
    String tag,
    String message, [
    Object? error,
    StackTrace? stackTrace,
  ]) {
    final levelStr = level.name.toUpperCase();
    developer.log(
      '[$levelStr] [$tag] $message',
      name: 'ZapShare',
      error: error,
      stackTrace: stackTrace,
      level: _levelToInt(level),
    );
  }

  static void d(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    log(LogLevel.debug, tag, message, error, stackTrace);
  }

  static void i(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    log(LogLevel.info, tag, message, error, stackTrace);
  }

  static void w(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    log(LogLevel.warn, tag, message, error, stackTrace);
  }

  static void e(String tag, String message, [Object? error, StackTrace? stackTrace]) {
    log(LogLevel.error, tag, message, error, stackTrace);
  }

  static int _levelToInt(LogLevel level) {
    switch (level) {
      case LogLevel.debug:
        return 500;
      case LogLevel.info:
        return 800;
      case LogLevel.warn:
        return 900;
      case LogLevel.error:
        return 1000;
    }
  }
}
