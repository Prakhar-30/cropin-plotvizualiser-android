plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.fieldar.plotfinder"
    compileSdk = 35
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.fieldar.plotfinder"
        // 26, as before: the rotation-vector remap and elapsedRealtimeNanos on a
        // Location are what the native channel relies on.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // Signed with the debug key so `flutter run --release` works out of
            // the box. Replace with a real signing config before distributing.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

flutter {
    source = "../.."
}

dependencies {
    // The fused provider, exactly as the Kotlin app used it, so a fix still
    // says whether it carries a bearing - see PlotFinderChannels.kt.
    implementation("com.google.android.gms:play-services-location:21.3.0")
}
