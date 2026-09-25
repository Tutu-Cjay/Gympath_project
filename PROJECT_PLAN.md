# Gympath — AI-DLC Project Plan

**Fitness Wearable Motion Tracking Device and Mobile Application**

---

## AI Agent History

| Phase | AI Agent | Role | Status |
|---|---|---|---|
| Inception → Construction B1–B6 | Claude Sonnet 4.6 (Claude Code) | Requirements, firmware, mobile app scaffold | ✅ Complete |
| Construction B7 → Operations | **Claude AI — Fable 5 (Latest Model)** | Bug fixes, polish, backend, deployment | 🟡 Active |

> **Agent Upgrade Note (2026-06-10):** Development AI agent upgraded from **Claude Sonnet 4.6** to **Claude AI Fable 5** (Claude's latest model) for remaining construction and operations phases. All prior work, decisions, and code context are preserved in this document.

---

## 1. Executive Summary

Gympath is a wearable fitness tracking system with two components:

- **Smart Tracker Device**: ESP32-S3 + QMI8658 IMU + 240×240 TFT display + NimBLE BLE. Worn during workouts to count reps, measure velocity, and stream 60-byte motion packets at 50 Hz.
- **Mobile App**: Flutter (Android/iOS) with real-time BLE visualization, rep game screen, monitoring, leaderboard, and meal plan.

**Current state (2026-06-10):** Firmware fully functional and tested. Mobile app UI complete with live BLE data. No backend server. 6 bugs identified — 2 critical, 4 high/medium.

---

## 2. Methodology: AI-Driven Development Lifecycle (AI-DLC)

Following the **Amazon AI-DLC framework**:
- Reference: [AI-DLC Paper](https://prod.d13rzhkk8cj2z0.amplifyapp.com/)
- Reference: [AWS AI-DLC Blog](https://aws.amazon.com/blogs/devops/ai-driven-development-life-cycle/)
- Reference: [AI-DLC Workflows (GitHub)](https://github.com/awslabs/aidlc-workflows)

### AI-DLC Principles Applied

| Principle | How Applied in Gympath |
|---|---|
| **Mob Elaboration** | AI generated requirements, user stories, BLE protocol spec → human approved |
| **Mob Construction** | AI wrote firmware + Flutter code in short "bolts" (1–3 day units) |
| **Human Checkpoints** | Human reviewed & approved BLE protocol, UI designs, motion accuracy |
| **Short Bolts** | Each feature = 1 bolt; no multi-week sprints |
| **AI creates, Human approves** | All architecture decisions reviewed before implementation |
| **Agent handoff** | Context captured in this doc for Kiro Fable 5 continuation |

---

## 3. Project History — All Phases

### Phase 0 — Inception (COMPLETED ✅)

**AI Agent:** Claude Sonnet 4.6  
**Duration:** ~2 days  
**Status:** All inception artifacts produced and approved

#### What was done:
- Defined project vision: wearable gym tracker for cable machine exercises
- Produced `docs/requirements.md` — device, connectivity, motion, UX, non-functional requirements
- Produced `docs/user_stories.md` — US1–US6 with acceptance criteria
- Produced `docs/ui_flow.md` — Mermaid screen flow diagram
- Produced `docs/ble_protocol.md` — GATT service UUID, 7 characteristics, data formats
- Produced `PROJECT_PLAN.md` (original) — architecture, bolts, testing strategy
- Collected UI reference images → `UI_image/` (4 images)

#### Key Decisions Made:
| Decision | Choice | Rationale |
|---|---|---|
| MCU | ESP32-S3 | BLE 5.0, sufficient RAM/Flash, widely available |
| IMU | QMI8658 | 6-axis, I²C, 1000 Hz ODR, compact |
| BLE Stack | NimBLE-Arduino | Lightweight, stable, supports ESP32 |
| AHRS | Mahony filter | Low CPU, stable, proven for wearables |
| Mobile Framework | Flutter | Single codebase iOS+Android, Dart type safety |
| BLE Library | flutter_blue_plus | Best maintained Flutter BLE lib |
| Theme | Dark + neon green #00FF88 | Gym/tech aesthetic |

#### Human Checkpoint 0 — Approved ✅
- Requirements reviewed and signed off
- BLE protocol UUID structure approved
- UI flow approved matching reference images

---

### Phase 1 — Construction B1: Project Setup (COMPLETED ✅)

**AI Agent:** Claude Sonnet 4.6  
**Duration:** 1 day  
**Bolt:** B1 — Project scaffolding, folder structure, documentation

#### What was built:
```
Gympath_project/
├── firmware/IMU_path/    ← Arduino sketch folder created
├── mobile/               ← Flutter project scaffolded
│   ├── lib/
│   │   ├── main.dart
│   │   ├── theme/
│   │   ├── models/
│   │   ├── services/
│   │   ├── screens/
│   │   ├── widgets/
│   │   └── utils/
│   └── pubspec.yaml      ← flutter_blue_plus + permission_handler
└── docs/                 ← All inception docs
```

#### Outcome:
- Flutter project compiles and runs empty shell
- Dark theme `AppTheme` defined with neon green palette
- Responsive utility `Responsive.w/h/sp/r()` implemented
- `pubspec.yaml` dependencies locked

---

### Phase 2 — Construction B2: Firmware IMU + Motion (COMPLETED ✅)

**AI Agent:** Claude Sonnet 4.6  
**Duration:** 2–3 days  
**Bolt:** B2 — ESP32 IMU driver, Mahony AHRS, motion processing, rep detection

#### What was built (`firmware/IMU_path/IMU_path.ino`):

**IMU Setup:**
- QMI8658 on I²C (SDA=6, SCL=7) at 1000 Hz ODR
- Accel range ±4g (m/s²), Gyro ±512 dps (converted to rad/s)
- Mahony AHRS filter initialized at 500 Hz

**Motion Pipeline:**
```
QMI8658 read → Mahony AHRS (quaternion) → rotateToEarth()
→ subtract gravity (gInitX/Y/Z) → LPF (α=0.70)
→ integrate velocity (damp=0.98) → integrate position (damp=0.995)
→ accEnv EMA (α=0.40) → beat-lock rep counter
```

**Rep Detection:**
- `accEnv > goodTh (1.0 m/s²)` → `motionCount++`, set `beatLock=true`
- `accEnv < 0.8` → release `beatLock`
- Rest: `accEnv < 0.2` for 10+ ticks → zero velocity

**Initial Calibration:**
- 400 samples at startup → compute initial quaternion `qInit` + gravity reference `gInitX/Y/Z`
- Removes mounting orientation bias

**Boot Logo:**
- Python script `logo generator.py` converts PNG → 240×240 RGB565 header `logo200.h`
- Displayed at startup with 5-second hold

#### Known Issues Introduced (to fix in B7):
- ⚠️ **C1**: Division by zero in `calibrateInitialOrientation()` when device faces straight up (az≈1.0)
- ⚠️ **M1**: Filter comment says "100 Hz" but runs at 500 Hz
- ⚠️ **M4**: accEnv uses hardcoded `9.81` instead of calibrated gravity magnitude

---

### Phase 3 — Construction B3: Firmware BLE GATT (COMPLETED ✅)

**AI Agent:** Claude Sonnet 4.6  
**Duration:** 1–2 days  
**Bolt:** B3 — NimBLE GATT server, characteristics, advertising, callbacks

#### What was built:

**GATT Service:** `12345678-1234-5678-1234-56789abcdef0`

| Characteristic | UUID | Properties | Bytes | Content |
|---|---|---|---|---|
| Motion Data | `…cdef1` | READ, NOTIFY | 60 | Full MotionPacket struct |
| Rep Count | `…cdef2` | READ, NOTIFY | 4 | int32 motionCount |
| Mean Velocity | `…cdef3` | READ, NOTIFY | 4 | float32 meanVelocity |

**BLE Config:**
- MTU: 185 bytes
- TX Power: +9 dBm
- Advertising name: `"Smart Tracker"`
- Auto-restart advertising on disconnect

**MotionPacket (60 bytes, little-endian packed struct):**
```
[0]  uint32  ts_ms
[4]  float32 ax, ay, az      (linear accel, gravity removed)
[16] float32 gx, gy, gz      (gyro rad/s)
[28] float32 accEnv           (envelope EMA)
[32] float32 velX, velY, velZ
[44] float32 posX, posY, posZ
[56] int32   motionCount
```

**Notify schedule:**
- Motion + velocity: every 20ms (50 Hz)
- Rep count: only on change

#### Human Checkpoint 1 — Approved ✅
- Physical device tested with nRF Connect app
- BLE notify confirmed at 50 Hz
- Rep count increment verified on physical motion

---

### Phase 4 — Construction B4: TFT Display (COMPLETED ✅)

**AI Agent:** Claude Sonnet 4.6  
**Duration:** 1 day  
**Bolt:** B4 (firmware side) — 7-segment display on TFT

#### What was built:

**7-Segment Display:**
- Custom `draw7SegDigit()` and `draw7SegNumber()` at scale=6
- Centered on 240×240 round display (cx=120, cy=120)
- Smooth animation attempted via `draw7SegSmooth()` (currently commented out for stability)

**Dynamic Color Ring:**
- Color maps accEnv → Blue (rest) → Green (good) → Red (fast)
- Ring drawn each loop: `for r=105 to 120: drawSmoothCircle()`
- Clears center only on rep count change (efficient redraw)

**Boot sequence:**
- Fill screen black → draw color ring → draw logo → hold 5s → calibrate → clear → loop

---

### Phase 5 — Construction B5: Mobile BLE + Core Screens (COMPLETED ✅)

**AI Agent:** Claude Sonnet 4.6  
**Duration:** 2–3 days  
**Bolt:** B5 — Flutter BLE service, MotionData model, Connect screen, Workout Game screen

#### What was built:

**`BleService` (singleton):**
- Permission handling (Android: SCAN, CONNECT, ADVERTISE, LOCATION)
- Scan with 6s timeout, filter by name `"smart tracker"` or service UUID
- Connect with 12s timeout
- GATT discovery → subscribe to `cdef1` notify
- `MotionData` stream (broadcast `StreamController`)
- `ValueNotifier<BleConnectionState>` for UI binding

**`MotionData.fromBytes()` parser:**
- 60-byte validation
- Little-endian `ByteData` parsing of all 15 fields
- Returns `null` on bad packet length

**Screens built:**
- `SplashScreen` — 2s logo + auto-navigate to `/connect`
- `ConnectDeviceScreen` — BLE scan UI, status indicator, Connect/Skip buttons
- `WorkoutGameScreen` — live BLE loop, calibration phase (2.5s), progress track painter, accuracy scoring

**WorkoutGameScreen algorithm:**
```
profileForWorkout(name) → ExerciseProfile (zMin/zMax/accTarget/accRange/repsPerLoop)
2.5s calibration → adjust thresholds from observed data
_onMotion(data):
  normalized = (posZ − zMin) / (zMax − zMin)
  target = (repIndex + normalized) / repsPerLoop
  progress = lerp(progress, target, 0.25)   ← smooth animation
  accuracy = (1 − |accEnv − accTarget| / accRange) × 100%
  grade = S/A/B/C based on accuracy
  bonus = acc ≥ 95% ? 5 : 0
```

**Exercise Profiles:**
| Exercise | zMin | zMax | accTarget | repsPerLoop |
|---|---|---|---|---|
| Pull-Up | -0.35 | 0.35 | 1.0 | 4 |
| Squat | -0.50 | 0.50 | 1.2 | 4 |
| Bench Press | -0.25 | 0.25 | 0.9 | 3 |
| Deadlift | -0.45 | 0.45 | 1.1 | 4 |
| Default | -0.40 | 0.40 | 1.0 | 4 |

#### Known Issues Introduced (to fix in B7):
- ⚠️ **H1**: `device.name` deprecated in flutter_blue_plus ≥1.20 → use `platformName`
- ⚠️ **H2**: UUID comparison case-sensitivity bug in `_scanForDevice()`
- ⚠️ **H4**: `_connSub` not cancelled in `disconnect()` → listener leak
- ⚠️ **M3**: Calibration progress bar frozen if no BLE data (no timer rebuild)

---

### Phase 6 — Construction B6: Mobile Full UI (COMPLETED ✅)

**AI Agent:** Claude Sonnet 4.6  
**Duration:** 2–3 days  
**Bolt:** B6 — All remaining screens, navigation, home dashboard, coach tab

#### What was built:

**`HomeScreen` (4-tab IndexedStack):**
- Tab 1 `_HomeTab`: Day 57 counter, daily indicators (mood/heart/speed/size), streak card (57), today's workout (57/69), Add Workout button, monthly stats (steps/calories)
- Tab 2 `_WorkoutsTab`: renders `ChooseWorkoutScreen` inline
- Tab 3 `_NutritionTab`: renders `MealPlanScreen` inline
- Tab 4 `_CoachTab`: TabController with Monitoring + Leaderboard sub-tabs

**`ChooseWorkoutScreen`:** Search bar + 6 workout cards → navigate to `WorkoutGameScreen`

**`MotionLogScreen`:** Live chart (CustomPainter) of posZ + accEnv, 200-point ring buffer, latest readings list

**`GymMonitoringScreen`:** User profile card, 7-month bar chart, weekly challenge (5/7), alerts list (Bench Press / Running / Squats)

**`LeaderboardScreen`:** Activity feed, rankings (Sasha 60 / You 57 / Sarah 45), summary stats

**`MealPlanScreen`:** Personalized meal plan, breakfast card, grocery list

**`BottomNavBar`:** 4 tabs — Home, Workouts, Nutrition, Coach

**Route map (MaterialApp.routes):**
```
/splash  → SplashScreen
/connect → ConnectDeviceScreen
/home    → HomeScreen
```

#### Known Issues (data is static — to fix in B7+):
- ⚠️ **M6**: All dashboard stats hardcoded (streak 57, steps, calories). Needs persistence.

---

### Phase 7 — Construction B7: Integration, Fixes & Polish (🟡 IN PROGRESS)

**AI Agent:** Claude AI — Fable 5 (Latest Model)  
**Started:** 2026-06-10  
**Status:** Active — bugs identified, fixes pending

#### Open Bug Backlog (priority order):

| ID | Severity | File | Issue | Status |
|---|---|---|---|---|
| C1 | 🔴 Critical | `IMU_path.ino` | Division by zero in `calibrateInitialOrientation()` when az≈1.0 | ✅ Fixed in B8 (2026-06-10) |
| H1 | 🟠 High | `ble_service.dart` | `device.name` deprecated → use `platformName` | ✅ Fixed in B9 (2026-06-12) |
| H2 | 🟠 High | `ble_service.dart` | UUID case mismatch in scan filter | ✅ Fixed in B9 (2026-06-12) |
| H3 | 🟠 High | `connect_device_screen.dart` | `assets/logo.png` missing from filesystem | ✅ Resolved — asset present + in pubspec |
| H4 | 🟠 High | `ble_service.dart` | `_connSub` listener leak in `disconnect()` | ✅ Fixed in B9 (2026-06-12) |
| M1 | 🟡 Medium | `IMU_path.ino` | Comment "100 Hz" should be "500 Hz" | ✅ Fixed in B8 (2026-06-10) |
| M3 | 🟡 Medium | `workout_game_screen.dart` | Calibration progress bar frozen without BLE | ✅ Fixed in B9 (2026-06-12) — Timer.periodic drives bar |
| M4 | 🟡 Medium | `IMU_path.ino` | Hardcoded 9.81 vs calibrated gravity | ✅ Fixed in B8 (2026-06-10) |
| M5 | 🟡 Medium | iOS `Info.plist` | Missing Bluetooth permission keys | ➖ N/A — no iOS project yet (Android-only) |
| M6 | 🟡 Medium | `home_screen.dart` | All stats hardcoded, no persistence | ✅ Fixed in B9 (2026-06-12) — local `WorkoutStore` |

#### B7 Tasks:

**Sub-bolt B7a — Critical Bug Fixes:**
- [ ] Fix C1: guard `s < 1e-6` in calibration
- [ ] Fix H1: `device.platformName`
- [ ] Fix H2: UUID lowercase normalize
- [ ] Fix H3: Create `mobile/assets/` + add logo
- [ ] Fix H4: cancel `_connSub` in disconnect

**Sub-bolt B7b — Feature Completion:**
- [ ] Workout persistence with `shared_preferences` (sets, reps, streak)
- [ ] Connect live data to dashboard (streak from stored sessions)
- [ ] iOS BLE permissions (Info.plist)
- [ ] Position reset BLE characteristic (`cdef4`)
- [ ] Calibration progress bar `Timer.periodic`

**Sub-bolt B7c — Polish & Testing:**
- [ ] E2E test: US1 (pair), US2 (workout), US3 (live data)
- [ ] Physical device rep accuracy test (target >95%)
- [ ] APK build + install test on Android 13+
- [ ] iOS simulator smoke test

#### Human Checkpoint 2 (B7 gate):
- [ ] Verify rep accuracy ≥95% on 3 exercise types
- [ ] Verify BLE scan finds device within 10s on Android 12+
- [ ] UI review: all screens render without overflow on 360×800

---

## 4. Upcoming Phases

### Phase 8 — Bolt B8: IMU 3D Pose & Origin Estimation (🟡 IMPLEMENTED — pending physical test)

**AI Agent:** Claude AI — Fable 5 (Latest Model)  
**Implemented:** 2026-06-10 (firmware + mobile code complete; physical-device tests B8-T1..T3 pending)  
**Scope:** Firmware algorithm upgrade + mobile parser/UI update. **No new hardware.**  
**Backup:** Pre-B8 firmware preserved at `firmware_backup_2026-06-10/`

#### Problem Statement (why current approach needs upgrading)

| Problem | Current State | Target State |
|---|---|---|
| Position drifts to ±∞ | Only velocity zeroed on `accEnv < 0.2` for 10 ticks | **ZUPT** zeros velocity hard; origin converges to true rest point |
| Rep detection is fragile | `accEnv > goodTh (1.0)` beat-lock on accel magnitude | **3D displacement from origin** — rep counted when device leaves and returns |
| Rest detection weak | Only checks `accEnv` (acceleration) | Checks **both** accel deviation from gravity AND gyro magnitude |
| No spatial awareness | Only `posZ` used for tracking | Full **dx, dy, dz** displacement vector + `dispMag` magnitude |
| No pose output to app | Quaternion computed but never sent | **Roll, Pitch, Yaw** (Euler ZYX, degrees) in BLE packet |
| accEnv uses hardcoded 9.81 | `fabs(norm − 9.81)` | Uses calibrated `gravityMag` from startup averaging |

---

#### Algorithm Design

**Step 1 — ZUPT (Zero Velocity Update)**
```
Every loop tick:
  accelMag = |earth-frame accel vector|          ← magnitude, should be ~gravityMag at rest
  gyroMag  = |gyro vector| [rad/s]               ← should be ~0 at rest

  stationary = (|accelMag − gravityMag| < 0.15 m/s²)
             AND (gyroMag < 0.08 rad/s)

  if stationary for 25+ consecutive ticks:
    zuptActive = true
    velX = velY = velZ = 0          ← hard velocity reset (no drift accumulation)
  else:
    zuptActive = false
```

**Step 2 — Origin Estimation**
```
  if zuptActive for 60+ ticks:       ← settled long enough
    if first time:
      origin = currentPos            ← seed origin
    else:
      origin = 0.97×origin + 0.03×currentPos   ← slow convergence to rest point

  Origin represents: the neutral/start position of the exercise
  Updates adaptively: if user moves to new setup position and holds still → origin updates
```

**Step 3 — 3D Displacement from Origin**
```
  dx = posX − originX
  dy = posY − originY
  dz = posZ − originZ
  dispMag = sqrt(dx² + dy² + dz²)   ← scalar distance from origin in metres
```

**Step 4 — Displacement-Based Rep Detection**
```
  repPhase = REST | ACTIVE

  REST → ACTIVE:   dispMag > 0.04m  (device moved 4cm from origin)
  while ACTIVE:    track repPeakDisp = max(repPeakDisp, dispMag)
  ACTIVE → REST:   dispMag < 0.025m AND repPeakDisp > 0.06m
                   → motionCount++, reset repPeakDisp

  This counts one rep as: leave origin → move → return to origin
  Works for any exercise axis (vertical, horizontal, diagonal)
```

**Step 5 — Euler Angle Extraction**
```
  From Mahony quaternion (q0, q1, q2, q3):
    roll  = atan2(2(q0q1 + q2q3),  1 − 2(q1² + q2²))  × RAD_TO_DEG
    pitch = asin (2(q0q2 − q3q1))                       × RAD_TO_DEG
    yaw   = atan2(2(q0q3 + q1q2),  1 − 2(q2² + q3²))  × RAD_TO_DEG

  Sent to app → can show device tilt, rotation, and orientation during exercise
```

---

#### MotionPacket v2 — Extended to 104 Bytes

```
Offset  Bytes  Field        Description
─────────────────────────────────────────────────────────────
 ── v1 fields (unchanged, 60 bytes) ──
  0      4    ts_ms         ESP32 millis() timestamp
  4     12    ax, ay, az    linear accel [m/s²] (gravity removed)
 16     12    gx, gy, gz    gyro [rad/s]
 28      4    accEnv        accel envelope EMA (legacy, kept)
 32     12    velX/Y/Z      integrated velocity [m/s]
 44     12    posX/Y/Z      integrated position [m]
 56      4    motionCount   cumulative rep count (int32)
 ── v2 new fields (44 bytes) ──
 60     12    roll, pitch, yaw       Euler angles ZYX [degrees]
 72     12    originX, originY, originZ  ZUPT-estimated origin [m]
 84     12    dx, dy, dz             displacement from origin [m]
 96      4    dispMag                3D displacement magnitude [m]
100      1    repPhase               0=REST, 1=ACTIVE
101      1    zuptActive             1 while ZUPT firing
102      2    _pad                   alignment padding
─────────────────────────────────────────────────────────────
Total: 104 bytes   (fits in MTU 185 bytes ✅)
```

**Backwards compatibility:** App checks `bytes.length >= 104` for v2 fields.
Old app receiving 104 bytes ignores extra 44 bytes (v1 parsing still valid at offset 0–59).

---

#### Mobile App Changes Required

| File | Change |
|---|---|
| `motion_data.dart` | Add v2 fields: roll, pitch, yaw, originX/Y/Z, dx/dy/dz, dispMag, repPhase, zuptActive. Parse if `bytes.length >= 104` |
| `workout_game_screen.dart` | Use `dispMag` + `repPhase` for progress instead of raw `posZ` + `accEnv` |
| `workout_game_screen.dart` | Show `roll/pitch/yaw` as pose indicator widget |
| `motion_log_screen.dart` | Add `dispMag` and `roll` graph lines alongside `posZ` |

---

#### Fitness Tracking Improvements Unlocked

| Exercise | Old tracking | New tracking |
|---|---|---|
| Pull-Up | posZ axis only | dy (vertical) displacement, pitch angle change |
| Squat | posZ axis only | dy (vertical) + pitch, detects depth |
| Bench Press | posZ axis only | dz (horizontal push) + roll stability |
| Deadlift | posZ axis only | dy (vertical lift) + pitch throughout lift |
| Cable Machine | posZ axis only | Full dx/dy/dz path along cable direction |
| Any exercise | beat-lock on vibration | True spatial rep: leave origin → return |

---

#### Algorithm Refinements Applied During Implementation (Fable 5 review)

The original B8 design was reviewed against the actual firmware before implementation.
Six refinements were made — all motivated by a key code finding: **the TFT was redrawn
every loop iteration (16 anti-aliased circles + 7-seg digits), making the real loop rate
unstable and far below the 500 Hz the Mahony filter assumes.**

| # | Refinement | Why |
|---|---|---|
| 1 | All stillness windows are **time-based (ms)**, not sample counts | Loop rate is not constant; "25 samples" had no fixed meaning |
| 2 | **Display throttled to 50ms (20 Hz)** | Frees the loop to run near the 500 Hz Mahony assumption; better orientation + integration |
| 3 | Rep state machine gets **timeout (8s) + origin re-anchor** | Pure displacement detection can get stuck ACTIVE forever if drift escapes the end threshold |
| 4 | **Adaptive end threshold** = max(3cm, 35% × rep peak) | A 50cm squat shouldn't require returning within 2.5cm of origin |
| 5 | False-positive guards: **min rep duration 300ms, refractory 250ms, min peak 8cm** | Rejects vibration spikes and double counts |
| 6 | **Time-based velocity damping** `exp(−1.2·dt)`; `posDamp`-to-absolute-zero removed | Per-tick damping changes meaning when loop rate changes; pulling position to absolute 0 conflicts with the origin concept |
| 7 | `asin` input clamped to ±1 in pitch extraction | Avoids NaN at gimbal lock |
| 8 | `meanVelocity` now full 3D speed magnitude (was \|velZ\| only) | Consistent with 3D displacement tracking |

> **Note:** Yaw from a 6-axis IMU (no magnetometer) is *relative* and drifts slowly.
> Roll/pitch are absolute (gravity-referenced). Documented in packet comments.

#### Tuning Parameters (firmware constants — as implemented)

| Constant | Default | Description |
|---|---|---|
| `ZUPT_ACC_TH` | 0.18 m/s² | Accel deviation from `gravityMag` for stationary |
| `ZUPT_GYRO_TH` | 0.10 rad/s | Gyro magnitude for stationary |
| `ZUPT_TIME_MS` | 150 ms | Sustained stillness before velocity hard-reset |
| `ORIGIN_SETTLE_MS` | 400 ms | Stillness before origin starts adapting |
| `ORIGIN_TAU` | 1.5 s | Origin convergence time constant (rate-independent) |
| `VEL_DAMP_LAMBDA` | 1.2 /s | Time-based velocity decay rate |
| `REP_START_TH` | 0.05 m | Displacement from origin to start a rep (5cm) |
| `REP_END_TH` | 0.03 m | Absolute return threshold (3cm) |
| `REP_END_PEAK_FRAC` | 0.35 | Adaptive end: below 35% of rep peak |
| `REP_MIN_PEAK` | 0.08 m | Minimum peak displacement to count rep (8cm) |
| `REP_MIN_DURATION_MS` | 300 ms | Reject vibration spikes |
| `REP_TIMEOUT_MS` | 8000 ms | Stuck-ACTIVE recovery → re-anchor origin, no count |
| `REP_REFRACTORY_MS` | 250 ms | Minimum gap between counted reps |
| `DISPLAY_INTERVAL_MS` | 50 ms | TFT redraw throttle (20 Hz) |

---

#### Implementation Order

- [x] **B8-F1** Firmware: fix `calibrateInitialOrientation()` division-by-zero (C1 bug) + compute `gravityMag` ✅ 2026-06-10
- [x] **B8-F2** Firmware: add ZUPT logic (accel + gyro dual-threshold, time-based) ✅ 2026-06-10
- [x] **B8-F3** Firmware: add origin estimation (ZUPT-gated, τ=1.5s low-pass) ✅ 2026-06-10
- [x] **B8-F4** Firmware: add 3D displacement + displacement-based rep state machine ✅ 2026-06-10
- [x] **B8-F5** Firmware: add Euler angle extraction from quaternion (asin clamped) ✅ 2026-06-10
- [x] **B8-F6** Firmware: extend `MotionPacket` struct to v2 (104 bytes), fill all fields ✅ 2026-06-10
- [x] **B8-F7** Firmware: throttle TFT redraw to 50ms (added during review) ✅ 2026-06-10
- [x] **B8-M1** Mobile: extend `MotionData` model with v2 fields + conditional parser ✅ 2026-06-10
- [x] **B8-M2** Mobile: `WorkoutGameScreen` uses `dispMag` + `repPhase` (v1 posZ fallback) + pose row ✅ 2026-06-10
- [x] **B8-M3** Mobile: `MotionLogScreen` plots dispMag + roll, shows pose/phase/ZUPT ✅ 2026-06-10
- [x] **B8-D1** Debug: firmware `DEBUG_STREAM` serial CSV @50Hz (pos/origin/vel/accel/euler/phase/ZUPT + boot CALIB metadata) ✅ 2026-06-10
- [x] **B8-D2** Debug: `tools/imu_debug_viewer.py` — realtime 3D viewer (pyqtgraph/OpenGL), RGB triads (world frame / ZUPT origin / device pose), CSV logger, replay mode ✅ 2026-06-10
- [x] **B8-F8** Firmware: FreeRTOS dual-core split — TFT rendering on core 0 (`displayTask`), IMU/BLE loop on core 1; debug logs showed display was starving the loop to ~4.5 Hz ✅ 2026-06-10
- [x] **B8-F9** Firmware: gravity-subtraction fix — `gInit` is now `(0,0,gravityMag)` in the Mahony earth frame (qInit-rotated reference caused constant ax/ay bias → position drift at rest); Mahony seeded with `qInit` at boot; ZUPT check moved before integration so position is frozen at rest ✅ 2026-06-10
- [x] **B8-F10** Firmware: rotation fix — replaced MahonyAHRS library with embedded **dt-aware Mahony** (`mahonyUpdateIMU`); the library's fixed-500Hz assumption over/under-rotated the attitude whenever loop rate differed, corrupting gravity subtraction during rotation. Added **accel gate** (`ACC_GATE_FRAC=0.15` — skip tilt correction when |a| deviates >15% from gravity, i.e. centripetal forces present) and **rotation-adaptive velocity damping** (`GYRO_DAMP_GAIN=2.0`); dt clamped to 50ms ✅ 2026-06-11
- [x] **B8-F11** Firmware: raw body-frame accel (`rax,ray,raz`) appended to debug CSV stream (24 columns) for rotation analysis ✅ 2026-06-11
- [x] **B8-D3** Debug: `tools/imu_rotation_test.py` + `run_rotation_test.bat` — guided test (still → roll → pitch → yaw → translate → still) with Mongolian on-screen instructions, per-segment drift/excursion/gravity-residual analysis, PASS/FAIL report saved to `logs/rotation_test_*_report.txt`; viewer parses both legacy 21-col and new 24-col logs ✅ 2026-06-11
- [x] **B8-F12** Firmware: **gyro bias calibration** — rotation-test run `rotation_test_20260611_221340` proved the root cause: a truly still device (euler range 1–2°, raw-accel dev 0.02 m/s²) had ZUPT only 39% active and a persistent 0.55 m/s² fake linear accel — uncalibrated QMI8658 gyro bias kept gyroMag above the ZUPT threshold and tilted Mahony's equilibrium off gravity. Fixes: bias averaged over the 400-sample boot window, refined online while ZUPT confirms stillness (τ=10 s), Mahony Kp ×4 while still (fast post-rotation recovery), velocity integration frozen above 3 rad/s rotation, `GYRO_DAMP_GAIN` 2→3, gyroBias added to `# CALIB` metadata. Test tool: first 1.5 s of each segment discarded (hand repositioning), translation verdict also requires return-to-start. **Verified** by run `222157`: still 0.1–0.3 cm PASS (was 15–30 cm), yaw 5 cm PASS (was 261 cm) ✅ 2026-06-11
- [x] **B8-F13** Firmware: raw gyro (`rgx,rgy,rgz`) added to debug stream (27 cols); I2C 100→400 kHz; debug baud 921600; test tool gained **gyro↔euler cross-check** (integrated travel + axis correlation). Run `233825` **proved attitude tracking is correct** (gyro 700° vs euler 686°, corr gx→r +0.98; yaw sign inversion is geometric — device mounted roll≈180°). Remaining roll/pitch drift identified as **real hand-arc centripetal accel** (ω²r ≈ 3.5 m/s² matches measured 3.56) + integration error at swing reversals where instantaneous ω≈0 escapes the freeze gate ✅ 2026-06-11
- [x] **B8-F14** Firmware: **gyro envelope freeze** — `gyroEnv` (peak-hold, τ=0.4 s decay) replaces instantaneous gyro magnitude in the velocity-freeze gate (`GYRO_FREEZE_TH`=2.0 rad/s on the envelope) so whole rotation episodes including reversals keep velocity frozen ⬜ pending re-test on device
- [x] **B8-D4** Debug: guided rotation test integrated into the viewer GUI — "▶ Guided test" button, large countdown/recording instruction banner, live 3D + charts visible during the test, report dialog at the end (analyzes the full session log, not the chart ring buffer) ✅ 2026-06-11
- [ ] **B8-T1** Test: verify rep count on 3 exercises with physical device
- [ ] **B8-T2** Test: verify ZUPT fires within ~200ms of device going still
- [ ] **B8-T3** Test: verify origin updates when device moved to new rest position
- [ ] **B8-T4** Test: compile firmware in Arduino IDE (no arduino-cli on dev machine)

#### Human Checkpoint B8:
- [ ] Rep accuracy ≥ 95% across pull-up, squat, bench press
- [ ] Position no longer drifts during 5-min continuous use
- [ ] Roll/pitch/yaw visible in app motion log

---

### Phase 8.5 — Bolt B9: Mobile Frontend Polish + Bug Fixes (✅ COMPLETE)

**AI Agent:** Claude AI — Fable 5 (Latest Model)
**Completed:** 2026-06-12
**Scope:** Fix all open B7 mobile bugs, wire dashboard to real data with local persistence, visual polish. Built clean as `app-debug.apk`.

**Bug fixes:** H1 (`platformName`), H2 (case-insensitive UUID match), H4 (`_connSub` cancelled in `disconnect()`), M3 (calibration bar driven by `Timer.periodic`, completes without BLE), plus removed dead `ActiveWorkoutScreen`, fixed unreachable switch default, removed unnecessary import.

**On-device fixes (2026-06-13):**
- `ConnectDeviceScreen` RenderFlex bottom overflow (14 px + 5.4 px on device A059) — `Spacer()` Column didn't fit short screens → wrapped in `LayoutBuilder + SingleChildScrollView + ConstrainedBox(minHeight) + IntrinsicHeight`.
- `GymMonitoringScreen` performance-chart bottom overflow — fragile `maxHeight - 32` bar math → bars now `Expanded + FractionallySizedBox` (proportional, can't overflow).
- "setState() called during build" on entering Workout/MotionLog — `_ble.connect()` in `initState` synchronously flipped `connectionState`, rebuilding the home `BleStatusChip` mid-build → deferred connect to `addPostFrameCallback`.

**🔴 BLE no-data root cause + firmware fix (2026-06-13):** app connected (GATT OK, MTU 185, CCCD notify enabled GATT_SUCCESS) but received **0 motion packets**; a diagnostic read of cdef1 returned **0 bytes**. Root cause: firmware gated `setValue/notify` on `deviceConnected`, set only by `onConnect` — but newer **NimBLE-Arduino doesn't call the old `onConnect(NimBLEServer*[, ble_gap_conn_desc*])` signatures**, so the flag stayed false and the characteristic was never written. Fix (applied to **both** `firmware/IMU_path` and `firmware_backup_2026-06-10/IMU_path`): gate notify on `bleServer->getConnectedCount() > 0` (callback-independent) + re-advertise on the connected→0 transition. **Requires re-flash.**

**BLE connection hardening (2026-06-13, docs-driven — US1 + C4):** reconciled `docs/ble_protocol.md` with the real firmware (60-byte cdef1, int32 cdef2, float32 cdef3; cdef4–7 marked planned). `BleService` gained **auto-reconnect** (5 attempts, 2s×n backoff, skipped on user-initiated disconnect), **MTU 247 request**, a `lastError` notifier, and try/catch around all BLE calls. `ConnectDeviceScreen` shows the error + a **Retry** SnackBar/button (US1). `WorkoutGameScreen` AppBar shows a live `BleStatusChip` (US1 "status visible during workout"). Clean `flutter analyze`, installed on device A059.

**Local persistence (M6):**
- `models/workout_session.dart` — `WorkoutSession` (workoutName, reps, accuracy, performance, bonus, durationSec, timestamp); maps 1:1 to a future backend row
- `services/workout_store.dart` — `WorkoutStore` singleton over `shared_preferences`; `ValueNotifier<WorkoutStats>` (dayNumber, streakDays, todayReps, totalSessions, totalReps, points, weekSessions, avgAccuracy). Loaded in `main()` before `runApp`
- `WorkoutGameScreen` Finish → saves session + shows summary dialog
- Dashboard (`_HomeTab`), Leaderboard "You" entry, summary stats now driven by real stored data (no more hardcoded 57s)

**Visual polish:**
- `widgets/ble_status_chip.dart` — live BLE link pill on home (tap to connect), spinner while scanning/connecting
- Today's-reps progress ring on dashboard, empty-state hint for new users
- All 26 `withOpacity()` → `withValues(alpha:)` (Flutter 3.27+ API)

> **Note:** local store is the offline cache + sync source for the Phase 9 backend — not throwaway. Backend will POST/sync this same session list.

---

### Phase 9 — Operations: Backend Server (🟡 IN PROGRESS — core server done)

**AI Agent:** Claude AI — Fable 5 (Latest Model)
**Started:** 2026-06-12
**Decision:** FastAPI + **SQLite (WAL)** via SQLAlchemy ORM, not Postgres — sized for the
user's goal of a ~50-user test server on their own PC. ORM keeps a Postgres swap to a
one-line `GYMPATH_DATABASE_URL` change. JWT (HS256) + bcrypt, email/password auth.

**Built (`backend/`):**
```
backend/
├── app/
│   ├── main.py          ← FastAPI app, CORS, /health, /, routers
│   ├── config.py        ← persisted JWT secret, DB url, token expiry
│   ├── database.py      ← SQLAlchemy engine, SQLite WAL pragmas
│   ├── models.py        ← User, WorkoutSession, Device (unified schema)
│   ├── schemas.py       ← pydantic request/response
│   ├── auth.py          ← bcrypt hash, JWT issue/verify, get_current_user
│   ├── services.py      ← stats + leaderboard aggregation (mirrors app)
│   └── routers/         ← auth, sessions, stats
├── seed.py              ← demo users + sessions
├── test_api.py          ← end-to-end TestClient suite (all pass ✅)
├── run_server.bat       ← double-click launch (binds 0.0.0.0:8000)
└── README.md
```

**Endpoints:** `/auth/register|login|me`, `/sessions` (+`/bulk`, list), `/stats`,
`/leaderboard`, `/health`. Interactive docs at `/docs`.
`workout_sessions` columns mirror the mobile `WorkoutSession` 1:1 → app's local
`WorkoutStore` syncs straight in via `/sessions/bulk`.

**Verified 2026-06-12:** `test_api.py` (register/dup-reject/login/auth-guard/me/create/
bulk/list-order/stats/leaderboard) all pass; live uvicorn boot + register + authed `/me` OK.

**Backend Bolts:**
| Bolt | Feature | Status |
|---|---|---|
| BS1 | User auth (JWT) + profiles | ✅ Done (email/password) |
| BS2 | Workout session sync (POST/bulk from app) | ✅ Done (server side) |
| BS3 | Leaderboard + stats API | ✅ Done (ranked by points) |
| BS-M | **Mobile↔backend wiring** (login screens, API client, sync `WorkoutStore`) | ⬜ Next decision |
| BS4 | Push notifications (coach alerts) | 🔵 Later (FCM) |
| BS5 | OTA firmware hosting | 🔵 Later |

### Phase 9 — Operations: Hardware v2 (🔵 PLANNED)

| Feature | Component | Notes |
|---|---|---|
| Battery level BLE | ADC on ESP32-S3 | Expose via `cdef5` characteristic |
| USB-C charging | BQ24079 or TP4056 | 3.7V LiPo management |
| Haptic feedback | ERM vibration motor | Rep milestone buzz |
| Heart rate | MAX30102 | I²C, add to MotionPacket v2 |
| Cable tension | HX711 + load cell | Resistance in kg |

### Phase 9.5 — Landing Website (✅ LIVE)

**AI Agent:** Claude AI — Fable 5 (Latest Model)
**Completed:** 2026-06-13 — **https://tutu-cjay.github.io/**

Customer-facing marketing + storefront (`website/`), reframed from the startup-pitch deck
(`docs/Gym Path (1).pptx`) to a consumer product site. Static HTML/CSS/JS, dark + neon-green
brand, Mongolian copy. Deployed to the org Pages repo `Tutu-Cjay/Tutu-Cjay.github.io`.

- **Pages:** `index.html` (hero, features, product, how-it-works, app showcase, **shop**, **subscription plans**, CTA), `account.html` (sign up / log in), `profile.html` (plan + order history)
- **Media:** pitch-deck videos converted to web mp4 + jpg posters via ffmpeg (211 MB → ~42 MB; unused investor-section clips dropped)
- **Demo auth:** front-end only (`assets/js/auth.js`, localStorage) — to be swapped for the Phase 9 FastAPI backend (JWT) once it's publicly hosted
- **Commerce:** pricing + order/plan intent (no real payment yet — Stripe later)
- Deployed via `gh` CLI (device-code auth) + git; existing repo LICENSE merged in

**Follow-ups:** wire account/checkout to the backend; real payments; custom domain.

### Phase 10 — Store Release (🔵 PLANNED)

- [ ] Play Store listing (screenshots, description, privacy policy)
- [ ] App Store submission
- [ ] Firmware v1.0 release tag
- [ ] CI/CD: GitHub Actions → EAS Build for Flutter APK/IPA

---

## 5. System Architecture (Current State)

```
┌────────────────────────────────────────────────────────────────┐
│                        GYMPATH v1.0                            │
│                                                                │
│  ┌─────────────────────────┐          ┌────────────────────┐  │
│  │  ESP32-S3 Smart Tracker │          │  Flutter Mobile App│  │
│  │                         │          │                    │  │
│  │  QMI8658 (1000 Hz)      │          │  BleService        │  │
│  │    ↓                    │  BLE 5.0 │    ↓               │  │
│  │  Mahony AHRS (500 Hz)   │◄────────►│  MotionData stream │  │
│  │    ↓                    │  60B/20ms│    ↓               │  │
│  │  rotateToEarth()        │          │  WorkoutGameScreen │  │
│  │    ↓                    │          │  MotionLogScreen   │  │
│  │  LPF + integrate        │          │  HomeScreen (4tab) │  │
│  │    ↓                    │          │  GymMonitoring     │  │
│  │  accEnv + rep count     │          │  Leaderboard       │  │
│  │    ↓                    │          │  MealPlan          │  │
│  │  TFT 7-seg display      │          │                    │  │
│  └─────────────────────────┘          └────────────────────┘  │
│                                                ↕ (planned)     │
│                                       ┌────────────────────┐  │
│                                       │  Backend Server    │  │
│                                       │  FastAPI + Postgres│  │
│                                       │  Redis + S3        │  │
│                                       └────────────────────┘  │
└────────────────────────────────────────────────────────────────┘
```

---

## 6. BLE Protocol Reference

### Service UUID: `12345678-1234-5678-1234-56789abcdef0`

| UUID | Name | Props | Format | Status |
|---|---|---|---|---|
| `…cdef1` | IMU Motion Data | READ, NOTIFY | 104B packed (v2; v1 apps read first 60B) | ✅ v2 since B8 |
| `…cdef2` | Rep Count | READ, NOTIFY | int32 LE | ✅ Implemented |
| `…cdef3` | Mean Velocity | READ, NOTIFY | float32 LE | ✅ Implemented |
| `…cdef4` | Position Reset | WRITE | uint8 | ⬜ Planned B7b |
| `…cdef5` | Battery Level | READ | uint8 % | ⬜ Planned Phase 9 |

### Connection parameters:
- Advertising: `"Smart Tracker"`, service UUID in adv data
- MTU: 185 bytes | TX: +9 dBm | Interval: 7.5–15ms | Timeout: 2000ms

---

## 7. File Index (Current)

```
Gympath_project/
├── PROJECT_PLAN.md              ← THIS FILE — AI-DLC history + roadmap
├── GYMPATH_DOCS.md              ← Full technical documentation + SVG pipelines
├── README.md                    ← ⚠️ OUTDATED (says React Native, MPU6050)
├── firmware/IMU_path/
│   ├── IMU_path.ino             ← ESP32 main (499 lines) ✅
│   ├── logo200.h                ← Boot logo RGB565 array ✅
│   └── logo generator.py        ← PNG → header conversion ✅
├── mobile/
│   ├── pubspec.yaml             ← flutter_blue_plus + permission_handler ✅
│   ├── lib/
│   │   ├── main.dart            ← routes, theme scale ✅
│   │   ├── theme/app_theme.dart ← design tokens ✅
│   │   ├── models/motion_data.dart  ← 60B parser ✅
│   │   ├── services/ble_service.dart ← BLE singleton ⚠️ bugs H1,H2,H4
│   │   ├── screens/
│   │   │   ├── splash_screen.dart ✅
│   │   │   ├── connect_device_screen.dart ⚠️ bug H3
│   │   │   ├── home_screen.dart ⚠️ hardcoded data M6
│   │   │   ├── choose_workout_screen.dart ✅
│   │   │   ├── workout_game_screen.dart ⚠️ bug M3
│   │   │   ├── motion_log_screen.dart ✅
│   │   │   ├── gym_monitoring_screen.dart ✅
│   │   │   ├── leaderboard_screen.dart ✅
│   │   │   ├── meal_plan_screen.dart ✅
│   │   │   └── active_workout_screen.dart ✅
│   │   ├── widgets/bottom_nav_bar.dart ✅
│   │   └── utils/responsive.dart ✅
│   └── DEPLOY.md
├── tools/
│   ├── imu_debug_viewer.py      ← serial debug viewer/logger (B8-D2) ✅
│   └── logs/                    ← CSV logs written by the viewer
├── firmware_backup_2026-06-10/  ← pre-B8 firmware backup
└── docs/
    ├── requirements.md ✅
    ├── user_stories.md ✅
    ├── ui_flow.md ✅
    └── ble_protocol.md ✅
```

---

## 8. Human Checkpoints Summary

| Checkpoint | Phase | Condition | Status |
|---|---|---|---|
| CP0 | Inception | Requirements + BLE protocol approved | ✅ Done |
| CP1 | B3 | BLE GATT tested with nRF Connect | ✅ Done |
| CP2 | B7 | Bug fixes verified, rep accuracy ≥95% | ⬜ Pending |
| CP3 | BS2 | Backend session sync working end-to-end | ⬜ Planned |
| CP4 | Store | Privacy review, permissions, release notes | ⬜ Planned |

---

## 9. Testing Strategy

| Layer | Method | Status |
|---|---|---|
| Firmware unit | Mock IMU data, verify rep count logic | ⬜ Not done |
| Firmware BLE | nRF Connect app manual test | ✅ Done |
| Flutter BLE parse | Unit test `MotionData.fromBytes()` with known bytes | ⬜ Not done |
| Flutter UI | Widget tests for screen rendering | ⬜ Not done |
| E2E physical | Real device + phone, US1–US5 acceptance | ⬜ In B7 |

---

## 10. References

- [AI-DLC Paper](https://prod.d13rzhkk8cj2z0.amplifyapp.com/)
- [AWS AI-DLC Blog](https://aws.amazon.com/blogs/devops/ai-driven-development-life-cycle/)
- [AI-DLC Workflows (GitHub)](https://github.com/awslabs/aidlc-workflows)
- Claude AI Fable 5 (Latest Claude model) — agent upgraded from Phase 7 onward
- UI Design references: `UI_image/` (1000003767.jpg, 1000004013.jpg, 1000004014.jpg, 1000004025.jpg)
- Result video: `RESULT_VIDEO/1000004024.mp4` — physical device demo
