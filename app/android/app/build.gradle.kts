import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Push notifications read Firebase's android/app/google-services.json, which stays out of git.
// Without the file the app still builds and runs, with notifications off.
if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

// The release signing key lives outside git: android/key.properties points at the keystore.
// Without it, release builds fall back to the debug key (fine for trying, not for sharing).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.coreacademy.core_academy"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        applicationId = "com.coreacademy.core_academy"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        manifestPlaceholders["appLabel"] = "Core Academy"
    }

    signingConfigs {
        create("release") {
            keyAlias = keystoreProperties["keyAlias"] as String?
            keyPassword = keystoreProperties["keyPassword"] as String?
            storeFile = keystoreProperties["storeFile"]?.let { rootProject.file(it as String) }
            storePassword = keystoreProperties["storePassword"] as String?
        }
    }

    buildTypes {
        debug {
            // The test build sits beside the live app on the same phone and uses the dev API.
            applicationIdSuffix = ".dev"
            manifestPlaceholders["appLabel"] = "Core Academy Dev"
        }
        release {
            signingConfig = signingConfigs.getByName(if (keystorePropertiesFile.exists()) "release" else "debug")
            // A copy to try before a version goes live (tools/build-dev-copy.ps1 passes -PdevCopy=true): release speed, but its own app id and
            // name, so it sits beside the live app. The same script gives it the dev server's address. It is signed with the debug key, like the
            // debug builds that share its app id, so it updates a practice copy already on a phone in place (a different key is refused).
            if (project.hasProperty("devCopy")) {
                applicationIdSuffix = ".dev"
                manifestPlaceholders["appLabel"] = "Core Academy Dev"
                signingConfig = signingConfigs.getByName("debug")
            }
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
