# Gympath

Motion tracker for **cable-machine exercises**, plus a mobile app that shows every
rep as a live graph.

The tracker clips onto the cable or weight stack. When you press **Start** in the app,
the tracker measures gravity while it is held still. After that it records the
movement along that one axis: **+ up** (against gravity) and **− down**. The app
plots position (cm) against time and counts reps.

## Components

| Part | Tech | Path |
|---|---|---|
| Tracker firmware | ESP32-S3 + QMI8658 IMU + 240×240 TFT, Arduino (NimBLE 2.x) | `firmware/Gympath_Track/` |
| Mobile app | Flutter (Android; iOS planned) | `mobile/` |
| Backend | FastAPI + SQLite, JWT auth (local, not yet wired to the app) | `backend/` |
| Website | Static site on GitHub Pages — https://tutu-cjay.github.io/ (separate repo) | `website/` |
| Tools | USB test bridge, firmware release script, IMU debug viewer | `tools/` |

## Quick start

### Firmware

Board `esp32:esp32:esp32s3` (core 2.0.12), libraries QMI8658, TFT_eSPI 2.5.43,
NimBLE-Arduino 2.3.7.

```powershell
arduino-cli compile --fqbn esp32:esp32:esp32s3 firmware/Gympath_Track
arduino-cli upload  --fqbn esp32:esp32:esp32s3 -p COM4 firmware/Gympath_Track
```

Flash over USB once. Later versions install from the app over BLE
(**Home → update icon**). To publish a new version, bump `FW_VERSION` and run
`tools/release_firmware.ps1`.

### Mobile app

```powershell
cd mobile
flutter pub get
flutter run            # phone with Bluetooth, or an emulator + USB test mode
```

### Testing on the emulator without Bluetooth (USB test mode)

```
Tracker ──USB 921600──▶ tools/serial_bridge.py ──TCP 7700──▶ emulator app (10.0.2.2:7700)
```

1. Plug the tracker in over USB and run `python tools/serial_bridge.py`.
   Use `--sim` to test without a tracker.
2. In a debug build of the app, long-press the status chip → **USB test link** → Connect.
3. Open a workout and press **Start**. The tracker screen shows **USB TEST**.

### Backend

See [backend/README.md](backend/README.md) (`run_server.bat`, API docs at `/docs`).

## Status (2026-10-06)

- ✅ 1D tracking, live graph for every workout, OTA update path, USB test mode
- ✅ Tracker ↔ emulator verified end-to-end at 50 Hz
- 🟡 Position drift on longer hand-held sets: tuning on a real cable stack is next
- ⬜ OTA not yet run on hardware; backend not yet connected to the app

Details: [PROJECT_PLAN.md](PROJECT_PLAN.md).

## Documentation

- [Project plan & history](PROJECT_PLAN.md)
- [BLE protocol](docs/ble_protocol.md) (includes OTA and the USB test-mode protocol)
- [Technical docs](GYMPATH_DOCS.md)
- [Requirements](docs/requirements.md) · [User stories](docs/user_stories.md) · [UI flow](docs/ui_flow.md)

## License

Proprietary
