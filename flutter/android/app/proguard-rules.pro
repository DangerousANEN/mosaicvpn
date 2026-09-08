# ProGuard / R8 rules for MosaicVPN Android Release

# Keep Flutter wrapper and embedding classes
-keep class io.flutter.app.** { *; }
-keep class io.flutter.plugin.** { *; }
-keep class io.flutter.util.** { *; }
-keep class io.flutter.view.** { *; }
-keep class io.flutter.** { *; }
-keep class io.flutter.plugins.** { *; }

# Suppress Play Store deferred component warnings when not using Play Store bundles
-dontwarn com.google.android.play.core.**

# Keep libbox Go JNI bindings
-keep class io.nekohasekai.libbox.** { *; }
-keep interface io.nekohasekai.libbox.** { *; }

# Keep MosaicVPN Kotlin classes used across JNI, MethodChannel, and Services
-keep class ru.mosaicvpn.mosaic_vpn.** { *; }
-keepclassmembers class ru.mosaicvpn.mosaic_vpn.** { *; }
