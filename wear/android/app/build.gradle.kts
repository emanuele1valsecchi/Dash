plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.dash.dash_wear"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // MUST match the phone app's applicationId exactly. The Wearable Data
        // Layer only routes messages between a handheld and a wearable app that
        // share a package name *and* a signing key — with different ids the
        // watch and phone simply never see each other, with no error to
        // explain why. `namespace` above may differ; only this must match.
        applicationId = "com.example.dash"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        // Wear OS 3 (API 30) and up. That covers Galaxy Watch 4 onward, every
        // Pixel Watch and TicWatch Pro 5 — effectively the whole active Wear OS
        // install base. Going lower would only reach Wear OS 2 hardware, where
        // Flutter performs badly on weak CPUs and Play support is winding down.
        // Note Galaxy Watch 3 and earlier run Tizen and are unreachable at any
        // minSdk. Overrides flutter.minSdkVersion, which targets phones.
        minSdk = 30
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

dependencies {
    // Wearable Data Layer: MessageClient for the live stats/command traffic,
    // NodeClient to find the phone. Same version as the phone app so the two
    // sides can't drift onto incompatible Play Services APIs.
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
}

flutter {
    source = "../.."
}
