# Flutter
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }
-dontwarn io.flutter.embedding.**

# Rust FFI — keep JNI entry points
-keep class ls.bloomee.** { native <methods>; }
-keepclasseswithmembernames class * { native <methods>; }

# Firebase
-keep class com.google.firebase.** { *; }
-dontwarn com.google.firebase.**

# audio_service
-keep class com.ryanheise.audioservice.** { *; }
-keep class com.ryanheise.just_audio.** { *; }

# media_kit / libmpv
-keep class com.alexmercerind.** { *; }

# Keep all annotations
-keepattributes *Annotation*
-keepattributes Signature
