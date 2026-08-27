# Retrofit + kotlinx.serialization keep rules.
-keepattributes Signature, InnerClasses, EnclosingMethod
-keepattributes RuntimeVisibleAnnotations, RuntimeVisibleParameterAnnotations
-keep,includedescriptorclasses class com.fieldar.plotfinder.data.net.**$$serializer { *; }
-keepclassmembers class com.fieldar.plotfinder.data.net.** { *** Companion; }
