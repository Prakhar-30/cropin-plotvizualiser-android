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
        // 26, as the Kotlin app was. The plugin itself needs only 21.
        minSdk = 26
        targetSdk = 35
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // One fixed key for field test builds, kept in the repository on purpose:
    // a debug key is generated afresh on every CI runner, so each build was
    // signed differently and Android refused to install one over another
    // ("App not installed"). With this key a new build installs over the old.
    // A test key, public with the repo - not for a Play Store release, which
    // needs its own key kept out of source control.
    signingConfigs {
        create("field") {
            storeFile = file("../field-build.keystore")
            storePassword = "plotfinder"
            keyAlias = "field"
            keyPassword = "plotfinder"
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("field")
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

