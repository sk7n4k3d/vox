-keep class chat.fluffy.fluffychat.bastien_fork.wear.** { *; }
-keep class com.google.android.gms.wearable.** { *; }

# Keep all logs (overrides default proguard-android-optimize.txt strip)
-keepclassmembers class android.util.Log {
    public static *** d(...);
    public static *** v(...);
    public static *** i(...);
    public static *** w(...);
    public static *** e(...);
}

-keepclassmembers class kotlinx.serialization.json.** {
    *** Companion;
}
-keepclasseswithmembers class kotlinx.serialization.json.** {
    kotlinx.serialization.KSerializer serializer(...);
}
