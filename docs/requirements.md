# Gympath Requirements Document

## Overview

Gympath is a fitness cable machine motion tracking system consisting of:
- **Smart Tracker Device**: ESP32 + IMU based motion sensor
- **Mobile Application**: Cross-platform iOS/Android app for workout tracking

## 1. Device Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| D1 | ESP32 microcontroller with BLE 5.0 support | Must |
| D2 | 6/9-axis IMU (e.g., MPU6050, MPU9250) for orientation and acceleration | Must |
| D3 | USB-C charging port for battery management | Must |
| D4 | Compact puck-shaped form factor suitable for attachment to gym equipment | Must |
| D5 | Real-time motion processing at 100-200 Hz sampling rate | Must |

## 2. Connectivity Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| C1 | BLE pairing and device discovery from mobile app | Must |
| C2 | Custom GATT service for motion data, rep count, velocity, weight, battery | Must |
| C3 | "Smart Tracker" device branding (VN-E900 style) in advertising | Should |
| C4 | Reliable connection with automatic reconnection on disconnect | Should |

## 3. Motion Data Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| M1 | Raw IMU data processed to filtered orientation (quaternion/Euler) | Must |
| M2 | Rep count detection via peak/trough analysis of motion axis | Must |
| M3 | Mean velocity calculation (m/s) per rep or per set | Must |
| M4 | Support for cable machine exercises (linear motion detection) | Must |

## 4. App UX Requirements

| ID | Requirement | Priority |
|----|-------------|----------|
| A1 | Connect Device screen: BLE scan, Smart Tracker discovery, Connect/Skip | Must |
| A2 | Workout selection with search and Start Workout flow | Must |
| A3 | Active workout screen: timer, sets/reps/weight, Mean Velocity display | Must |
| A4 | Gym Monitoring: performance graph, alerts (e.g., "Underperformed Bench Press") | Must |
| A5 | Home/Dashboard: streaks, daily progress, Add Workout, monthly stats | Must |
| A6 | Leaderboard and social activity feed | Should |
| A7 | Meal Plan with personalized meals and grocery list | Should |
| A8 | Dark theme with neon green accents (#00FF00) | Must |

## 5. Non-Functional Requirements

| ID | Requirement |
|----|-------------|
| NF1 | Mobile app supports iOS and Android |
| NF2 | BLE data latency < 100ms for real-time display |
| NF3 | Rep count accuracy > 95% for cable machine exercises |
| NF4 | Battery life > 8 hours continuous use |
