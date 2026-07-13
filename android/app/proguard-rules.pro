# NOOP — R8 / ProGuard rules.
#
# The app is offline and reflection-light. Room generates its own keep rules, and
# Compose ships consumer rules, so this file is mostly empty by design. Add keeps
# here only if a release build strips something the BLE/protocol layer needs at runtime.

# Keep Room-generated database implementation classes (Room embeds its own rules too,
# but this is an explicit safety net for the *_Impl classes it generates).
-keep class com.noop.data.** { *; }

# Protocol enums are matched by Int rawValue via fromRaw(...); keep their members so a
# future reflective/serialized path can't be broken by minification. They are small.
-keep class com.noop.protocol.** { *; }

# Tink (pulled in by androidx.security:security-crypto for the encrypted AI-key store)
# references errorprone annotations that aren't on the runtime classpath. They're
# compile-time only and safe to ignore under R8.
-dontwarn com.google.errorprone.annotations.CanIgnoreReturnValue
-dontwarn com.google.errorprone.annotations.CheckReturnValue
-dontwarn com.google.errorprone.annotations.Immutable
-dontwarn com.google.errorprone.annotations.RestrictedApi

# Keep Compose runtime and UI internals (some use reflection for serialization/snapshots).
-keep class androidx.compose.** { *; }

# Keep Navigation Compose for route reflection.
-keep class androidx.navigation.** { *; }

# Keep Room runtime components.
-keep class androidx.room.** { *; }

# Keep Health Connect client (uses reflection for protobuf).
-keep class androidx.health.connect.** { *; }

# Keep OkHttp/Okio for AI Coach networking.
-keep class okhttp3.** { *; }
-keep class okio.** { *; }

# Keep Kotlinx serialization if used.
-keep class kotlinx.serialization.** { *; }

# Keep Coroutines internals.
-keep class kotlinx.coroutines.** { *; }

# Keep WorkManager for widgets.
-keep class androidx.work.** { *; }

# Keep Glance (widget) internals.
-keep class androidx.glance.** { *; }

# Preserve line numbers for readable stack traces, then hide the original source file name.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile

# Don't strip EnclosingMethod, InnerClasses, Signature — needed for Kotlin reflection.
-keepattributes EnclosingMethod,InnerClasses,Signature

# Keep annotations used by Room, Compose, etc.
-keepattributes *Annotation*
-keepattributes RuntimeVisibleAnnotations,RuntimeInvisibleAnnotations