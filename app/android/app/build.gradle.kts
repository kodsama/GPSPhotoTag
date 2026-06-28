plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "ai.kodsama.stunda"
    // Pinned to 36: some plugins (e.g. desktop_drop) compile against API 36 and
    // require all consumers to match.
    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "ai.kodsama.stunda"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // Writing GPS EXIF tags back onto MediaStore photos (see MainActivity).
    implementation("androidx.exifinterface:exifinterface:1.3.7")
    // ONNX Runtime native library (libonnxruntime.so per ABI), loaded by the
    // engine via dart:ffi DynamicLibrary.open("libonnxruntime.so") for the
    // people/animal detector and the Smart duplicate-metric embedder.
    implementation("com.microsoft.onnxruntime:onnxruntime-android:1.26.0")
}
