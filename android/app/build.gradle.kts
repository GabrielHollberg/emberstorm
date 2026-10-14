import java.util.Properties

plugins {
    id("com.android.application")
}

// The upload key for Google Play (2026-10-13): Google keeps the key that signs
// what phones install (Play App Signing), and this one only proves an upload is
// ours. Its file is in the private repo; its password in a file outside every
// repository - EMBERSTORM_UPLOAD_PROPERTIES, else ~/.emberstorm/android-upload.properties
// (storeFile, storePassword, keyAlias, keyPassword). Without it, release builds
// are not signed and cannot be uploaded; the debug builds published on GitHub
// are unchanged.
val uploadProps = Properties().apply {
    val f = file(System.getenv("EMBERSTORM_UPLOAD_PROPERTIES")
        ?: "${System.getProperty("user.home")}/.emberstorm/android-upload.properties")
    if (f.isFile) f.inputStream().use { load(it) }
}

android {
    namespace = "dev.soundstorm.app"
    compileSdk = 36

    defaultConfig {
        applicationId = "dev.soundstorm.app"
        minSdk = 26
        targetSdk = 36
        versionCode = 67
        versionName = "0.67"
    }

    signingConfigs {
        if (uploadProps.getProperty("storeFile") != null) {
            create("upload") {
                storeFile = file(uploadProps.getProperty("storeFile"))
                storePassword = uploadProps.getProperty("storePassword")
                keyAlias = uploadProps.getProperty("keyAlias")
                keyPassword = uploadProps.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        // For Google Play: an app bundle (gradlew bundleRelease), signed with
        // the upload key.
        release {
            isMinifyEnabled = false
            signingConfigs.findByName("upload")?.let { signingConfig = it }
        }
        // The published APK is this build type, signed with the debug key so
        // it installs over earlier ones - but not debuggable: with it, anyone
        // with adb access could copy the sign-in cookies (run-as) and open a
        // console in the signed-in page (a security review).
        debug {
            isDebuggable = false
        }
    }

    buildFeatures {
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}

dependencies {
    // Only what the platform itself lacks: document-start scripts and origin-
    // checked messages for the web view, and the media session and its
    // notification. No AppCompat, no Compose - the screens are two.
    implementation("androidx.core:core-ktx:1.17.0")
    implementation("androidx.webkit:webkit:1.14.0")
    implementation("androidx.media:media:1.7.0")
    // Android's own media player, for songs from the server (AudioService):
    // screen-off playback, audio focus, gapless.
    implementation("androidx.media3:media3-exoplayer:1.5.1")
    // A long audiobook in one .m4b is played in pieces (the server's /api/bookhls).
    implementation("androidx.media3:media3-exoplayer-hls:1.5.1")
    implementation("androidx.media3:media3-session:1.5.1")
    // Phone photo backup (PhotoBackup): jobs Android runs when it suits -
    // on Wi-Fi, while charging - with the app closed.
    implementation("androidx.work:work-runtime-ktx:2.10.1")
    // Scanning a TV's sign-in QR code from inside the app: Google's own
    // scanner screen, from Play services - no camera permission, nothing of
    // the camera's in the app.
    implementation("com.google.android.gms:play-services-code-scanner:16.1.0")
}
