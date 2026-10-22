# Release builds are shrunk. Classes reached only from native code or by reflection must be kept, or they are stripped
# and fail at run time (as shared_preferences did in 0.2.0).

# WireGuard's Go backend calls back into these from native code
-keep class com.wireguard.** { *; }

# the VPN plug-in, and the JSON library it reads with by reflection on Kotlin classes
-keep class orban.group.wireguard_flutter.** { *; }
-keep class com.beust.klaxon.** { *; }
-keep class kotlin.Metadata { *; }
-dontwarn com.beust.klaxon.**

# No chatter in the TV's log: the VPN plug-in writes the whole WireGuard file there, private key and all, at info level
-assumenosideeffects class android.util.Log {
    public static int v(...);
    public static int d(...);
    public static int i(...);
}
