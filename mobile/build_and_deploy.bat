@echo off
echo Gympath - Building and deploying to Android...
cd /d "%~dp0"

where flutter >nul 2>&1
if %errorlevel% neq 0 (
    echo ERROR: Flutter is not installed or not in PATH.
    echo Install Flutter from https://docs.flutter.dev/get-started/install
    pause
    exit /b 1
)

echo.
echo Step 1: Getting dependencies...
call flutter pub get
if %errorlevel% neq 0 (
    echo Failed to get dependencies.
    pause
    exit /b 1
)

echo.
echo Step 2: Building release APK...
call flutter build apk --release
if %errorlevel% neq 0 (
    echo Build failed.
    pause
    exit /b 1
)

echo.
echo Build successful!
echo APK location: build\app\outputs\flutter-apk\app-release.apk
echo.

set /p deploy="Deploy to connected device now? (y/n): "
if /i "%deploy%"=="y" (
    echo.
    echo Installing on device...
    call flutter install --release
)

echo.
echo Done.
pause
