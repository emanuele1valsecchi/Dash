plugins {
    id("com.android.application")
    // Required for MainActivity.kt to compile at all, and for the `kotlin { }`
    // extension configured below to exist. Declared with its version in
    // settings.gradle.kts (`apply false`), so no version here. Not optional
    // while gradle.properties keeps `android.builtInKotlin=false` — without
    // it AGP 9 provides no Kotlin support of its own.
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.example.dash"
    compileSdk = 37
    ndkVersion = flutter.ndkVersion

    compileOptions {
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.example.dash"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // Wearable Data Layer, for talking to the Wear OS companion in wear/.
    // Keep this version in step with wear/android/app/build.gradle.kts.
    implementation("com.google.android.gms:play-services-wearable:18.2.0")
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}

flutter {
    source = "../.."
}
