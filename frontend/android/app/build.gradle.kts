import java.io.FileInputStream
import java.util.Base64
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// ── 릴리스 서명 (2026-10-22, 앱 1단계) ────────────────────────────────────────
// `android/key.properties`가 있으면 그 키로 릴리스에 서명한다. 없으면 **디버그 키**로 서명한다
// (지금까지와 같다 — CI·다른 팀원 PC에서도 키 없이 `flutter build apk --release`가 된다).
// key.properties·*.jks는 절대 커밋하지 않는다(.gitignore). CI는 비밀값에서 그때그때 만든다.
//   storeFile=upload-keystore.jks   ← android/app/ 기준 경로(또는 절대 경로)
//   storePassword=…  keyAlias=…  keyPassword=…
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseKey = keystorePropertiesFile.exists()
val keystoreProperties = Properties().apply {
    if (hasReleaseKey) FileInputStream(keystorePropertiesFile).use { load(it) }
}

fun keystoreValue(name: String): String =
    keystoreProperties.getProperty(name)?.trim()?.takeIf { it.isNotEmpty() }
        ?: error("android/key.properties에 '$name' 값이 없어요 — storeFile·storePassword·keyAlias·keyPassword 네 줄이 모두 필요합니다")

// ── 평문(http) 통신 허용 여부 ─────────────────────────────────────────────────
// 개발(debug·profile)은 USB + `adb reverse`로 http://127.0.0.1:8000 에 붙으므로 늘 허용한다.
// 릴리스는 **서버 주소가 http일 때만** 허용한다 — 빌드 때 넣은 `--dart-define=API_BASE_URL=…`를 읽는다.
// (flutter 도구는 dart-define을 `KEY=VALUE`의 base64를 쉼표로 이은 `dart-defines` 속성으로 넘긴다)
// 주소를 안 넣었으면 앱 기본값이 http://127.0.0.1:8000 이므로 허용한다(지금까지와 같다).
val dartDefines: Map<String, String> =
    (project.findProperty("dart-defines") as String?)
        ?.split(",")
        ?.mapNotNull { entry ->
            try {
                val decoded = String(Base64.getDecoder().decode(entry), Charsets.UTF_8)
                val eq = decoded.indexOf('=')
                if (eq > 0) decoded.substring(0, eq) to decoded.substring(eq + 1) else null
            } catch (e: IllegalArgumentException) {
                null
            }
        }
        ?.toMap()
        ?: emptyMap()
val releaseApiBaseUrl = dartDefines["API_BASE_URL"].orEmpty().trim()
val releaseAllowsCleartext =
    releaseApiBaseUrl.isEmpty() || releaseApiBaseUrl.startsWith("http://", ignoreCase = true)

android {
    namespace = "com.jeonseai.jeonse_ai"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // 휴대폰 알림(flutter_local_notifications)이 옛 안드로이드에서도 새 날짜 API를 쓰게 한다 (2026-10-22, P1-2)
        isCoreLibraryDesugaringEnabled = true
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.jeonseai.jeonse_ai"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // AndroidManifest.xml의 `${usesCleartextTraffic}` 자리. 개발 빌드는 허용(위 설명).
        manifestPlaceholders["usesCleartextTraffic"] = "true"
    }

    signingConfigs {
        if (hasReleaseKey) {
            create("release") {
                storeFile = file(keystoreValue("storeFile"))
                storePassword = keystoreValue("storePassword")
                keyAlias = keystoreValue("keyAlias")
                keyPassword = keystoreValue("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            // 키가 있으면 릴리스 키, 없으면 디버그 키 (`flutter run --release`도 그대로 된다)
            signingConfig = if (hasReleaseKey) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            manifestPlaceholders["usesCleartextTraffic"] = releaseAllowsCleartext.toString()
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    // 위 isCoreLibraryDesugaringEnabled의 짝 — 알림 플러그인 안내서가 정한 버전
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
