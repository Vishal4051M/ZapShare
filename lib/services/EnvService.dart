import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class EnvService {
  static final Map<String, String> _envMap = {};

  /// Load and parse the `.env` asset file.
  static Future<void> init() async {
    try {
      final envString = await rootBundle.loadString('.env');
      final lines = envString.split('\n');
      for (var line in lines) {
        line = line.trim();
        if (line.isEmpty || line.startsWith('#')) continue;

        final equalIndex = line.indexOf('=');
        if (equalIndex == -1) continue;

        final key = line.substring(0, equalIndex).trim();
        var val = line.substring(equalIndex + 1).trim();

        // Strip surrounding quotes if present
        if ((val.startsWith("'") && val.endsWith("'")) ||
            (val.startsWith('"') && val.endsWith('"'))) {
          val = val.substring(1, val.length - 1);
        }

        _envMap[key] = val;
      }
      if (kDebugMode) {
        print('✅ Loaded ${_envMap.length} environment variables from .env asset');
      }
    } catch (e) {
      if (kDebugMode) {
        print('⚠️ Failed to load .env file: $e');
      }
    }
  }

  /// Retrieve an environment variable value by its key.
  static String get(String key, {String defaultValue = ''}) {
    return _envMap[key] ?? defaultValue;
  }
}
