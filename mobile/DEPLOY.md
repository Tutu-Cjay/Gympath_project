# Gympath - Build and Deploy to Android Phone

## Prerequisites

1. **Install Flutter** (if not installed):
   - Download from https://docs.flutter.dev/get-started/install
   - Add Flutter to your system PATH

2. **Install Android Studio** or Android SDK:
   - For building APK: Android SDK with `platform-tools` and build-tools

3. **Enable USB debugging** on your Android phone:
   - Settings > About phone > Tap "Build number" 7 times
   - Settings > Developer options > Enable "USB debugging"

## Build APK

**Option A - Use the script (Windows):**
Double-click `mobile\build_and_deploy.bat`

**Option B - Manual commands:**

Open a terminal in the project folder and run:

```bash
cd mobile
flutter pub get
flutter build apk --release
```

If the build fails (e.g. missing files), run `flutter create .` in the mobile folder first to regenerate platform files.

The APK will be created at:
`mobile/build/app/outputs/flutter-apk/app-release.apk`

## Deploy to Phone

### Option 1: USB (ADB)

1. Connect your phone via USB
2. Run:
```bash
flutter install --release
```
   Or with ADB directly:
```bash
adb install mobile/build/app/outputs/flutter-apk/app-release.apk
```

### Option 2: Transfer APK file

1. Copy `app-release.apk` to your phone (email, cloud, USB file transfer)
2. On your phone, open the APK file
3. Allow "Install from unknown sources" if prompted
4. Install the app

## First Run

- The app starts on the **Connect Device** screen
- Tap **Connect** or **Skip for now** to go to the main app
- Bottom navigation: Home, Workouts, Nutrition, Coach

## Troubleshooting

- **Flutter not found**: Add Flutter to PATH or use full path to `flutter.bat`
- **SDK not found**: Run `flutter doctor` and fix any issues
- **Build fails**: Run `flutter clean` then `flutter pub get` again
