# Gympath User Stories and Acceptance Criteria

## User Story Map

```
Connect & Pair          Workout Flow              Progress & Insights
────────────────        ─────────────             ──────────────────
US1: Pair Device   →    US2: Select Workout  →    US4: View Summary
                        US3: Live Tracking   →    US5: Gym Monitoring
                                                 US6: Dashboard
```

## User Stories

### US1: Pair Smart Tracker via BLE

**As a** gym user  
**I want to** pair my Smart Tracker device via Bluetooth from the Connect Device screen  
**So that** my workout data is streamed to the app in real-time

**Acceptance Criteria:**
- [ ] App displays Connect Device screen with Smart Tracker illustration
- [ ] App scans for BLE devices and filters for Gympath/Smart Tracker
- [ ] Detected device shows: "Smart Tracker", model "VN-E900", signal strength
- [ ] User can tap "Connect" to pair; tap "Skip for now" to bypass
- [ ] Successful connection navigates to main app flow
- [ ] Failed connection shows error message with retry option

---

### US2: Select Workout and Start Session

**As a** gym user  
**I want to** select a workout (e.g., Barbell Bench Press) and start a session  
**So that** the app tracks my exercise performance

**Acceptance Criteria:**
- [ ] App displays Choose Workout screen with search bar
- [ ] Workout list shows: Full Body, Barbell Bench Press, Squats, Deadlift, Pull-Up, Running (with durations)
- [ ] User can search workouts by category/name
- [ ] User selects a workout and taps "Start Workout"
- [ ] App navigates to Active Workout screen and starts timer

---

### US3: Receive Real-Time Data from Device

**As a** gym user  
**I want** the app to receive real-time reps, sets, weight, and mean velocity from the Smart Tracker  
**So that** I see accurate live feedback during my workout

**Acceptance Criteria:**
- [ ] App subscribes to BLE characteristics: rep count, mean velocity, weight
- [ ] Rep count updates in real-time on Active Workout screen
- [ ] Mean velocity (m/s) displays per set
- [ ] Weight (kg) is readable and writable from app
- [ ] Connection status indicator visible during workout

---

### US4: View Workout Summary

**As a** gym user  
**I want to** see a workout summary with Total Volume, Sets, and Mean Velocity  
**So that** I understand my performance after each session

**Acceptance Criteria:**
- [ ] Active Workout screen shows: Total Volume (kg), Sets count, Mean Velocity (m/s)
- [ ] Bar chart or progress visualization for performance
- [ ] "Finish Workout" button concludes session and saves data
- [ ] Summary persists and is viewable in history

---

### US5: Gym Monitoring Alerts

**As a** gym user  
**I want** the app to surface alerts like "Underperformed Bench Press"  
**So that** I receive intelligent feedback on my form or effort

**Acceptance Criteria:**
- [ ] Gym Monitoring screen displays performance graph over time
- [ ] Alerts section lists workout-specific alerts (Bench Press, Running, Squats)
- [ ] "Underperformed" type alerts with optional weight suggestions
- [ ] Weekly Challenge progress (5/7, steps) visible

---

### US6: Dashboard, Streaks, Leaderboard, Meal Plan

**As a** gym user  
**I want to** view my Home dashboard, streaks, leaderboard, and meal plan  
**So that** I stay motivated and have a holistic fitness experience

**Acceptance Criteria:**
- [ ] Home screen: Day N, streak count, daily activity checkmarks, Add Workout
- [ ] Monthly stats (e.g., 275,804 / 124,580) displayed
- [ ] Leaderboard: rankings (e.g., Sasha 60, You 57, Sarah 45)
- [ ] Activity feed: friend activities, achievements (e.g., "Alex unlocked 50 Days Streak")
- [ ] Meal Plan: personalized plan, breakfast/lunch/dinner, grocery list
