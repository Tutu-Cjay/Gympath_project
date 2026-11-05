# GYMPATH — Complete Project Documentation

> **Date:** 2026-04-05 | **Version:** 1.0 | **Status:** Active Development

> **Update 2026-10-06.** Sections 3–4 below describe the older `firmware/IMU_path`
> pipeline (Mahony AHRS, 3D) and the `WorkoutGameScreen`. The current product is
> **cable-machine only** and runs **`firmware/Gympath_Track`**:
> - 1D tracking along the gravity axis captured at START (+ up / − down), ZUPT, and a
>   direction-agnostic rep counter. No Mahony filter.
> - App: `CableTrackScreen` is the live graph for every workout.
> - OTA firmware updates over BLE, and a USB test mode for emulator testing.
> - A FastAPI + SQLite backend now exists (`backend/`), but the app does not use it yet.
>
> For the current state see [PROJECT_PLAN.md](PROJECT_PLAN.md) (phases 8.6–8.8) and
> [docs/ble_protocol.md](docs/ble_protocol.md). Build steps for the current firmware
> are in [README.md](README.md).

---

## Table of Contents

1. [Project Overview](#1-project-overview)
2. [System Architecture](#2-system-architecture)
3. [ESP32 Smart Tracker Firmware](#3-esp32-smart-tracker-firmware)
   - 3.1 Hardware Components
   - 3.2 Firmware Algorithm Pipeline (SVG)
   - 3.3 AHRS / Mahony Filter Pipeline (SVG)
   - 3.4 Rep Detection Algorithm
4. [Mobile App (Flutter)](#4-mobile-app-flutter)
   - 4.1 Screen Navigation Flow (SVG)
   - 4.2 BLE Communication Pipeline (SVG)
   - 4.3 Workout Game Algorithm (SVG)
5. [BLE Protocol Reference](#5-ble-protocol-reference)
6. [Code Errors & Bugs Found](#6-code-errors--bugs-found)
7. [Next Steps & Roadmap](#7-next-steps--roadmap)
8. [Build & Deploy Guide](#8-build--deploy-guide)

---

## 1. Project Overview

**Gympath** is a wearable fitness tracking system for gym workouts — particularly cable machines, free weights, and bodyweight exercises. The system consists of:

| Component | Technology | Role |
|---|---|---|
| **Smart Tracker** | ESP32-S3 + QMI8658 IMU + TFT Display | Wearable sensor — measures motion, counts reps, shows count on screen |
| **Mobile App** | Flutter (Android/iOS) | Real-time workout visualisation, rep tracking, leaderboard |
| **BLE Link** | NimBLE (device) + flutter_blue_plus (app) | Wireless 50 Hz data stream |

**No backend server currently exists.** All data processing happens on-device (ESP32) and in the mobile app. A backend is planned in next steps.

---

## 2. System Architecture

```
┌─────────────────────────────────────────────────────┐
│                  GYMPATH SYSTEM                      │
│                                                     │
│  ┌──────────────┐   BLE 4.2/5.0   ┌──────────────┐ │
│  │  ESP32-S3    │ ───────────────► │  Flutter App │ │
│  │  Smart       │   50 Hz / 60B   │  Android/iOS │ │
│  │  Tracker     │ ◄─────────────── │              │ │
│  └──────────────┘  Write cmds      └──────┬───────┘ │
│                                           │         │
│                                    (planned)        │
│                                           ▼         │
│                                   ┌──────────────┐  │
│                                   │  REST/WS     │  │
│                                   │  Backend     │  │
│                                   │  (future)    │  │
│                                   └──────────────┘  │
└─────────────────────────────────────────────────────┘
```

---

## 3. ESP32 Smart Tracker Firmware

### 3.1 Hardware Components

| Part | Value |
|---|---|
| MCU | ESP32-S3 |
| IMU | QMI8658 (Accel + Gyro) on I²C pins SDA=6, SCL=7 |
| Display | TFT_eSPI (round 240×240, backlight on GPIO 40) |
| BLE Stack | NimBLE-Arduino |
| Accel range | ±4 g |
| Gyro range | ±512 dps |
| ODR (both) | 1000 Hz |
| BLE MTU | 185 bytes |
| Tx power | +9 dBm |

### 3.2 Firmware Algorithm Pipeline


<svg xmlns="http://www.w3.org/2000/svg" width="820" height="900" viewBox="0 0 820 900">
  <defs>
    <marker id="arrow" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#00FF88"/>
    </marker>
    <filter id="glow">
      <feGaussianBlur stdDeviation="2" result="coloredBlur"/>
      <feMerge><feMergeNode in="coloredBlur"/><feMergeNode in="SourceGraphic"/></feMerge>
    </filter>
  </defs>
  <!-- Background -->
  <rect width="820" height="900" fill="#0D0D0D" rx="16"/>

  <!-- Title -->
  <text x="410" y="36" text-anchor="middle" fill="#00FF88" font-size="18" font-family="monospace" font-weight="bold" filter="url(#glow)">ESP32 SMART TRACKER — FIRMWARE PIPELINE</text>

  <!-- SETUP PHASE -->
  <text x="60" y="72" fill="#888" font-size="12" font-family="monospace">── SETUP ──────────────────────────────────</text>

  <!-- Block: Power On -->
  <rect x="60" y="84" width="160" height="48" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="140" y="104" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Power On</text>
  <text x="140" y="122" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Serial 115200 baud</text>

  <!-- Block: I2C + IMU Init -->
  <rect x="280" y="84" width="180" height="48" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="370" y="104" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">I²C + QMI8658 Init</text>
  <text x="370" y="122" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">±4g, ±512dps, 1000Hz</text>

  <!-- Block: TFT Init -->
  <rect x="520" y="84" width="160" height="48" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="600" y="104" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">TFT Display Init</text>
  <text x="600" y="122" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">240×240 + Boot Logo</text>

  <!-- Arrows setup row -->
  <line x1="220" y1="108" x2="278" y2="108" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="460" y1="108" x2="518" y2="108" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Calibrate Init Orientation -->
  <rect x="280" y="172" width="240" height="48" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="400" y="192" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Calibrate Initial Orientation</text>
  <text x="400" y="210" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">400 samples @ 5ms → quaternion qInit</text>

  <!-- Setup phase down arrows -->
  <line x1="370" y1="132" x2="370" y2="170" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="600" y1="132" x2="600" y2="152" stroke="#00FF88" stroke-width="1"/>
  <line x1="600" y1="152" x2="400" y2="152" stroke="#00FF88" stroke-width="1"/>
  <line x1="400" y1="152" x2="400" y2="170" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="140" y1="132" x2="140" y2="152" stroke="#00FF88" stroke-width="1"/>
  <line x1="140" y1="152" x2="370" y2="152" stroke="#00FF88" stroke-width="1"/>

  <!-- Block: Setup BLE -->
  <rect x="560" y="172" width="160" height="48" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="640" y="192" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Setup BLE (NimBLE)</text>
  <text x="640" y="210" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Advertise "Smart Tracker"</text>

  <!-- LOOP PHASE label -->
  <text x="60" y="258" fill="#888" font-size="12" font-family="monospace">── MAIN LOOP (≈500 Hz) ────────────────────</text>

  <!-- Block: Read IMU -->
  <rect x="60" y="272" width="160" height="48" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="140" y="292" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Read QMI8658</text>
  <text x="140" y="310" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">ax,ay,az [m/s²] gx,gy,gz [°/s]</text>

  <!-- Init to loop arrows -->
  <line x1="400" y1="220" x2="400" y2="244" stroke="#00FF88" stroke-width="1"/>
  <line x1="400" y1="244" x2="140" y2="244" stroke="#00FF88" stroke-width="1"/>
  <line x1="140" y1="244" x2="140" y2="270" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Mahony AHRS -->
  <rect x="280" y="272" width="180" height="48" rx="10" fill="#2E1A1A" stroke="#FF8844" stroke-width="1.5"/>
  <text x="370" y="292" text-anchor="middle" fill="#FF8844" font-size="12" font-family="monospace" font-weight="bold">Mahony AHRS</text>
  <text x="370" y="310" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">filter.updateIMU() → q[4]</text>

  <line x1="220" y1="296" x2="278" y2="296" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Rotate to Earth Frame -->
  <rect x="520" y="272" width="200" height="48" rx="10" fill="#2E1A1A" stroke="#FF8844" stroke-width="1.5"/>
  <text x="620" y="292" text-anchor="middle" fill="#FF8844" font-size="12" font-family="monospace" font-weight="bold">Rotate to Earth Frame</text>
  <text x="620" y="310" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">ax_e, ay_e, az_e via quaternion</text>

  <line x1="460" y1="296" x2="518" y2="296" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Subtract Gravity -->
  <rect x="520" y="360" width="200" height="48" rx="10" fill="#2E1A1A" stroke="#FF8844" stroke-width="1.5"/>
  <text x="620" y="380" text-anchor="middle" fill="#FF8844" font-size="12" font-family="monospace" font-weight="bold">Remove Gravity Bias</text>
  <text x="620" y="398" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">ax_lin = ax_e − gInitX</text>

  <line x1="620" y1="320" x2="620" y2="358" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: LPF -->
  <rect x="280" y="360" width="180" height="48" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="370" y="380" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Low-Pass Filter</text>
  <text x="370" y="398" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">α=0.70 → accX_f, accY_f, accZ_f</text>

  <line x1="518" y1="384" x2="462" y2="384" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Integrate Velocity -->
  <rect x="60" y="360" width="180" height="48" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="150" y="380" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Integrate Velocity</text>
  <text x="150" y="398" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">vel += acc×dt, damp=0.98</text>

  <line x1="278" y1="384" x2="242" y2="384" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Integrate Position -->
  <rect x="60" y="448" width="180" height="48" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="150" y="468" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Integrate Position</text>
  <text x="150" y="486" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">pos += vel×dt, damp=0.995</text>

  <line x1="150" y1="408" x2="150" y2="446" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Acc Envelope -->
  <rect x="300" y="448" width="200" height="48" rx="10" fill="#2E1A1A" stroke="#FF8844" stroke-width="1.5"/>
  <text x="400" y="468" text-anchor="middle" fill="#FF8844" font-size="12" font-family="monospace" font-weight="bold">Acceleration Envelope</text>
  <text x="400" y="486" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">|√(ax²+ay²+az²) − 9.81| EMA α=0.4</text>

  <!-- Arrow from subtract gravity down-left to accEnv -->
  <line x1="620" y1="408" x2="620" y2="432" stroke="#00FF88" stroke-width="1"/>
  <line x1="620" y1="432" x2="400" y2="432" stroke="#00FF88" stroke-width="1"/>
  <line x1="400" y1="432" x2="400" y2="446" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Beat-Lock Rep Counter -->
  <rect x="300" y="536" width="200" height="48" rx="10" fill="#2E2A1A" stroke="#FFD700" stroke-width="1.5"/>
  <text x="400" y="556" text-anchor="middle" fill="#FFD700" font-size="12" font-family="monospace" font-weight="bold">Beat-Lock Rep Counter</text>
  <text x="400" y="574" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">accEnv &gt; 1.0 → motionCount++</text>

  <line x1="400" y1="496" x2="400" y2="534" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: Display Update -->
  <rect x="560" y="536" width="200" height="48" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="660" y="556" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">TFT Display Update</text>
  <text x="660" y="574" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">7-seg digit + color ring</text>

  <line x1="500" y1="560" x2="558" y2="560" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: BLE Notify -->
  <rect x="60" y="536" width="200" height="48" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="160" y="556" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">BLE Notify @ 50 Hz</text>
  <text x="160" y="574" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">60-byte MotionPacket</text>

  <line x1="300" y1="560" x2="262" y2="560" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Block: delay(2) loop back -->
  <rect x="300" y="624" width="200" height="40" rx="10" fill="#111" stroke="#555" stroke-width="1.5"/>
  <text x="400" y="648" text-anchor="middle" fill="#555" font-size="12" font-family="monospace">delay(2ms) → loop()</text>

  <line x1="400" y1="584" x2="400" y2="622" stroke="#555" stroke-width="1.5" marker-end="url(#arrow)"/>
  <line x1="300" y1="644" x2="40" y2="644" stroke="#555" stroke-width="1"/>
  <line x1="40" y1="644" x2="40" y2="296" stroke="#555" stroke-width="1"/>
  <line x1="40" y1="296" x2="58" y2="296" stroke="#555" stroke-width="1.5" marker-end="url(#arrow)"/>

  <!-- Rest counter note -->
  <rect x="560" y="448" width="200" height="48" rx="10" fill="#2E2A1A" stroke="#FFD700" stroke-width="1"/>
  <text x="660" y="468" text-anchor="middle" fill="#FFD700" font-size="11" font-family="monospace" font-weight="bold">Rest Detection</text>
  <text x="660" y="486" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">accEnv&lt;0.2 for 10+ ticks → vel=0</text>
  <line x1="150" y1="496" x2="150" y2="512" stroke="#555" stroke-width="1"/>
  <line x1="150" y1="512" x2="660" y2="512" stroke="#555" stroke-width="1"/>
  <line x1="660" y1="512" x2="660" y2="446" stroke="#555" stroke-width="1" marker-end="url(#arrow)"/>

  <!-- Legend -->
  <rect x="60" y="700" width="700" height="160" rx="10" fill="#111" stroke="#333"/>
  <text x="410" y="724" text-anchor="middle" fill="#888" font-size="12" font-family="monospace">LEGEND</text>
  <rect x="80" y="738" width="16" height="16" rx="3" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="102" y="751" fill="#00FF88" font-size="11" font-family="monospace">Sensor / Output</text>
  <rect x="260" y="738" width="16" height="16" rx="3" fill="#2E1A1A" stroke="#FF8844" stroke-width="1.5"/>
  <text x="282" y="751" fill="#FF8844" font-size="11" font-family="monospace">Math / DSP</text>
  <rect x="420" y="738" width="16" height="16" rx="3" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="442" y="751" fill="#6EA8FF" font-size="11" font-family="monospace">Integration</text>
  <rect x="580" y="738" width="16" height="16" rx="3" fill="#2E2A1A" stroke="#FFD700" stroke-width="1.5"/>
  <text x="602" y="751" fill="#FFD700" font-size="11" font-family="monospace">Logic / Counter</text>
  <text x="80" y="790" fill="#666" font-size="10" font-family="monospace">Packet fields: ts_ms | ax,ay,az | gx,gy,gz | accEnv | velX,velY,velZ | posX,posY,posZ | motionCount</text>
  <text x="80" y="810" fill="#666" font-size="10" font-family="monospace">Total: 4+3×4+3×4+4+3×4+3×4+4 = 60 bytes (little-endian packed struct)</text>
  <text x="80" y="830" fill="#666" font-size="10" font-family="monospace">BLE MTU: 185B | Notify interval: 20ms (50 Hz) | Advertising: "Smart Tracker"</text>
  <text x="80" y="850" fill="#666" font-size="10" font-family="monospace">Service UUID: 12345678-1234-5678-1234-56789abcdef0</text>
</svg>

---

### 3.3 AHRS / Mahony Filter Pipeline

<svg xmlns="http://www.w3.org/2000/svg" width="760" height="440" viewBox="0 0 760 440">
  <defs>
    <marker id="arr2" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#FF8844"/>
    </marker>
  </defs>
  <rect width="760" height="440" fill="#0D0D0D" rx="16"/>
  <text x="380" y="32" text-anchor="middle" fill="#FF8844" font-size="16" font-family="monospace" font-weight="bold">MAHONY AHRS — SENSOR FUSION PIPELINE</text>

  <!-- Accel input -->
  <rect x="30" y="60" width="140" height="60" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="100" y="84" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Accelerometer</text>
  <text x="100" y="100" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">ax, ay, az [m/s²]</text>
  <text x="100" y="114" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">1000 Hz ODR</text>

  <!-- Gyro input -->
  <rect x="30" y="160" width="140" height="60" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="100" y="184" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Gyroscope</text>
  <text x="100" y="200" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">gx, gy, gz [°/s]</text>
  <text x="100" y="214" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">×DEG_TO_RAD → rad/s</text>

  <!-- Mahony box -->
  <rect x="230" y="80" width="200" height="140" rx="12" fill="#2E1A1A" stroke="#FF8844" stroke-width="2"/>
  <text x="330" y="108" text-anchor="middle" fill="#FF8844" font-size="13" font-family="monospace" font-weight="bold">Mahony AHRS</text>
  <text x="330" y="130" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">filter.begin(500 Hz)</text>
  <line x1="250" y1="142" x2="410" y2="142" stroke="#555" stroke-width="0.5"/>
  <text x="330" y="160" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Mahony PI controller</text>
  <text x="330" y="176" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Kp=2.0, Ki=0.005</text>
  <text x="330" y="196" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Quaternion integration</text>

  <!-- Quaternion output -->
  <rect x="500" y="80" width="200" height="80" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="600" y="108" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Quaternion Output</text>
  <text x="600" y="128" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">q0, q1, q2, q3</text>
  <text x="600" y="148" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">filter.q0 … filter.q3</text>

  <!-- Rotation matrix box -->
  <rect x="500" y="200" width="200" height="80" rx="10" fill="#2E1A1A" stroke="#FF8844" stroke-width="1.5"/>
  <text x="600" y="228" text-anchor="middle" fill="#FF8844" font-size="12" font-family="monospace" font-weight="bold">rotateToEarth()</text>
  <text x="600" y="248" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">R(q) × [ax,ay,az]ᵀ</text>
  <text x="600" y="264" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">→ ax_e, ay_e, az_e</text>

  <!-- Gravity subtract -->
  <rect x="500" y="320" width="200" height="60" rx="10" fill="#2E2A1A" stroke="#FFD700" stroke-width="1.5"/>
  <text x="600" y="348" text-anchor="middle" fill="#FFD700" font-size="12" font-family="monospace" font-weight="bold">Remove Gravity</text>
  <text x="600" y="366" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">ax_lin = ax_e − gInitX</text>

  <!-- Earth frame box -->
  <rect x="230" y="280" width="200" height="100" rx="12" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="330" y="308" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Linear Accel</text>
  <text x="330" y="326" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Earth-frame, gravity-free</text>
  <text x="330" y="344" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">ax_lin, ay_lin, az_lin</text>
  <text x="330" y="364" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">→ LPF → integrate</text>

  <!-- Initial calibration -->
  <rect x="30" y="280" width="160" height="80" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="110" y="308" text-anchor="middle" fill="#6EA8FF" font-size="11" font-family="monospace" font-weight="bold">Init Calibration</text>
  <text x="110" y="326" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">400 samples → qInit</text>
  <text x="110" y="344" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">gInitX/Y/Z (gravity ref)</text>

  <!-- Arrows -->
  <line x1="170" y1="90" x2="228" y2="130" stroke="#FF8844" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="170" y1="190" x2="228" y2="160" stroke="#FF8844" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="430" y1="150" x2="498" y2="120" stroke="#FF8844" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="600" y1="160" x2="600" y2="198" stroke="#FF8844" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="600" y1="280" x2="600" y2="318" stroke="#FF8844" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="500" y1="350" x2="432" y2="350" stroke="#FF8844" stroke-width="1.5" marker-end="url(#arr2)"/>
  <line x1="190" y1="320" x2="228" y2="320" stroke="#00FF88" stroke-width="1.5" marker-end="url(#arr2)"/>

  <!-- Note -->
  <text x="30" y="410" fill="#555" font-size="10" font-family="monospace">NOTE: filter.begin(500) sets sample rate. Actual loop runs ~500Hz via delay(2ms). Gyro in deg/s × DEG_TO_RAD before filter.</text>
</svg>

### 3.4 Rep Detection Algorithm

The firmware uses an **acceleration envelope + beat-lock** mechanism:

accEnv (EMA) = 0.60 × accEnv_prev + 0.40 × |‖accel_earth‖ − 9.81|

Rep counted WHEN:
  accEnv > goodTh (1.0 m/s²)  AND  beatLock == false
  → motionCount++
  → beatLock = true

Lock RELEASED when:
  accEnv < 0.8 m/s²

Rest detected when:
  accEnv < slowTh (0.2 m/s²)  for 10+ consecutive samples
  → velX = velY = velZ = 0 (velocity zero)
  → position slowly damps (posDamp = 0.995)

**Thresholds:**

| Variable | Value | Purpose |
|---|---|---|
| `slowTh` | 0.2 m/s² | Rest detection lower bound |
| `goodTh` | 1.0 m/s² | Rep trigger threshold |
| `fastTh` | 3.80 m/s² | Max for colour normalisation |
| `velDamp` | 0.98 | Velocity damping per tick |
| `posDamp` | 0.995 | Position damping during rest |
| `accelLPF` | 0.70 | Low-pass filter coefficient |

---

## 4. Mobile App (Flutter)

**Tech Stack:** Flutter 3.0+, Dart SDK ≥3.0  
**BLE Library:** flutter_blue_plus ^1.32.0  
**Permissions:** BLUETOOTH_SCAN, BLUETOOTH_CONNECT, BLUETOOTH_ADVERTISE, ACCESS_FINE_LOCATION  

### 4.1 Screen Navigation Flow

<svg xmlns="http://www.w3.org/2000/svg" width="780" height="620" viewBox="0 0 780 620">
  <defs>
    <marker id="nav" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#00FF88"/>
    </marker>
    <marker id="nav_gray" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#555"/>
    </marker>
  </defs>
  <rect width="780" height="620" fill="#0D0D0D" rx="16"/>
  <text x="390" y="32" text-anchor="middle" fill="#00FF88" font-size="16" font-family="monospace" font-weight="bold">GYMPATH MOBILE — SCREEN NAVIGATION FLOW</text>

  <!-- Splash Screen -->
  <rect x="310" y="54" width="160" height="52" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="2"/>
  <text x="390" y="78" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Splash Screen</text>
  <text x="390" y="96" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">2 sec logo animation</text>

  <!-- Connect Device -->
  <rect x="310" y="150" width="160" height="52" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="2"/>
  <text x="390" y="174" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Connect Device</text>
  <text x="390" y="192" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">BLE scan &amp; pair</text>

  <line x1="390" y1="106" x2="390" y2="148" stroke="#00FF88" stroke-width="1.5" marker-end="url(#nav)"/>
  <text x="396" y="132" fill="#666" font-size="9" font-family="monospace">auto</text>

  <!-- Home Screen -->
  <rect x="290" y="256" width="200" height="52" rx="10" fill="#1A2E2E" stroke="#6EA8FF" stroke-width="2"/>
  <text x="390" y="280" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Home Screen</text>
  <text x="390" y="298" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">IndexedStack (4 tabs)</text>

  <!-- Connect → Home (connect) -->
  <line x1="350" y1="202" x2="320" y2="254" stroke="#00FF88" stroke-width="1.5" marker-end="url(#nav)"/>
  <text x="290" y="234" fill="#666" font-size="9" font-family="monospace">Connected</text>

  <!-- Skip → Home -->
  <line x1="430" y1="202" x2="460" y2="254" stroke="#555" stroke-width="1.5" stroke-dasharray="4,3" marker-end="url(#nav_gray)"/>
  <text x="454" y="234" fill="#555" font-size="9" font-family="monospace">Skip</text>

  <!-- Tab 1 -->
  <rect x="30" y="362" width="140" height="60" rx="8" fill="#111" stroke="#00FF88" stroke-width="1"/>
  <text x="100" y="386" text-anchor="middle" fill="#00FF88" font-size="11" font-family="monospace" font-weight="bold">Tab 1: Home</text>
  <text x="100" y="404" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Dashboard</text>
  <text x="100" y="416" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Streak, Stats</text>

  <!-- Tab 2 -->
  <rect x="195" y="362" width="140" height="60" rx="8" fill="#111" stroke="#00FF88" stroke-width="1"/>
  <text x="265" y="386" text-anchor="middle" fill="#00FF88" font-size="11" font-family="monospace" font-weight="bold">Tab 2: Workouts</text>
  <text x="265" y="404" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Choose Workout</text>
  <text x="265" y="416" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Select exercise</text>

  <!-- Tab 3 -->
  <rect x="360" y="362" width="140" height="60" rx="8" fill="#111" stroke="#00FF88" stroke-width="1"/>
  <text x="430" y="386" text-anchor="middle" fill="#00FF88" font-size="11" font-family="monospace" font-weight="bold">Tab 3: Nutrition</text>
  <text x="430" y="404" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Meal Plan</text>
  <text x="430" y="416" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Grocery list</text>

  <!-- Tab 4 -->
  <rect x="525" y="362" width="140" height="60" rx="8" fill="#111" stroke="#00FF88" stroke-width="1"/>
  <text x="595" y="386" text-anchor="middle" fill="#00FF88" font-size="11" font-family="monospace" font-weight="bold">Tab 4: Coach</text>
  <text x="595" y="404" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Monitoring +</text>
  <text x="595" y="416" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Leaderboard</text>

  <!-- Home to Tabs -->
  <line x1="340" y1="308" x2="100" y2="360" stroke="#6EA8FF" stroke-width="1" marker-end="url(#nav)"/>
  <line x1="365" y1="308" x2="265" y2="360" stroke="#6EA8FF" stroke-width="1" marker-end="url(#nav)"/>
  <line x1="415" y1="308" x2="430" y2="360" stroke="#6EA8FF" stroke-width="1" marker-end="url(#nav)"/>
  <line x1="440" y1="308" x2="595" y2="360" stroke="#6EA8FF" stroke-width="1" marker-end="url(#nav)"/>

  <!-- Tab 2 → Workout Game -->
  <rect x="195" y="470" width="140" height="60" rx="8" fill="#2E2A1A" stroke="#FFD700" stroke-width="1.5"/>
  <text x="265" y="494" text-anchor="middle" fill="#FFD700" font-size="11" font-family="monospace" font-weight="bold">Workout Game</text>
  <text x="265" y="512" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Live BLE motion</text>
  <text x="265" y="524" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Rep count + accuracy</text>

  <line x1="265" y1="422" x2="265" y2="468" stroke="#FFD700" stroke-width="1.5" marker-end="url(#nav)"/>
  <text x="271" y="448" fill="#666" font-size="9" font-family="monospace">select</text>

  <!-- Workout Game → Motion Log -->
  <rect x="380" y="470" width="140" height="60" rx="8" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1"/>
  <text x="450" y="494" text-anchor="middle" fill="#6EA8FF" font-size="11" font-family="monospace" font-weight="bold">Motion Log</text>
  <text x="450" y="512" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Live chart</text>
  <text x="450" y="524" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">posZ + accEnv</text>

  <line x1="335" y1="500" x2="378" y2="500" stroke="#6EA8FF" stroke-width="1" marker-end="url(#nav)"/>
  <text x="340" y="494" fill="#666" font-size="9" font-family="monospace">chart icon</text>

  <!-- Tab 4 → sub tabs -->
  <rect x="525" y="470" width="140" height="40" rx="8" fill="#111" stroke="#555" stroke-width="1"/>
  <text x="595" y="494" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Gym Monitoring</text>
  <rect x="525" y="522" width="140" height="40" rx="8" fill="#111" stroke="#555" stroke-width="1"/>
  <text x="595" y="546" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Leaderboard</text>
  <line x1="595" y1="422" x2="595" y2="468" stroke="#555" stroke-width="1" marker-end="url(#nav_gray)"/>

  <!-- Tab 1 → Add Workout -->
  <rect x="30" y="470" width="140" height="40" rx="8" fill="#111" stroke="#555" stroke-width="1"/>
  <text x="100" y="494" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">+ Add Workout →</text>
  <text x="100" y="505" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">ChooseWorkoutScreen</text>
  <line x1="100" y1="422" x2="100" y2="468" stroke="#555" stroke-width="1" marker-end="url(#nav_gray)"/>

  <!-- Footer -->
  <rect x="30" y="582" width="720" height="24" rx="6" fill="#111" stroke="#222"/>
  <text x="390" y="598" text-anchor="middle" fill="#555" font-size="10" font-family="monospace">All routes: /splash → /connect → /home | Named routes via MaterialApp.routes</text>
</svg>

### 4.2 BLE Communication Pipeline

<svg xmlns="http://www.w3.org/2000/svg" width="760" height="540" viewBox="0 0 760 540">
  <defs>
    <marker id="ble" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#6EA8FF"/>
    </marker>
  </defs>
  <rect width="760" height="540" fill="#0D0D0D" rx="16"/>
  <text x="380" y="32" text-anchor="middle" fill="#6EA8FF" font-size="16" font-family="monospace" font-weight="bold">BLE COMMUNICATION PIPELINE</text>

  <!-- ESP32 side column -->
  <rect x="20" y="50" width="200" height="450" rx="12" fill="#1A2E1A" stroke="#00FF88" stroke-width="1.5"/>
  <text x="120" y="76" text-anchor="middle" fill="#00FF88" font-size="13" font-family="monospace" font-weight="bold">ESP32 (Server)</text>

  <rect x="35" y="88" width="170" height="36" rx="8" fill="#0D1A0D" stroke="#00FF88" stroke-width="1"/>
  <text x="120" y="110" text-anchor="middle" fill="#00FF88" font-size="10" font-family="monospace">NimBLE GATT Server</text>

  <rect x="35" y="134" width="170" height="36" rx="8" fill="#0D1A0D" stroke="#00CC6A" stroke-width="1"/>
  <text x="120" y="152" text-anchor="middle" fill="#00CC6A" font-size="10" font-family="monospace">Service: …cdef0</text>

  <rect x="35" y="180" width="170" height="32" rx="6" fill="#0D1A0D" stroke="#555" stroke-width="1"/>
  <text x="120" y="200" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">MOTION_CHAR …cdef1</text>
  <text x="120" y="210" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">READ | NOTIFY (60 bytes)</text>

  <rect x="35" y="220" width="170" height="32" rx="6" fill="#0D1A0D" stroke="#555" stroke-width="1"/>
  <text x="120" y="240" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">REP_CHAR …cdef2</text>
  <text x="120" y="250" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">READ | NOTIFY (uint8)</text>

  <rect x="35" y="260" width="170" height="32" rx="6" fill="#0D1A0D" stroke="#555" stroke-width="1"/>
  <text x="120" y="280" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">VEL_CHAR …cdef3</text>
  <text x="120" y="290" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">READ | NOTIFY (float32)</text>

  <rect x="35" y="310" width="170" height="50" rx="6" fill="#0D1A0D" stroke="#555" stroke-width="1"/>
  <text x="120" y="330" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">ServerCallbacks</text>
  <text x="120" y="346" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">onConnect → deviceConnected</text>
  <text x="120" y="358" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">onDisconnect → restart adv</text>

  <rect x="35" y="372" width="170" height="36" rx="6" fill="#0D1A0D" stroke="#555" stroke-width="1"/>
  <text x="120" y="392" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Advertise "Smart Tracker"</text>
  <text x="120" y="404" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">MTU=185, Power=+9dBm</text>

  <rect x="35" y="420" width="170" height="36" rx="6" fill="#0D1A0D" stroke="#555" stroke-width="1"/>
  <text x="120" y="438" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">Notify @ 20ms intervals</text>
  <text x="120" y="450" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">motionChar.setValue + notify()</text>

  <!-- Flutter side column -->
  <rect x="540" y="50" width="200" height="450" rx="12" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="640" y="76" text-anchor="middle" fill="#6EA8FF" font-size="13" font-family="monospace" font-weight="bold">Flutter (Client)</text>

  <rect x="555" y="88" width="170" height="36" rx="8" fill="#0D0D1A" stroke="#6EA8FF" stroke-width="1"/>
  <text x="640" y="110" text-anchor="middle" fill="#6EA8FF" font-size="10" font-family="monospace">BleService (Singleton)</text>

  <rect x="555" y="134" width="170" height="32" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="152" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">_ensurePermissions()</text>
  <text x="640" y="162" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">Android BT + Location</text>

  <rect x="555" y="176" width="170" height="32" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="194" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">FlutterBluePlus.startScan(6s)</text>
  <text x="640" y="206" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">Filter: name OR service UUID</text>

  <rect x="555" y="218" width="170" height="32" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="236" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">device.connect(12s timeout)</text>
  <text x="640" y="248" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">Ignore already-connected err</text>

  <rect x="555" y="260" width="170" height="32" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="278" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">discoverServices()</text>
  <text x="640" y="290" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">Match service …cdef0</text>

  <rect x="555" y="302" width="170" height="32" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="320" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">setNotifyValue(true)</text>
  <text x="640" y="332" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">Subscribe …cdef1</text>

  <rect x="555" y="344" width="170" height="42" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="362" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">onValueReceived.listen()</text>
  <text x="640" y="378" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">MotionData.fromBytes(bytes)</text>
  <text x="640" y="388" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">→ _motionController.add()</text>

  <rect x="555" y="396" width="170" height="42" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="414" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">motionStream (broadcast)</text>
  <text x="640" y="430" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">→ WorkoutGameScreen</text>
  <text x="640" y="442" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">→ MotionLogScreen</text>

  <rect x="555" y="448" width="170" height="36" rx="6" fill="#0D0D1A" stroke="#555" stroke-width="1"/>
  <text x="640" y="466" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">connectionState (ValueNotifier)</text>
  <text x="640" y="478" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">disconnected/scanning/connected</text>

  <!-- Center channel -->
  <rect x="250" y="180" width="240" height="200" rx="12" fill="#0D0D0D" stroke="#333" stroke-width="1.5"/>
  <text x="370" y="202" text-anchor="middle" fill="#555" font-size="11" font-family="monospace">BLE 4.2 / 5.0</text>
  <text x="370" y="220" text-anchor="middle" fill="#333" font-size="10" font-family="monospace">Conn: 7.5–15ms interval</text>
  <text x="370" y="238" text-anchor="middle" fill="#333" font-size="10" font-family="monospace">Timeout: 2000ms</text>

  <!-- Data flow arrows -->
  <line x1="205" y1="196" x2="248" y2="252" stroke="#00FF88" stroke-width="2" marker-end="url(#ble)"/>
  <text x="208" y="240" fill="#00FF88" font-size="9" font-family="monospace">60B NOTIFY</text>
  <text x="208" y="252" fill="#666" font-size="8" font-family="monospace">50 Hz</text>

  <line x1="205" y1="236" x2="248" y2="282" stroke="#00FF88" stroke-width="1.5" marker-end="url(#ble)"/>
  <text x="208" y="276" fill="#888" font-size="8" font-family="monospace">REP NOTIFY</text>

  <line x1="205" y1="276" x2="248" y2="312" stroke="#00FF88" stroke-width="1.5" marker-end="url(#ble)"/>
  <text x="208" y="312" fill="#888" font-size="8" font-family="monospace">VEL NOTIFY</text>

  <line x1="490" y1="282" x2="553" y2="252" stroke="#6EA8FF" stroke-width="1.5" marker-end="url(#ble)"/>
  <text x="498" y="270" fill="#6EA8FF" font-size="8" font-family="monospace">PARSE</text>
</svg>

### 4.3 Workout Game Algorithm

<svg xmlns="http://www.w3.org/2000/svg" width="720" height="500" viewBox="0 0 720 500">
  <defs>
    <marker id="wg" markerWidth="10" markerHeight="7" refX="10" refY="3.5" orient="auto">
      <polygon points="0 0, 10 3.5, 0 7" fill="#FFD700"/>
    </marker>
  </defs>
  <rect width="720" height="500" fill="#0D0D0D" rx="16"/>
  <text x="360" y="32" text-anchor="middle" fill="#FFD700" font-size="15" font-family="monospace" font-weight="bold">WORKOUT GAME SCREEN — ALGORITHM PIPELINE</text>

  <!-- Start -->
  <rect x="280" y="52" width="160" height="42" rx="10" fill="#1A2E1A" stroke="#00FF88" stroke-width="2"/>
  <text x="360" y="77" text-anchor="middle" fill="#00FF88" font-size="12" font-family="monospace" font-weight="bold">Screen Open</text>

  <!-- Profile select -->
  <rect x="460" y="52" width="200" height="60" rx="8" fill="#111" stroke="#555" stroke-width="1"/>
  <text x="560" y="72" text-anchor="middle" fill="#888" font-size="10" font-family="monospace" font-weight="bold">Exercise Profiles</text>
  <text x="560" y="88" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Pull-Up / Squat / Bench</text>
  <text x="560" y="100" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Deadlift / Default</text>
  <line x1="440" y1="73" x2="462" y2="73" stroke="#555" stroke-width="1"/>

  <!-- BLE Subscribe -->
  <rect x="280" y="136" width="160" height="42" rx="10" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1.5"/>
  <text x="360" y="161" text-anchor="middle" fill="#6EA8FF" font-size="12" font-family="monospace" font-weight="bold">Subscribe BLE Stream</text>
  <line x1="360" y1="94" x2="360" y2="134" stroke="#FFD700" stroke-width="1.5" marker-end="url(#wg)"/>

  <!-- Calibration phase -->
  <rect x="240" y="222" width="240" height="60" rx="10" fill="#2E2A1A" stroke="#FFD700" stroke-width="2"/>
  <text x="360" y="246" text-anchor="middle" fill="#FFD700" font-size="12" font-family="monospace" font-weight="bold">Calibration Phase (2.5s)</text>
  <text x="360" y="264" text-anchor="middle" fill="#888" font-size="10" font-family="monospace">Collect min/max of posZ + accEnv</text>
  <text x="360" y="276" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">→ adjust zMin, zMax, accTarget, accRange</text>
  <line x1="360" y1="178" x2="360" y2="220" stroke="#FFD700" stroke-width="1.5" marker-end="url(#wg)"/>

  <!-- Motion data arrive -->
  <rect x="240" y="330" width="240" height="42" rx="10" fill="#2E1A1A" stroke="#FF8844" stroke-width="1.5"/>
  <text x="360" y="355" text-anchor="middle" fill="#FF8844" font-size="12" font-family="monospace" font-weight="bold">MotionData Arrives (50Hz)</text>
  <line x1="360" y1="282" x2="360" y2="328" stroke="#FFD700" stroke-width="1.5" marker-end="url(#wg)"/>

  <!-- Normalize posZ -->
  <rect x="30" y="416" width="180" height="60" rx="8" fill="#1A1A2E" stroke="#6EA8FF" stroke-width="1"/>
  <text x="120" y="440" text-anchor="middle" fill="#6EA8FF" font-size="10" font-family="monospace" font-weight="bold">Normalize posZ</text>
  <text x="120" y="458" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">(posZ − zMin) / (zMax − zMin)</text>
  <text x="120" y="470" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">→ progress 0.0–1.0</text>

  <!-- Calc accuracy -->
  <rect x="270" y="416" width="180" height="60" rx="8" fill="#2E1A1A" stroke="#FF8844" stroke-width="1"/>
  <text x="360" y="440" text-anchor="middle" fill="#FF8844" font-size="10" font-family="monospace" font-weight="bold">Calc Accuracy</text>
  <text x="360" y="458" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">(1 − |accEnv−target|/range)×100</text>
  <text x="360" y="470" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">S≥97% A≥92% B≥85% C&lt;85%</text>

  <!-- Update UI -->
  <rect x="510" y="416" width="180" height="60" rx="8" fill="#1A2E1A" stroke="#00FF88" stroke-width="1"/>
  <text x="600" y="440" text-anchor="middle" fill="#00FF88" font-size="10" font-family="monospace" font-weight="bold">setState() Update UI</text>
  <text x="600" y="458" text-anchor="middle" fill="#888" font-size="9" font-family="monospace">progress (lerp 0.25)</text>
  <text x="600" y="470" text-anchor="middle" fill="#666" font-size="8" font-family="monospace">reps, accuracy, grade, bonus</text>

  <!-- Arrows from motion data -->
  <line x1="290" y1="372" x2="120" y2="414" stroke="#FF8844" stroke-width="1.5" marker-end="url(#wg)"/>
  <line x1="360" y1="372" x2="360" y2="414" stroke="#FF8844" stroke-width="1.5" marker-end="url(#wg)"/>
  <line x1="430" y1="372" x2="600" y2="414" stroke="#FF8844" stroke-width="1.5" marker-end="url(#wg)"/>

  <!-- Sidebar: Track painter note -->
  <rect x="30" y="222" width="190" height="80" rx="8" fill="#111" stroke="#333" stroke-width="1"/>
  <text x="125" y="244" text-anchor="middle" fill="#888" font-size="10" font-family="monospace" font-weight="bold">_TrackPainter</text>
  <text x="125" y="262" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Cubic bezier path</text>
  <text x="125" y="278" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Dot at path.metric</text>
  <text x="125" y="294" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">position × progress</text>

  <!-- Sidebar: bonus note -->
  <rect x="510" y="222" width="190" height="80" rx="8" fill="#111" stroke="#333" stroke-width="1"/>
  <text x="605" y="244" text-anchor="middle" fill="#888" font-size="10" font-family="monospace" font-weight="bold">Bonus Logic</text>
  <text x="605" y="262" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">acc ≥ 95% → +5 pts</text>
  <text x="605" y="278" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">acc &lt; 95% → 0 pts</text>
  <text x="605" y="294" text-anchor="middle" fill="#666" font-size="9" font-family="monospace">Shown in _MetricChip</text>
</svg>

---

## 5. BLE Protocol Reference

### GATT Service

**Service UUID:** `12345678-1234-5678-1234-56789abcdef0`

| Char UUID | Name | Properties | Format | Notes |
|---|---|---|---|---|
| `…cdef1` | IMU Motion Data | READ, NOTIFY | 60B packed struct | 50 Hz stream |
| `…cdef2` | Rep Count | READ, NOTIFY | int32 LE | Only on change |
| `…cdef3` | Mean Velocity | READ, NOTIFY | float32 LE | 50 Hz |

### MotionPacket (60 bytes, little-endian)

```
Offset  Size  Type     Field
  0      4    uint32   ts_ms        — ESP32 millis() timestamp
  4      4    float32  ax           — linear accel X [m/s²] (gravity removed)
  8      4    float32  ay           — linear accel Y [m/s²]
 12      4    float32  az           — linear accel Z [m/s²]
 16      4    float32  gx           — gyro X [rad/s]
 20      4    float32  gy           — gyro Y [rad/s]
 24      4    float32  gz           — gyro Z [rad/s]
 28      4    float32  accEnv       — acceleration envelope EMA [m/s²]
 32      4    float32  velX         — integrated velocity X [m/s]
 36      4    float32  velY         — integrated velocity Y [m/s]
 40      4    float32  velZ         — integrated velocity Z [m/s]
 44      4    float32  posX         — integrated position X [m]
 48      4    float32  posY         — integrated position Y [m]
 52      4    float32  posZ         — integrated position Z [m]
 56      4    int32    motionCount  — cumulative rep counter
         Total = 60 bytes
```

### Connection Parameters

| Parameter | Value |
|---|---|
| Advertising name | `Smart Tracker` |
| MTU | 185 bytes |
| TX Power | +9 dBm |
| Conn interval | 7.5–15 ms |
| Conn timeout | 2000 ms |
| Scan timeout (app) | 6 s |
| Connect timeout (app) | 12 s |

---

## 6. Code Errors & Bugs Found

### CRITICAL

| # | File | Line | Issue | Fix |
|---|---|---|---|---|
| C1 | `IMU_path.ino` | 289 | **Division by zero** in `calibrateInitialOrientation()`: when the device is held with +Z pointing up, `az ≈ 1.0` → `s = sqrt((1−1.0)×2) = 0` → `ay/s = ∞` | Guard: `if (s < 1e-6) { qInit[0]=1; qInit[1]=qInit[2]=qInit[3]=0; return; }` |
| C2 | `README.md` | 5,31,47 | **Completely outdated**: says React Native (is Flutter), MPU6050/9250 (is QMI8658), PlatformIO (is Arduino IDE). Misleads new contributors | Rewrite README (see Section 8) |

### HIGH

| # | File | Line | Issue | Fix |
|---|---|---|---|---|
| H1 | `ble_service.dart` | 102 | `result.device.name` is **deprecated** in flutter_blue_plus ≥1.20. Returns empty string on some Android 13+ devices | Use `result.device.platformName` |
| H2 | `ble_service.dart` | 106 | UUID comparison may fail: `serviceUuid` is lowercase but advertised UUIDs from flutter_blue_plus may be uppercase or in different Guid format | Normalize: `uuids.any((u) => u.toLowerCase().contains('cdef0'))` |
| H3 | `connect_device_screen.dart` | 87 | `Image.asset('assets/logo.png')` — asset declared in pubspec but **`assets/` folder not found** in mobile directory. Will crash at runtime with `Unable to load asset` | Create `mobile/assets/` folder and add logo.png, OR use a placeholder Icon instead |
| H4 | `ble_service.dart` | 76 | `_connSub` (connection state listener) is **never cancelled** in `disconnect()`. Memory/listener leak on repeated connect/disconnect cycles | Add `await _connSub?.cancel(); _connSub = null;` in `disconnect()` |

### MEDIUM

| # | File | Line | Issue | Fix |
|---|---|---|---|---|
| M1 | `IMU_path.ino` | 324 | Comment says `// 100 Hz` but `filter.begin(500.0f)` sets **500 Hz**. Loop runs at ~500 Hz (2ms delay). Misleading comment | Fix comment to `// 500 Hz` |
| M2 | `IMU_path.ino` | 311 | `Serial.begin(115200)` always runs even when `ENABLE_SERIAL 0`. Minor flash/power waste | Wrap in `#if ENABLE_SERIAL` |
| M3 | `workout_game_screen.dart` | 202 | `calibPct` calculated in `build()` with `DateTime.now()` but the widget **only rebuilds on BLE data**. If no BLE device is connected, the calibration progress bar is frozen | Add a `Timer.periodic(100ms)` during calibration to force rebuild |
| M4 | `IMU_path.ino` | 396 | `fabs(sqrt(ax_e²+ay_e²+az_e²) − 9.81)` uses hardcoded `9.81` gravity instead of the calibrated `gInitZ` value, causing accEnv offset errors on non-standard gravity devices | Replace with `fabs(norm − sqrt(gInitX*gInitX+gInitY*gInitY+gInitZ*gInitZ))` |
| M5 | `ble_service.dart` | 87 | `_ensurePermissions()` only handles Android. On **iOS** no BLE permission is requested. `NSBluetoothAlwaysUsageDescription` must be in Info.plist (not present) | Add iOS permission key to `ios/Runner/Info.plist` |
| M6 | `home_screen.dart` | all | All stats (streak 57, steps 275,804, calories 124,580) are **hardcoded**. No persistence or real data source | Integrate shared_preferences or a backend |

### LOW

| # | File | Line | Issue | Fix |
|---|---|---|---|---|
| L1 | `IMU_path.ino` | 66–79 | Duplicate `onConnect`/`onDisconnect` with different signatures (single arg + two arg). Can cause **ambiguous override warnings** on some NimBLE versions | Keep only the 2-arg versions which are the current NimBLE standard |
| L2 | `motion_log_screen.dart` | 116–117 | `Text('z=...')` and `Text('env=...')` missing explicit `TextStyle` → inconsistent rendering | Add matching `TextStyle(color: ..., fontSize: ...)` |
| L3 | `main.dart` | 1 | `import 'dart:math'` unused outside of `min()` in builder — could use `MediaQueryData` clamp directly | Minor: leave as-is or remove |
| L4 | `IMU_path.ino` | all | No position **reset/zeroing** mechanism. After extended sessions `posX/Y/Z` accumulates floating-point drift unboundedly | Add a "reset position" BLE write characteristic |

---

## 7. Next Steps & Roadmap

### Phase 1 — Bug Fixes (Immediate)

- [ ] **Fix C1**: Add `s` division-by-zero guard in `calibrateInitialOrientation()`
- [ ] **Fix H1**: Replace `device.name` with `device.platformName` in BleService
- [ ] **Fix H2**: Normalize UUID comparison in `_scanForDevice()`
- [ ] **Fix H3**: Create `mobile/assets/` folder with logo, or use Icon fallback
- [ ] **Fix H4**: Cancel `_connSub` in `disconnect()`
- [ ] **Fix M3**: Add calibration timer for progress bar animation
- [ ] **Rewrite README.md** with correct tech stack

### Phase 2 — Feature Completion (Short-term)

- [ ] **Workout History**: Persist sets/reps/accuracy per workout session using `shared_preferences` or SQLite (`sqflite`)
- [ ] **Real Dashboard Data**: Connect streak counter, steps, calories to actual logged workouts
- [ ] **Position Reset Characteristic**: Add BLE write char (`cdef4`) to zero position on ESP32
- [ ] **Set Logic**: Implement set start/end detection + rest timer between sets
- [ ] **iOS Build**: Add `NSBluetoothAlwaysUsageDescription` + `NSLocationWhenInUseUsageDescription` to Info.plist, test on device
- [ ] **Exercise Detection**: Auto-detect exercise type from motion signature (ML or rule-based)

### Phase 3 — Backend / Server (Medium-term)

```
Planned Server Architecture:

  Flutter App
      │
      │ REST API / WebSocket
      ▼
  FastAPI / Node.js Server
      │
      ├── PostgreSQL (workout history, users, leaderboard)
      ├── Redis (leaderboard real-time, session cache)
      └── (optional) ML inference (exercise classification)
```

- [ ] **User accounts**: Auth (JWT), user profiles
- [ ] **Workout sync**: POST workout sessions from app to server
- [ ] **Real Leaderboard**: Server-side ranking by weekly calories/reps
- [ ] **Coach Alerts**: Server detects performance drops, pushes notification to app
- [ ] **OTA Firmware Update**: Server hosts firmware binaries, app triggers ESP32 OTA update via BLE

### Phase 4 — Hardware Improvements (Long-term)

- [ ] **Battery Level**: Read battery ADC on ESP32, expose via BLE `cdef5`
- [ ] **Haptic Feedback**: Vibration motor on rep count milestone
- [ ] **Heart Rate Sensor**: Add MAX30102 for HR monitoring
- [ ] **Cable Tension Sensor**: Load cell for resistance measurement
- [ ] **USB-C Charging IC**: Battery management (BQ24079 or similar)

---

## 8. Build & Deploy Guide

### Firmware (Arduino IDE)

**Required Libraries** (install via Arduino Library Manager):
- `NimBLE-Arduino` 2.3.7 (2.x callback signatures; `Gympath_Track` relies on them)
- `QMI8658` (custom or from vendor)
- `MahonyAHRS`
- `TFT_eSPI` (configure for your display in User_Setup.h)

**Board:** ESP32-S3 Dev Module  
**Upload Speed:** 921600  
**Flash Size:** 8MB (if using boot logo)

```bash
# Select Tools > Board > ESP32S3 Dev Module
# Select correct COM port
# Click Upload
```

**TFT_eSPI `User_Setup.h` key settings:**
```cpp
#define ST7789_DRIVER
#define TFT_WIDTH  240
#define TFT_HEIGHT 240
#define TFT_MOSI   11
#define TFT_SCLK   12
#define TFT_CS     10
#define TFT_DC      9
#define TFT_RST     8
#define SPI_FREQUENCY 40000000
```

### Mobile App (Flutter)

**Prerequisites:**
- Flutter SDK >= 3.0.0
- Android Studio / VS Code with Flutter extension
- Android SDK (API 36 target, API 21 minimum)
- Physical Android device recommended (BLE emulation unreliable)

```bash
cd mobile
flutter pub get

# Run on connected device
flutter run

# Build release APK
flutter build apk --release

# Build App Bundle (for Play Store)
flutter build appbundle --release
```

**Android Permissions** (already in `AndroidManifest.xml`):
```xml
<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation"/>
<uses-permission android:name="android.permission.BLUETOOTH_CONNECT"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADVERTISE"/>
<uses-permission android:name="android.permission.ACCESS_FINE_LOCATION"/>
```

**iOS Setup** (add to `ios/Runner/Info.plist`):
```xml
<key>NSBluetoothAlwaysUsageDescription</key>
<string>Gympath uses Bluetooth to connect to your Smart Tracker device.</string>
<key>NSLocationWhenInUseUsageDescription</key>
<string>Required for Bluetooth scanning on iOS.</string>
```

### Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| BLE scan finds nothing | Missing location permission | Grant `ACCESS_FINE_LOCATION` at runtime |
| App crashes on Connect screen | Missing `assets/logo.png` | Create `mobile/assets/` and add logo, or remove Image.asset call |
| Rep count jumps erratically | `goodTh` too low for exercise | Increase `goodTh` in firmware or exercise-specific profile |
| Position drifts to ±∞ | No position reset | Call position reset BLE write, or implement auto-reset on rest |
| `device.name` returns empty | Deprecated API on Android 13+ | Use `device.platformName` |
| Calibration bar frozen | No timer rebuild during calib | Add `Timer.periodic` in `initState` during calibration |

---

## Appendix: File Index

```
Gympath_project/
├── GYMPATH_DOCS.md              ← THIS FILE (full documentation)
├── README.md                    ← Project overview (OUTDATED — needs rewrite)
├── PROJECT_PLAN.md              ← AI-DLC implementation plan
├── firmware/
│   └── IMU_path/
│       ├── IMU_path.ino         ← ESP32 firmware (499 lines)
│       ├── logo200.h            ← 240×240 RGB565 boot logo array
│       └── logo generator.py    ← PNG→RGB565 conversion utility
├── mobile/
│   ├── pubspec.yaml             ← Flutter deps + assets declaration
│   ├── lib/
│   │   ├── main.dart            ← App entry point, routes, theme scale
│   │   ├── theme/app_theme.dart ← Dark + neon-green design tokens
│   │   ├── models/
│   │   │   └── motion_data.dart ← 60-byte BLE packet parser
│   │   ├── services/
│   │   │   └── ble_service.dart ← BLE singleton (scan/connect/subscribe)
│   │   ├── screens/
│   │   │   ├── splash_screen.dart
│   │   │   ├── connect_device_screen.dart
│   │   │   ├── home_screen.dart          ← 4-tab IndexedStack
│   │   │   ├── choose_workout_screen.dart
│   │   │   ├── workout_game_screen.dart  ← Live BLE game loop
│   │   │   ├── motion_log_screen.dart    ← Live chart
│   │   │   ├── gym_monitoring_screen.dart
│   │   │   ├── leaderboard_screen.dart
│   │   │   ├── meal_plan_screen.dart
│   │   │   └── active_workout_screen.dart
│   │   ├── widgets/
│   │   │   └── bottom_nav_bar.dart
│   │   └── utils/
│   │       └── responsive.dart  ← 360×800 base scale utility
│   └── DEPLOY.md
└── docs/
    ├── requirements.md
    ├── user_stories.md
    ├── ui_flow.md
    └── ble_protocol.md
```
