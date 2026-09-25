# Gympath

Fitness cable machine motion tracking device and mobile phone application.

## Overview

- **Smart Tracker Device**: ESP32 + IMU based motion sensor with BLE connectivity
- **Mobile App**: Cross-platform iOS/Android app (React Native) for workout tracking

## Project Structure

```
Gympath/
├── firmware/           # ESP32 firmware (PlatformIO)
├── mobile/             # React Native app
├── docs/               # Requirements, protocol, user stories
├── UI_image/           # Design assets
└── README.md
```

## Quick Start

### Firmware (ESP32)

```bash
cd firmware
pio run
pio run --target upload
```

### Mobile App

```bash
cd mobile
npm install
npx react-native run-android   # or run-ios
```

## Documentation

- [Requirements](docs/requirements.md)
- [User Stories](docs/user_stories.md)
- [UI Flow](docs/ui_flow.md)
- [BLE Protocol](docs/ble_protocol.md)

## Hardware

- ESP32 (BLE 5.0)
- MPU6050 or MPU9250 IMU
- USB-C charging

## License

Proprietary
