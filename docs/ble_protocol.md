# Gympath BLE Protocol Specification

## Overview

The Smart Tracker device exposes a custom GATT service for motion data, configuration, and device info. The mobile app acts as BLE Central; the device acts as BLE Peripheral.

> **Implementation status (2026-06-13).** The current firmware implements only
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

#### 5. Battery (Read)

| Property | Value |
|----------|-------|
| UUID | `12345678-1234-5678-1234-56789abcdef5` |
| Properties | Read |
| Data Format | 1 byte: uint8 (0-100, percentage) |
| Description | Battery level in percent |

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
