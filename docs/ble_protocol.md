# Gympath BLE Protocol Specification

## Overview

The Smart Tracker device exposes a custom GATT service for motion data, configuration, and device info. The mobile app acts as BLE Central; the device acts as BLE Peripheral.

> **Current firmware (2026-10-06): `firmware/Gympath_Track`** implements `…cdef1`–`…cdef3`
> plus `…cdef8` (track control), `…cdef9` (20-byte track data), `…cdefa` (OTA) and
> `…cdefb` (version) — sections 8–11 below — and the USB test mode at the end.
> `…cdef4`–`…cdef7` are still planned.
>
> **Earlier status (2026-06-13, IMU_path firmware).** The current firmware implements only
> three characteristics — `…cdef1` (motion, **60-byte** packed `MotionPacket`;
> the v2/B8 build extends it to 104 bytes), `…cdef2` (rep count, **int32 LE**),
> and `…cdef3` (mean velocity, float32 LE). Advertised local name is
> **"Smart Tracker"**. Characteristics `…cdef4`–`…cdef7` (weight, battery,
> device name, set-complete) below are **planned, not yet in firmware**. The
> mobile `BleService` is written against the implemented set.

## Service Definition

### Primary Service: Gympath Motion Tracking

| Attribute | UUID | Description |
|-----------|------|-------------|
| Service UUID | `12345678-1234-5678-1234-56789abcdef0` | Gympath Motion Service |

### Characteristics

#### 1. IMU Data (Notify)

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef1` |
| Properties | Notify, Read |
| Data Format | **60-byte packed `MotionPacket`** (little-endian): `uint32 ts_ms`, `float ax,ay,az`, `float gx,gy,gz`, `float accEnv`, `float velX,velY,velZ`, `float posX,posY,posZ`, `int32 motionCount`. v2/B8 firmware appends 44 bytes (roll/pitch/yaw, origin, displacement, repPhase, zupt) → 104 bytes; app parses v2 fields only when `length >= 104`. |
| Update Rate | 50 Hz (every 20 ms) |
| Description | Full motion snapshot; app derives rep count, progress, and charts from it. |

#### 2. Rep Count (Notify, Read)

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef2` |
| Properties | Notify, Read |
| Data Format | **4 bytes: int32 LE** (cumulative `motionCount`); notified only on change |
| Description | Current rep count. (App reads count from the cdef1 packet too.) |

#### 3. Mean Velocity (Notify, Read)

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef3` |
| Properties | Notify, Read |
| Data Format | 4 bytes: float32 (m/s) |
| Description | Mean velocity of the last completed rep or current set average |

#### 4. Weight (Read, Write)

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef4` |
| Properties | Read, Write |
| Data Format | 2 bytes: uint16 (value = kg × 10, e.g., 500 = 50.0 kg) |
| Description | Current weight setting in kg; writable by app for display/sync |

#### 5. Battery (Read, Notify) — `firmware/Gympath_Track` 1.2+

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef5` |
| Properties | Read, Notify |
| Data Format | uint8 percent (0-100; 255 = unknown / no battery, USB only), then (1.2.1+) uint8 flags: bit0 charging, bit1 computer on USB |
| Description | Battery level from GPIO1 (200k/100k divider), notified when it changes |

#### 6. Device Name (Read)

| Property | Value |
|----------|-------|
| UUID | Standard Device Name (0x2A00) or custom `12345678-1234-5678-1234-56789abcdef6` |
| Properties | Read |
| Data Format | UTF-8 string |
| Value | "Smart Tracker" or "Gympath Tracker" |

#### 7. Set Complete (Notify, Write)

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef7` |
| Properties | Notify, Write |
| Data Format | 1 byte: 0 = no op, 1 = reset rep count / new set |
| Description | App writes 1 to signal set complete; device notifies on set completion |

#### 8. Track Control (Write) — `firmware/Gympath_Track`

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef8` |
| Properties | Read, Write, Write Without Response |
| Data Format | 2 bytes: `[cmd, seq]` — cmd `0` = STOP, `1` = START, `2` = ZERO; `seq` changes on every write so a repeated command is still acted on exactly once |
| Description | START: device (already placed) averages accel+gyro while still → gravity vector, \|g\|, gyro bias; then tracks. ZERO: resets position to 0 without re-calibrating |

#### 9. Track Data (Notify) — `firmware/Gympath_Track`

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef9` |
| Properties | Read, Notify |
| Update Rate | 50 Hz while connected |
| Data Format | 20-byte packed: `uint32 t_ms`, `float a` (m/s²), `float v` (m/s), `float p` (m), `int16 reps`, `uint8 state` (0 idle, 1 calibrating, 2 tracking, 3 calibration failed), `uint8 flags` (bit0 = still/ZUPT) |
| Description | 1D motion along the gravity axis captured at START. **+ = against gravity (up), − = with gravity (down)**; `p` is relative to the START position |

#### 10. Firmware Update / OTA (Write, Notify) — `firmware/Gympath_Track`

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdefa` |
| Properties | Write, Write Without Response, Notify |
| App → device | `BEGIN [1, size u32, md5 16 B]` · `DATA [2, bytes…]` (≤ MTU−4 per write, **with response** = flow control) · `END [3]` · `ABORT [4]` |
| Device → app (notify) | `[state, err, written u32]` — state `0` idle, `1` receiving, `2` done (reboots ~1.5 s later), `3` error; err `1` bad header, `2` no space, `3` flash write, `4` verify/MD5 |
| Description | Writes into the inactive OTA partition; the old firmware keeps running until the new image passes the MD5 + image check. A dropped link mid-update aborts and discards the partial image |

#### 11. Firmware Version (Read) — `firmware/Gympath_Track`

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdefb` |
| Data Format | UTF-8 string, e.g. `1.0.0` (`FW_VERSION`) — compared with `https://tutu-cjay.github.io/firmware/manifest.json` |

> Gympath_Track also keeps …cdef1 (60 B; `az`/`velZ`/`posZ` carry the 1D values,
> `motionCount` = reps), …cdef2 and …cdef3, so older app screens keep working.

#### 12. Day Summary (Write) — `firmware/Gympath_Track` 1.2+

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdefc` |
| Properties | Write, Write Without Response |
| Data Format | 23 bytes, little endian (firmware `DayPacket`, app `DaySummary.encode`) |
| Description | Today's numbers for the idle screen; sent after connecting and after every saved set. Kept in flash across restarts |

| Offset | Type | Field |
|---|---|---|
| 0 | u8 | version = 1 |
| 1 | u32 | phone local time, s since 1970 (UTC + offset): the tracker's clock |
| 5 | u16 | reps today |
| 7 | u16 | sets today |
| 9 | u32 | weight lifted today, kg (weight × reps) |
| 13 | u16 | time under load today, min |
| 15 | u16 | daily rep goal |
| 17 | u8 | week streak (weeks) |
| 18 | u8 | training days this week |
| 19 | u8 | days a week that count |
| 20 | u8 | this week's training days, bit 0 = Monday … bit 6 = Sunday |
| 21 | u8 | muscle groups worked today |
| 22 | u8 | muscle groups the exercises can train |

#### 13. Settings (Read, Write) — `firmware/Gympath_Track` 1.5+

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdefd` |
| Properties | Read, Write |
| Data Format | write `[1, theme, number style]` (style optional; 1.5 takes `[1, theme]`); read `[1, theme, theme count, number style, style count]` (1.5 reads back only the first 3) |
| Description | Rep screen theme: 0 Classic, 1 Stroke, 2 Tempo, 3 Minimal. Number style of the rep count (1.6+): 0 Segment, 1 Rounded segment, 2 Bold, 3 Light. The count is centred on its ink at any digit count. Both kept in flash |

## USB Test Mode (no Bluetooth — emulator testing)

`tools/serial_bridge.py` relays the tracker's UART (921600 baud) to TCP
`127.0.0.1:7700`; the Android emulator reaches it at `10.0.2.2:7700`. In a
debug build, long-press the status chip → *USB test link*.

| Direction | Line | Meaning |
|-----------|------|---------|
| PC → device | `TEST 1` / `TEST 0` | enter / leave test mode (bridge sends these on app connect / disconnect) |
| app → device | `C,<cmd>,<seq>` | same as a write to …cdef8 |
| device → app | `V,<version>` | sent on entering test mode |
| device → app | `T,<hex>` | 20-byte TrackPacket (§9), 50 Hz |
| device → app | `M,<hex>` | 60-byte MotionPacket (§1), 50 Hz |

The display shows **USB TEST** while active. `serial_bridge.py --sim`
replaces the tracker with synthetic ~30 cm reps (no hardware needed).

## Advertising

| Field | Value |
|-------|-------|
| Local Name | "Smart Tracker" or "VN-E900" |
| Service UUID | 12345678-1234-5678-1234-56789abcdef0 |
| Tx Power | 0 dBm (typical) |
| Connectable | Yes |
| Scan Response | Device name, optional battery % |

## Connection Parameters

| Parameter | Recommended |
|-----------|-------------|
| Connection Interval | 7.5 - 15 ms |
| Slave Latency | 0 |
| Supervision Timeout | 2000 ms |

## Data Flow

1. **App discovers device** via scan filter on service UUID or local name
2. **App connects** and discovers service/characteristics
3. **App subscribes** to IMU Data, Rep Count, Mean Velocity, Set Complete (notify)
4. **Device streams** IMU and rep/velocity updates at configured rate
5. **App writes** Weight when user changes it; writes Set Complete when user finishes a set
6. **App reads** Battery, Device Name periodically or on connect

## Byte Order

All multi-byte values use **little-endian** byte order.
