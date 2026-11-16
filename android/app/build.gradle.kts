import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

if (file("google-services.json").exists()) {
    apply(plugin = "com.google.gms.google-services")
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4") // For flutter_local_notifications // Workaround for: https://github.com/MaikuB/flutter_local_notifications/issues/2286
    implementation("androidx.core:core-ktx:1.17.0") // For Android Auto

    // Wear OS bridge — DataClient + MessageClient + CapabilityClient phone↔watch
    implementation("com.google.android.gms:play-services-wearable:20.0.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-play-services:1.9.0")

    // ML Kit Smart Reply — bundled (PAS play-services-mlkit-smart-reply qui exige GMS)
    implementation("com.google.mlkit:smart-reply:17.0.4")

    // Compression vidéo native (remplace video_compress Flutter)
    implementation("androidx.media3:media3-transformer:1.9.1")

    // Tests JVM unit (règles d'écriture SmsSentReceiver, sans framework Android
    // à l'exécution : constantes Telephony inlinées à la compilation)
    testImplementation("junit:junit:4.13.2")
}


// Workaround for https://pub.dev/packages/unifiedpush#the-build-fails-because-of-duplicate-classes
configurations.all {
    // Use the latest version published: https://central.sonatype.com/artifact/com.google.crypto.tink/tink-android
    val tink = "com.google.crypto.tink:tink-android:1.17.0"
    // You can also use the library declaration catalog
    // val tink = libs.google.tink
    resolutionStrategy {
        force(tink)
        dependencySubstitution {
            substitute(module("com.google.crypto.tink:tink")).using(module(tink))
        }
    }
}


android {
    namespace = "chat.fluffy.fluffychat"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    signingConfigs {
        // LOCAL TEST ONLY — build debug signing for lab/testing builds. Not for distribution.
        create("release") {
            val debugKeystore = file("${System.getProperty("user.home")}/.android/debug.keystore")
            if (debugKeystore.exists()) {
                keyAlias = "androiddebugkey"
                keyPassword = "android"
                storeFile = debugKeystore
                storePassword = "android"
            } else {
                throw GradleException("Keystore de debug introuvable : $debugKeystore. Genere-le avec un build debug ou restaure dummy.keystore.")
            }
            enableV1Signing = true
            enableV2Signing = true
            enableV3Signing = true
            enableV4Signing = true
        }
    }

    val keystoreProperties = Properties()
    val keystorePropertiesFile = rootProject.file("key.properties")
    if (keystorePropertiesFile.exists()) {
        keystoreProperties.load(FileInputStream(keystorePropertiesFile))
        signingConfigs.getByName("release").apply {
            keyAlias = keystoreProperties["keyAlias"] as String
            keyPassword = keystoreProperties["keyPassword"] as String
            storeFile = keystoreProperties["storeFile"]?.let { file(it) }
            storePassword = keystoreProperties["storePassword"] as String
        }
    }

    defaultConfig {
        applicationId = "eu.devlabz.vox"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        ndk { // Workaround for https://github.com/flutter/flutter/issues/162153#issuecomment-2612443642
            // x86_64 retiré : vodozemac_bindings_dart ne compile pas en x86_64 (build.rs)
            // — et armeabi-v7a/x86 sont inutiles sur les appareils cibles 64 bits.
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        // Parité avec release pour le profiling sur appareil : même signature
        // (install in-place -r au-dessus de l'app release, données gardées),
        // même minification — les mesures profile-vs-release restent
        // comparables.
        getByName("profile") {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
        }
        release {
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}
