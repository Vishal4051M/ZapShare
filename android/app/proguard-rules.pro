# Add project specific ProGuard rules here.
# You can control the set of applied configuration files using the
# proguardFiles setting in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

# Uncomment this to preserve the line number information for
# debugging stack traces.
#-keepattributes SourceFile,LineNumberTable

# If you keep the line number information, uncomment this to
# hide the original source file name.
#-renamesourcefileattribute SourceFile

# Keep network-related classes
-keep class okhttp3.** { *; }
-keep class retrofit2.** { *; }
-keep class java.net.** { *; }
-keep class javax.net.** { *; }

# Keep HTTP client classes
-keep class dart.io.** { *; }
-keep class dart.async.** { *; }

# Keep Flutter plugin classes
-keep class io.flutter.plugins.** { *; }

# Keep SAF (Storage Access Framework) related classes
-keep class android.content.** { *; }
-keep class android.net.** { *; }
-keep class android.provider.** { *; }

# Keep method channels
-keep class com.example.zap_share.** { *; }
