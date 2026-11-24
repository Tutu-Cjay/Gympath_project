/*
 * Gympath_Track — 1D gravity-axis tracker for cable machines.
 *
 * A cable machine only moves along one line (with / against gravity), so
 * instead of full 3D dead-reckoning we track a single signed axis:
 *
 *   1. Phone writes START to the control characteristic (…cdef8).
 *   2. Device must already be in place. It averages accel + gyro while still
 *      → gravity vector (body frame), |g|, and gyro bias.
 *   3. From then on every accel sample is projected onto that "up" axis:
 *          a_up = dot(a, up) - |g|      (+ = against gravity, − = with it)
 *      integrated to velocity and position. The up axis is carried through
 *      any rotation with the gyro (du/dt = −ω × u), so a handle that tilts
 *      still projects correctly.
 *   4. ZUPT zeroes velocity whenever the device is still.
 *   5. Streams a compact track packet (…cdef9) at 50 Hz for the phone's
 *      realtime position-vs-time graph, plus the legacy 60-byte packet on
 *      …cdef1 (az/velZ/posZ = 1D values) so older app screens keep working.
 *
 * BLE is callback-free on purpose: NimBLE-Arduino 2.x does not call the old
 * 1.x callback signatures, so connection state is read from
 * getConnectedCount() and commands are polled from the characteristic value.
 *
 * Board: Waveshare ESP32-S3-LCD-1.28 (TFT_eSPI setup: firmware/tft_setup).
 *
 * Release notes
 * 1.7.0: live preview while choosing in the app: the tracker shows the rep
 * screen and follows the app's carousels in real time, themes sliding
 * sideways and the count sliding up / down (pages rendered into PSRAM,
 * panel SPI at 80 MHz for smooth motion).
 * 1.6.0: number styles for the rep count, chosen in the app: Segment,
 * Rounded segment, Bold and Light, on every theme. The count always sits
 * centred whatever its number of digits (4 digits drop to a smaller size).
 * 1.5.0: four rep screen themes, chosen in the app: Classic (7-segment
 * count, speed ring), Stroke (the ring fills with each rep's travel),
 * Tempo (lift / lower phase and the last rep's up / down time), Minimal
 * (big count, a dot per rep). Kept across restarts.
 * 1.4.0: more accurate positions: rest is only accepted when the tracked
 * speed is low too (smooth mid-stroke motion no longer reads as rest);
 * drift is removed at every rest (back-correction of the movement) and at
 * every bottom of back-to-back reps; the old velocity leak (which shrank
 * long, slow strokes) is gone. In simulation (tools/track_sim.py): range
 * error 10-18 % → 1-4 %, lifting speed 5-8 % → <1 %, resting drift after
 * 10 reps ~1 m → 0.
 * 1.3.2: greys tinted towards the accents: deep blue-slate ring tracks,
 * green-grey clock, blue-grey secondary text and empty week dots.
 * 1.3.1: updates no longer fail at a random point: the stall check compared
 * the loop's clock with a later time stamp from the Bluetooth task, which
 * wrapped around and cancelled the update; the battery is not read during
 * an update.
 * 1.3.0: subpixel text rendering (like ClearType): glyph edges placed at a
 * third of a pixel using the panel's B-G-R stripes, drawn in one block per
 * text (no flicker).
 * 1.2.5: smoother text: glyph edges are gamma-corrected for the black
 * screen (the panel blends in sRGB, which made edges look thin and stepped).
 * 1.2.4: charging is shown by the battery's blocks filling up one after
 * another (no CHG text); the battery icon has 4 blocks.
 * 1.2.3: anti-aliased text (Roboto) and shapes; fixed overlaps: the battery
 * strip no longer erases the inner ring and the footer line fits the round
 * screen (layout checked by tools/check_tracker_layout.py).
 * 1.2.2: the screen redraws only what changed (text in place, rings by the
 * changed arc, digits by the segments that switch), so it no longer
 * flickers or stalls on full-screen repaints.
 * 1.2.1: charging is detected and shown (CHG and a bolt on the battery):
 * a computer on USB, a charger plugged in or out (the voltage step), or a
 * voltage that keeps rising or sits at 4.2 V; the percentage while charging
 * is corrected for the charge current. The app gets it with the battery.
 * 1.2.0: when no set is running the screen shows today at a glance: reps
 * against the daily goal and muscles worked as rings, sets, weight lifted,
 * this week's training days and week streak, the clock, and the battery
 * level (also readable by the app on …cdef5). The app sends the day's
 * numbers (…cdefc); the last ones are kept across restarts.
 * 1.1.1: calibration no longer reports MOVED on a still tracker: it judges
 * stillness by how much the readings vary, so the gyro's zero offset is
 * measured instead of treated as movement; when it does fail, the screen
 * shows what the sensor measured.
 * 1.1.0: reps that pause at either end are no longer lost; motion is
 * integrated with the real time between IMU samples; the first START after
 * reconnecting is never ignored; a stalled update is cancelled after 15 s
 * and a failed update is shown on the screen; an IMU fault is shown instead
 * of a frozen screen; a new image that crashes rolls back to the old one.
 */
#include <Wire.h>
#include <QMI8658.h>
#include <TFT_eSPI.h>
#include <NimBLEDevice.h>
#include <Update.h>
#include <esp_ota_ops.h>
#include <Preferences.h>
#include "tracker_fonts.h"   // subpixel Roboto (tools/make_tracker_fonts.py)
#include "soc/usb_serial_jtag_reg.h"
#include <math.h>

#define FW_VERSION   "1.7.0"     // bump on every release; the app compares it
                                 // with the published manifest.json to offer
                                 // updates (.github/workflows/firmware.yml)
#define FW_BUILD     "TRACK-1D-16"
#define DEBUG_STREAM 0   // 1 = CSV over serial (t,a,v,p,reps,state) @ 50 Hz
#define SERIAL_BAUD  921600

// USB test mode (tools/serial_bridge.py → app on an emulator, no Bluetooth):
//   PC → device  "TEST 1" / "TEST 0"   enter / leave test mode
//                "C,<cmd>,<seq>"       same as a write to …cdef8
//   device → PC  "V,<FW_VERSION>"      on entering test mode
//                "T,<hex 20 B>"        TrackPacket  @ 50 Hz
//                "M,<hex 60 B>"        MotionPacket @ 50 Hz

/* ================= OBJECTS ================= */
QMI8658 imu;
QMI8658_Data imuData;
TFT_eSPI tft;
// Where the drawing helpers draw: the panel, or an off-screen page (the live
// theme preview renders rep screens into PSRAM and slides them).
TFT_eSPI*    gfx = &tft;
TFT_eSprite* gfxPage = nullptr;   // set while gfx is an off-screen page

// Types used in function parameters live up here: the Arduino build puts
// its generated prototypes before the first function.
// What a rep screen shows: live values during a set, sample ones in the
// app's preview.
struct RepIn {
  int      reps;
  float    frac;          // Stroke: travel of the current stroke
  int8_t   phase;         // +1 lifting, −1 lowering, 0 holding
  uint32_t upMs, downMs;  // Tempo: last rep
  uint16_t speedCol;      // Classic: ring colour
  uint8_t  style;         // number style
};
// A rendered rep screen in PSRAM (live preview).
struct PageSlot { TFT_eSprite* spr; int8_t th, st; uint32_t used; };

/* ================= BLE ================= */
#define SERVICE_UUID     "12345678-1234-5678-1234-56789abcdef0"
#define MOTION_CHAR_UUID "12345678-1234-5678-1234-56789abcdef1"  // legacy 60 B
#define REP_CHAR_UUID    "12345678-1234-5678-1234-56789abcdef2"
#define VEL_CHAR_UUID    "12345678-1234-5678-1234-56789abcdef3"
#define CTRL_CHAR_UUID   "12345678-1234-5678-1234-56789abcdef8"  // app → device
#define TRACK_CHAR_UUID  "12345678-1234-5678-1234-56789abcdef9"  // device → app
#define OTA_CHAR_UUID    "12345678-1234-5678-1234-56789abcdefa"  // firmware update
#define VER_CHAR_UUID    "12345678-1234-5678-1234-56789abcdefb"  // FW_VERSION
#define BAT_CHAR_UUID    "12345678-1234-5678-1234-56789abcdef5"  // battery %
#define DAY_CHAR_UUID    "12345678-1234-5678-1234-56789abcdefc"  // app → day summary
#define SET_CHAR_UUID    "12345678-1234-5678-1234-56789abcdefd"  // settings (rep screen theme)

// OTA over BLE (written to …cdefa, with response = flow control):
//   BEGIN [1, size u32 LE, md5 16 B]   DATA [2, bytes…]   END [3]   ABORT [4]
// Device notifies status on the same characteristic:
//   [state, err, written u32 LE]  state: 0 idle, 1 receiving, 2 done, 3 error
//   err: 1 bad header, 2 no space, 3 flash write, 4 verify/MD5, 5 timed out
enum OtaOp : uint8_t { OTA_BEGIN = 1, OTA_DATA = 2, OTA_END = 3, OTA_ABORT = 4 };
enum OtaState : uint8_t { OTA_IDLE = 0, OTA_RECEIVING = 1, OTA_DONE = 2, OTA_ERROR = 3 };

// Control command: [cmd, seq]. seq changes on every write so the same
// command can be sent twice in a row and still be acted on once each.
enum Cmd : uint8_t { CMD_STOP = 0, CMD_START = 1, CMD_ZERO = 2 };

enum TrackState : uint8_t {
  ST_IDLE       = 0,  // waiting for START
  ST_CALIB      = 1,  // measuring gravity — keep the device still
  ST_TRACK      = 2,  // tracking
  ST_CALIB_FAIL = 3,  // never got a still window
};

struct __attribute__((packed)) TrackPacket {   // 20 bytes
  uint32_t t_ms;
  float    a;      // m/s²  along up axis (+ = against gravity)
  float    v;      // m/s
  float    p;      // m     relative to the START position
  int16_t  reps;
  uint8_t  state;  // TrackState
  uint8_t  flags;  // bit0 = ZUPT active (device still)
};

struct __attribute__((packed)) MotionPacket {  // legacy 60 bytes
  uint32_t ts_ms;
  float ax, ay, az, gx, gy, gz, accEnv;
  float velX, velY, velZ, posX, posY, posZ;
  int32_t motionCount;
};

NimBLEServer* bleServer = nullptr;
NimBLECharacteristic* motionChar = nullptr;
NimBLECharacteristic* repChar = nullptr;
NimBLECharacteristic* velChar = nullptr;
NimBLECharacteristic* ctrlChar = nullptr;
NimBLECharacteristic* trackChar = nullptr;
NimBLECharacteristic* batChar = nullptr;
NimBLECharacteristic* dayChar = nullptr;
NimBLECharacteristic* otaChar = nullptr;
NimBLECharacteristic* verChar = nullptr;

volatile uint8_t  otaState = OTA_IDLE;
volatile uint8_t  otaErr = 0;
volatile uint32_t otaSize = 0, otaWritten = 0;
volatile bool     otaRebootPending = false;
uint32_t          otaDoneMs = 0;
volatile uint32_t otaLastMs = 0;         // last BEGIN / DATA (stall detection)
volatile uint32_t otaErrorMs = 0;        // when the last update failed
const uint32_t    OTA_STALL_MS = 15000;  // no data this long → cancel

/* ================= TUNING ================= */
const uint32_t CALIB_WINDOW_MS  = 500;    // still window used for gravity
const uint32_t CALIB_TIMEOUT_MS = 6000;   // give up if never still
// "Still" is judged by how much the readings vary, not by their mean: the
// gyro's zero-rate offset (a few °/s on the QMI8658) is what calibration
// measures, so it must not count as movement.
const float    CALIB_ACC_STD    = 0.25f;  // m/s²  max std-dev of |a|
const float    CALIB_GYRO_STD   = 0.05f;  // rad/s max std-dev of ω (≈ 3 °/s)
const float    CALIB_GYRO_MAX   = 0.35f;  // rad/s max mean |ω| (≈ 20 °/s): turning
const float    CALIB_G_MIN      = 7.0f;   // m/s²  |a| must look like gravity
const float    CALIB_G_MAX      = 12.5f;

const float    ZUPT_ACC_TH      = 0.15f;  // m/s²  | |a| − |g| | below this …
const float    ZUPT_GYRO_TH     = 0.08f;  // rad/s … and |ω| below this …
const float    ZUPT_TIME_S      = 0.08f;  // … for this long → device is still

const float    ACC_LPF          = 0.35f;  // EMA weight of the new sample
const float    ACC_DEADBAND     = 0.0f;   // m/s²  (drift is corrected at rest now)
const float    VEL_LEAK         = 0.02f;  // 1/s   only a whisper of damping
// Rest is only believed when the tracked speed is low too: at constant
// speed mid-stroke the sensors are as quiet as at rest.
const float    ZUPT_MAX_V       = 0.12f;  // m/s
const float    ZUPT_LONG_S      = 1.5f;   // s  quiet this long → rest anyway
// Drift correction (tools/track_sim.py measures it):
const float    MAX_SEG_S        = 8.0f;   // s  longer movements: no back-correction
const float    HOME_SNAP        = 0.03f;  // m  at rest this close to the start → on the pile
const float    BOTTOM_SNAP      = 0.06f;  // m  back-to-back reps: bottoms this close …
const float    BOTTOM_GAIN      = 0.5f;   //    … are pulled halfway to the last one
const float    AXIS_REALIGN     = 0.02f;  // per still sample, pull up-axis to accel
const float    BIAS_REFINE      = 0.002f; // per still sample, refine gyro bias

const float    REP_MIN_DISP     = 0.05f;  // m  an excursion must travel ≥ 5 cm
const float    REP_RETURN_FRAC  = 0.60f;  // …and come back ≥ 60 % of it

/* ================= STATE ================= */
volatile uint8_t state = ST_IDLE;
volatile int32_t reps = 0;
volatile float   vNow = 0;     // read by the display task

// calibration accumulators
uint32_t calStartMs = 0, calWinStartMs = 0;
uint32_t calN = 0;
double   cSum[3], cMagSum, cMagSq, cGyro[3], cGyroSq[3], cGyroMag;
// the stillest window seen, shown on the screen when calibration fails
float calBestAccMean = 0, calBestAccStd = 99, calBestGyroDps = 0, calBestGyroStdDps = 0;
void calibReset(uint32_t now);

// tracking
float up[3]    = {0, 0, 1};   // gravity-opposite unit vector, body frame
float gMag     = 9.81f;
float gBias[3] = {0, 0, 0};   // rad/s
float aF = 0, v = 0, p = 0, accEnv = 0;
float stillT = 0;
bool  zupt = false;
float segT = 0;          // s moving since the last rest or bottom
float vAtStill = 0;      // velocity when the sensors went quiet
float lastBottom = 0;    // where the last stroke started (m)
const float home = 0;    // the resting height the set started from

// Rep counter (direction agnostic, position based): one rep = the stack
// travels ≥ REP_MIN_DISP from where the movement started and comes back
// ≥ REP_RETURN_FRAC of the way. A pause at either end (ZUPT) keeps the
// excursion, so a held contraction still counts.
float  repBase = 0;           // where the current excursion started (m)
float  repPeak = 0;           // furthest distance from repBase so far (m)
int8_t repDir  = 0;           // +1 / −1 during an excursion, 0 between reps
int8_t lastDir = 0;           // direction of the last rep (0 after a rest)

uint32_t lastSampleUs = 0, lastBleMs = 0, lastDbgMs = 0;
bool     imuOk = true;
bool     fwConfirmed = false;
int32_t  lastRepSent = -1;
int      lastSeq = -1;
bool     wasConnected = false;
volatile bool testMode = false;   // USB test link active
uint32_t lastTestMs = 0;
char     serBuf[32];
uint8_t  serLen = 0;

/* ================= DAY SUMMARY + BATTERY ================= */
// What the app sends to …cdefc after connecting and after every saved set.
// Little endian. localEpoch is the phone's local time (UTC + its offset), so
// days and the clock follow the user's time zone.
struct __attribute__((packed)) DayPacket {
  uint8_t  ver;            // 1
  uint32_t localEpoch;     // s
  uint16_t reps;           // today
  uint16_t sets;
  uint32_t volumeKg;       // weight × reps, kg
  uint16_t activeMin;      // time under load, minutes
  uint16_t repGoal;        // daily rep goal
  uint8_t  weekStreak;     // weeks in a row with enough training days
  uint8_t  daysThisWeek;
  uint8_t  weekGoal;       // days a week that count
  uint8_t  weekMask;       // bit0 = Monday … bit6 = Sunday trained
  uint8_t  musclesActive;  // muscle groups worked today
  uint8_t  musclesTotal;
};
static_assert(sizeof(DayPacket) == 23, "DayPacket is 23 bytes");

DayPacket         day = {};
volatile bool     dayValid = false;     // have numbers (from the app or NVS)
volatile bool     clockValid = false;   // the app gave the time since boot
volatile uint32_t dayRxMs = 0;          // millis() when day.localEpoch was true
volatile uint16_t dayVersion = 0;       // bumps on every new packet
volatile bool     daySavePending = false;
Preferences       prefs;

// Rep screen theme, chosen in the app (…cdefd: [1, theme]); kept in NVS.
//   0 Classic  7-segment count, ring coloured by speed
//   1 Stroke   the ring fills with the stack's travel through each rep
//   2 Tempo    lift / lower phase and the last rep's up / down time
//   3 Minimal  big count and one dot per rep around the edge
const uint8_t     THEME_COUNT = 4;
volatile uint8_t  repTheme = 0;
volatile bool     themeSavePending = false;
volatile uint16_t themeVersion = 0;   // bumps on a change: the screen redraws

// For the themes: where the stack is in the stroke and the rep's tempo
// (written by the tracking on core 1, read by the display on core 0).
volatile float    strokeFrac = 0;     // 0 = start of the stroke, 1 = top of the last rep
volatile int8_t   phase = 0;          // +1 lifting, −1 lowering, 0 holding
volatile uint16_t tempoUpMs = 0, tempoDownMs = 0;   // the last counted rep

// Battery: GPIO1 through a 200k/100k divider (Waveshare ESP32-S3-LCD-1.28).
const int      BAT_PIN = 1;
float          vbat = 0;                // smoothed, V
volatile int   batPct = -1;             // −1 = not measured yet
volatile bool  batPresent = true;       // false: no cell, running from USB
volatile bool  batCharging = false;     // charger plugged in (see chargeStep)
volatile bool  usbHost = false;         // a computer is on the USB port
uint32_t       lastBatMs = 0;

// The board has no charger-status or VBUS pin (the ETA6096 STAT only drives
// its LED), so charging is inferred:
//  - a computer on USB is seen by its 1 kHz start-of-frame counter;
//  - plugging a charger in lifts the cell voltage by the charge current
//    through its internal resistance (tens of mV within seconds), unplugging
//    drops it again;
//  - while charging the voltage keeps climbing, or sits at the charger's
//    4.2 V limit, which a resting cell does not exceed.
const float CHG_STEP_V   = 0.040f;  // jump within ~10 s = plugged / unplugged
const float CHG_RISE_V   = 0.015f;  // rise over 5 min = charging
const float CHG_FALL_V   = 0.010f;  // fall over 5 min = not charging
const float CHG_TOP_V    = 4.19f;   // at/above: on the charger
float    vRecent[6] = {0};          // last 6 raw readings (2 s apart)
float    vHist[10]  = {0};          // one reading per 30 s (5 min)
int      vRecentN = 0, vHistN = 0;
uint32_t lastHistMs = 0, lastSof = 0;

bool usbHostSeen() {
  uint32_t sof = REG_GET_FIELD(USB_SERIAL_JTAG_FRAM_NUM_REG, USB_SERIAL_JTAG_SOF_FRAME_INDEX);
  bool moving = sof != lastSof;   // read 2 s apart: a host sends 2000 frames
  lastSof = sof;
  return moving;
}

void chargeStep(float v, uint32_t now) {
  usbHost = usbHostSeen();
  bool charging = batCharging;
  // sudden step: newest two readings against the oldest two (~10 s apart),
  // pairs averaged so ADC noise does not look like a step
  for (int i = 0; i < 5; i++) vRecent[i] = vRecent[i + 1];
  vRecent[5] = v;
  if (vRecentN < 6) vRecentN++;
  if (vRecentN == 6) {
    float d = (vRecent[4] + vRecent[5] - vRecent[0] - vRecent[1]) / 2;
    if (d >= CHG_STEP_V) { charging = true; vRecentN = 0; }        // count once
    else if (d <= -CHG_STEP_V) { charging = false; vRecentN = 0; }
  }
  // slow trend over five minutes
  if (now - lastHistMs >= 30000 || lastHistMs == 0) {
    lastHistMs = now;
    for (int i = 0; i < 9; i++) vHist[i] = vHist[i + 1];
    vHist[9] = vbat;
    if (vHistN < 10) vHistN++;
    if (vHistN == 10) {
      float d = vHist[9] - vHist[0];
      if (d >= CHG_RISE_V) charging = true;
      else if (d <= -CHG_FALL_V) charging = false;
    }
  }
  if (vbat >= CHG_TOP_V) charging = true;
  if (usbHost) charging = true;
  batCharging = batPresent && charging;
}

// Milliseconds since `then`, a millis() stamp another task may have taken
// just after we read the clock: never negative (unsigned it would wrap to
// ~49 days).
static inline uint32_t sinceMs(uint32_t then) {
  int32_t d = (int32_t)(millis() - then);
  return d > 0 ? (uint32_t)d : 0;
}

uint32_t localNow() {
  return day.localEpoch + sinceMs(dayRxMs) / 1000;
}

// Li-ion resting voltage → %, piecewise linear.
int batteryPercent(float v) {
  static const float V[] = {3.30f, 3.60f, 3.69f, 3.73f, 3.77f, 3.80f, 3.84f,
                            3.87f, 3.91f, 3.95f, 4.02f, 4.08f, 4.15f, 4.20f};
  static const int   P[] = {0, 5, 10, 18, 28, 38, 50, 58, 66, 74, 82, 90, 96, 100};
  if (v <= V[0]) return 0;
  for (int i = 1; i < 14; i++) {
    if (v <= V[i]) return P[i-1] + (int)((v - V[i-1]) / (V[i] - V[i-1]) * (P[i] - P[i-1]));
  }
  return 100;
}

/* ================= HELPERS ================= */
static inline float dot3(const float a[3], const float b[3]) {
  return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}
static inline void norm3(float a[3]) {
  float n = sqrtf(dot3(a, a));
  if (n > 1e-6f) { a[0] /= n; a[1] /= n; a[2] /= n; }
}

// stroke / tempo bookkeeping for the rep screen themes
float    strokeBase = 0;     // where the current (or last) stroke started
int8_t   strokeDir = 0;
float    lastRangeM = 0.30f; // travel of the last counted rep (0.30 until one)
uint32_t strokeStartMs = 0, strokePeakMs = 0;

void resetReps() {
  repBase = p; repPeak = 0; repDir = 0; lastDir = 0;
  strokeBase = p; strokeDir = 0; lastRangeM = 0.30f;
  strokeFrac = 0; phase = 0; tempoUpMs = tempoDownMs = 0;
}

void resetMotion() {
  aF = v = p = accEnv = 0;
  stillT = 0; zupt = false;
  segT = 0; vAtStill = 0; lastBottom = 0;
  resetReps();
}

void beginCalibration(uint32_t now) {
  state = ST_CALIB;
  calStartMs = now;
  calibReset(now);
  calBestAccStd = 99;
  calN = 0;
  for (int i = 0; i < 3; i++) { cSum[i] = 0; cGyro[i] = 0; }
  cMagSum = cMagSq = cGyroMag = 0;
  reps = 0;
  resetMotion();
}

/* ================= CONTROL (polled, callback-free) ================= */
void applyCommand(uint8_t cmd, uint32_t now) {
  switch (cmd) {
    case CMD_START: beginCalibration(now); break;
    case CMD_STOP:  state = ST_IDLE; resetMotion(); break;
    case CMD_ZERO:  if (state == ST_TRACK) { p = 0; v = 0; segT = 0; lastBottom = 0; resetReps(); }
                    break;
  }
}

void pollControl(uint32_t now) {
  if (!ctrlChar) return;
  auto val = ctrlChar->getValue();
  if (val.length() < 2) return;
  const uint8_t* d = (const uint8_t*)val.data();
  int seq = d[1];
  if (seq == lastSeq) return;          // already handled
  lastSeq = seq;
  applyCommand(d[0], now);
}

/* ================= USB TEST MODE ================= */
void handleSerialLine(const char* s, uint32_t now) {
  if (!strcmp(s, "TEST 1")) {
    testMode = true;
    state = ST_IDLE; resetMotion();
    Serial.println("V," FW_VERSION);
  } else if (!strcmp(s, "TEST 0")) {
    testMode = false;
    state = ST_IDLE; resetMotion();
  } else if (testMode && s[0] == 'C' && s[1] == ',') {
    int cmd = -1, seq = -1;
    if (sscanf(s + 2, "%d,%d", &cmd, &seq) == 2 && seq != lastSeq) {
      lastSeq = seq;
      applyCommand((uint8_t)cmd, now);
    }
  }
}

void pollSerial(uint32_t now) {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\r') continue;
    if (c == '\n') {
      serBuf[serLen] = 0;
      if (serLen) handleSerialLine(serBuf, now);
      serLen = 0;
    } else if (serLen < sizeof(serBuf) - 1) {
      serBuf[serLen++] = c;
    } else {
      serLen = 0;                      // overlong garbage: drop it
    }
  }
}

void sendHexLine(char tag, const void* data, size_t n) {
  static const char hx[] = "0123456789abcdef";
  char line[2 + 2 * sizeof(MotionPacket) + 2];
  size_t k = 0;
  line[k++] = tag; line[k++] = ',';
  const uint8_t* b = (const uint8_t*)data;
  for (size_t i = 0; i < n; i++) { line[k++] = hx[b[i] >> 4]; line[k++] = hx[b[i] & 15]; }
  line[k++] = '\n';
  Serial.write((const uint8_t*)line, k);
}

/* ================= CALIBRATION ================= */
void calibReset(uint32_t now) {
  calWinStartMs = now; calN = 0;
  for (int i = 0; i < 3; i++) { cSum[i] = 0; cGyro[i] = 0; cGyroSq[i] = 0; }
  cMagSum = cMagSq = cGyroMag = 0;
}

void calibStep(const float a[3], const float w[3], uint32_t now) {
  float mag = sqrtf(dot3(a, a));
  float wm  = sqrtf(dot3(w, w));
  for (int i = 0; i < 3; i++) {
    cSum[i] += a[i]; cGyro[i] += w[i]; cGyroSq[i] += (double)w[i] * w[i];
  }
  cMagSum += mag; cMagSq += (double)mag * mag; cGyroMag += wm;
  calN++;

  if (now - calWinStartMs < CALIB_WINDOW_MS) return;

  double mean = cMagSum / calN;
  double var  = cMagSq / calN - mean * mean;
  double std  = var > 0 ? sqrt(var) : 0;
  double gVar = 0, gMean[3];
  for (int i = 0; i < 3; i++) {
    gMean[i] = cGyro[i] / calN;
    double vi = cGyroSq[i] / calN - gMean[i] * gMean[i];
    if (vi > 0) gVar += vi;
  }
  double gStd  = sqrt(gVar);
  double gBiasMag = sqrt(gMean[0]*gMean[0] + gMean[1]*gMean[1] + gMean[2]*gMean[2]);

  if (std < calBestAccStd) {
    calBestAccMean = mean; calBestAccStd = std;
    calBestGyroDps = gBiasMag * RAD_TO_DEG; calBestGyroStdDps = gStd * RAD_TO_DEG;
  }
#if DEBUG_STREAM
  Serial.printf("calib n=%lu |a|=%.3f sd=%.3f gyro=%.2fdps sd=%.2fdps\n",
                (unsigned long)calN, mean, std, gBiasMag * RAD_TO_DEG, gStd * RAD_TO_DEG);
#endif

  bool still = calN > 50 && std < CALIB_ACC_STD && gStd < CALIB_GYRO_STD &&
               gBiasMag < CALIB_GYRO_MAX && mean > CALIB_G_MIN && mean < CALIB_G_MAX;
  if (still) {
    for (int i = 0; i < 3; i++) {
      up[i]    = (float)(cSum[i] / calN);   // accel at rest points "up"
      gBias[i] = (float)gMean[i];
    }
    gMag = sqrtf(dot3(up, up));
    norm3(up);
    resetMotion();
    state = ST_TRACK;
  } else if (now - calStartMs > CALIB_TIMEOUT_MS) {
    state = ST_CALIB_FAIL;               // app shows "keep still, retry"
  } else {
    calibReset(now);                     // not still enough — fresh window
  }
}

/* ================= TRACKING ================= */
void repStep();

void trackStep(const float a[3], float w[3], float dt) {
  for (int i = 0; i < 3; i++) w[i] -= gBias[i];

  // carry the world-fixed up axis through body rotation: du/dt = −ω × u
  float cx = w[1]*up[2] - w[2]*up[1];
  float cy = w[2]*up[0] - w[0]*up[2];
  float cz = w[0]*up[1] - w[1]*up[0];
  up[0] -= cx * dt; up[1] -= cy * dt; up[2] -= cz * dt;
  norm3(up);

  float mag = sqrtf(dot3(a, a));
  float wm  = sqrtf(dot3(w, w));

  // ---- ZUPT: still → velocity is exactly zero ----
  bool wasZupt = zupt;
  if (fabsf(mag - gMag) < ZUPT_ACC_TH && wm < ZUPT_GYRO_TH) {
    if (stillT == 0) vAtStill = v;     // speed when it went quiet
    stillT += dt;
  } else {
    stillT = 0;
  }
  zupt = stillT > ZUPT_TIME_S && (fabsf(v) < ZUPT_MAX_V || stillT > ZUPT_LONG_S);

  // ---- project onto the gravity axis ----
  float aUp = dot3(a, up) - gMag;
  aF += ACC_LPF * (aUp - aF);
  float aUse = fabsf(aF) < ACC_DEADBAND ? 0.0f : aF;
  accEnv = 0.9f * accEnv + 0.1f * fabsf(aF);

  if (zupt) {
    if (!wasZupt) {
      // The movement that just ended began and ended at rest, so the speed
      // left over is drift; it grew about evenly, so the position is off by
      // half its area (plus what it added while going quiet).
      if (segT > 0 && segT < MAX_SEG_S) p -= vAtStill * segT * 0.5f + v * ZUPT_TIME_S;
      if (fabsf(p - home) < HOME_SNAP) p = home;   // back on the pile
    }
    v = 0;
    segT = 0;
    lastBottom = p;
    // while still, gently re-anchor the axis and gyro bias to reality
    float an[3] = {a[0], a[1], a[2]};
    norm3(an);
    for (int i = 0; i < 3; i++) {
      up[i] += AXIS_REALIGN * (an[i] - up[i]);
      gBias[i] += BIAS_REFINE * w[i];
    }
    norm3(up);
    gMag += 0.01f * (mag - gMag);
  } else {
    float vBefore = v;
    v += aUse * dt;
    v *= expf(-VEL_LEAK * dt);
    segT += dt;
    if (vBefore < 0 && v >= 0 && segT > 0.3f) {
      // Bottom of a stroke with no rest (reps back to back): the stack comes
      // back to about where the last stroke started, so most of the gap is
      // drift, and so is the speed error that built it up since then.
      float e = p - lastBottom;
      if (fabsf(e) < BOTTOM_SNAP) {
        p -= BOTTOM_GAIN * e;
        v -= BOTTOM_GAIN * 2.0f * e / segT;
      }
      lastBottom = p;
      segT = 0;
    }
  }
  p += v * dt;
  vNow = v;
  repStep();
}

void repStep() {
  uint32_t nowMs = millis();
  phase = v > 0.05f ? 1 : (v < -0.05f ? -1 : 0);
  if (strokeDir != 0) {
    float f = (p - strokeBase) * strokeDir / fmaxf(lastRangeM, 0.05f);
    strokeFrac = f < 0 ? 0 : (f > 1 ? 1 : f);
  } else {
    strokeFrac = 0;
  }
  if (repDir == 0) {
    // Between reps the start point follows the stack: at rest, and while it
    // keeps travelling back after a counted rep (so the next rep starts from
    // the real turning point).
    float d = p - repBase;
    if (zupt) { repBase = p; lastDir = 0; }
    else if (lastDir != 0 && d * lastDir < 0) repBase = p;
    d = p - repBase;
    if (fabsf(d) >= REP_MIN_DISP) {
      repDir = d > 0 ? 1 : -1;
      repPeak = fabsf(d);
      strokeBase = repBase; strokeDir = repDir;
      // the stroke began when it left the start point, a moment ago
      strokeStartMs = nowMs - (uint32_t)(1000.0f * REP_MIN_DISP / fmaxf(fabsf(v), 0.05f));
      strokePeakMs = nowMs;
    }
    return;
  }
  float out = (p - repBase) * repDir;  // distance from the start, outwards
  if (out > repPeak) { repPeak = out; strokePeakMs = nowMs; }
  if (out <= (1.0f - REP_RETURN_FRAC) * repPeak) {
    reps = reps + 1;
    lastDir = repDir;
    repDir = 0;
    repBase = p;
    lastRangeM = repPeak;
    uint32_t upMs = strokePeakMs - strokeStartMs;
    // counted 60 % of the way back: the whole way down takes about 1/0.6 of it
    uint32_t downMs = (uint32_t)((nowMs - strokePeakMs) / REP_RETURN_FRAC);
    tempoUpMs = (uint16_t)(upMs > 60000 ? 60000 : upMs);
    tempoDownMs = (uint16_t)(downMs > 60000 ? 60000 : downMs);
  }
}

/* ================= DISPLAY (core 0) ================= */
// The panel is slow to fill (SPI), so every screen redraws only what changed:
// text is overwritten in place (padded to the old text's width), rings are
// extended or shortened by the changed arc, 7-segment digits change only the
// segments that switch, and a full clear happens only when the screen
// itself changes.
const bool segMap[10][7] = {
  {1,1,1,1,1,1,0},{0,1,1,0,0,0,0},{1,1,0,1,1,0,1},{1,1,1,1,0,0,1},
  {0,1,1,0,0,1,1},{1,0,1,1,0,1,1},{1,0,1,1,1,1,1},{1,1,1,0,0,0,0},
  {1,1,1,1,1,1,1},{1,1,1,1,0,1,1}
};
// The rep count, in the user's number style (…cdefd byte 2):
//   0 Segment          sharp 7-segment digits
//   1 Rounded segment  7-segment digits with rounded, anti-aliased bars
//   2 Bold             Roboto Bold
//   3 Light            Roboto Regular
// Always centred on its point whatever the number of digits; 4 digits drop
// to the smaller size so they stay inside the ring.
const uint8_t     NUM_STYLE_COUNT = 4;
volatile uint8_t  numStyle = 0;

void segRect(int k, int x, int y, int s, int& rx, int& ry, int& rw, int& rh) {
  int w = 6 * s, h = s, vv = 7 * s;
  switch (k) {
    case 0: rx = x + h;     ry = y;              rw = w; rh = h;  break;
    case 1: rx = x + w + h; ry = y + h;          rw = h; rh = vv; break;
    case 2: rx = x + w + h; ry = y + vv + 2 * h; rw = h; rh = vv; break;
    case 3: rx = x + h;     ry = y + 2 * vv + 2 * h; rw = w; rh = h; break;
    case 4: rx = x;         ry = y + vv + 2 * h; rw = h; rh = vv; break;
    case 5: rx = x;         ry = y + h;          rw = h; rh = vv; break;
    default: rx = x + h;    ry = y + vv + h;     rw = w; rh = h;  break;
  }
}

void fillSegment(int k, int x, int y, int s, uint16_t c, bool round) {
  int rx, ry, rw, rh;
  segRect(k, x, y, s, rx, ry, rw, rh);
  if (c == TFT_BLACK) { gfx->fillRect(rx, ry, rw, rh, c); return; }
  if (round) {               // a hair of gap along the bar so ends stay round
    if (k == 0 || k == 3 || k == 6) { rx += 1; rw -= 2; } else { ry += 1; rh -= 2; }
  }
  if (!round) gfx->fillRect(rx, ry, rw, rh, c);
  else gfx->fillSmoothRoundRect(rx, ry, rw, rh, s / 2, c, TFT_BLACK);
}

void segBox(int len, int s, int cx, int cy, int& x, int& y, int& w, int& h) {
  int dw = 8 * s, sp = 2 * s;
  w = len * dw + (len - 1) * sp;
  h = 17 * s;
  x = cx - w / 2; y = cy - h / 2;
}

// What the count currently shows (reset when its screen is drawn fresh).
struct CountView {
  char shown[8];
  uint16_t color;
  int8_t s;                 // segment size, 0 = not segments
  const SPFont* font;       // font, null = not text
  int cx, cy;
};
CountView cv;
void countReset() { memset(&cv, 0, sizeof cv); }

// Draws (c) or erases (black) the lit segments of `str` at its box.
void segDigits(const char* str, int s, int cx, int cy, uint16_t c, bool round) {
  int x, y, w, h;
  segBox(strlen(str), s, cx, cy, x, y, w, h);
  for (; *str; str++, x += 10 * s)
    for (int k = 0; k < 7; k++)
      if (segMap[*str - '0'][k]) fillSegment(k, x, y, s, c, round);
}

// Remove whatever the count drew last (only its own pixels: the ring
// around it stays).
void countClear() {
  if (!cv.shown[0]) return;
  if (cv.s) {
    segDigits(cv.shown, cv.s, cv.cx, cv.cy, TFT_BLACK, false);
  } else if (cv.font) {
    int w = textW(*cv.font, cv.shown), h = textH(*cv.font);
    gfx->fillRect(cv.cx - w / 2, cv.cy - h / 2, w, h, TFT_BLACK);
  }
  cv.shown[0] = 0;
}

// Centre on the ink, not on the digit cells: a 7-segment "1" lights only
// its cell's right edge, and a font's "1" sits off-centre in its cell, so a
// count starting or ending in 1 would otherwise look pushed aside.
int segInkShift(const char* str, int s) {
  return str[0] == '1' ? (7 * s) / 2 : 0;       // its ink starts 7s into the cell
}
int fontInkShift(const SPFont& f, const char* str) {
  int len = strlen(str);
  const SPGlyph* g0 = findGlyph(f, str[0]);
  const SPGlyph* g1 = findGlyph(f, str[len - 1]);
  if (!g0 || !g1) return 0;
  int W = textW(f, str);
  int inkL = g0->dx, inkR = W - g1->adv + g1->dx + g1->w;
  return (inkL + inkR) / 2 - W / 2;
}

void drawCount(int n, int cx, int cy, bool large, uint16_t c, uint8_t style) {
  char str[8];
  snprintf(str, sizeof str, "%d", n < 0 ? 0 : n);
  int len = strlen(str);
  bool many = len >= 4;
  if (style <= 1) {
    int s = large ? (many ? 4 : 6) : (many ? 2 : 3);
    int ecx = cx - segInkShift(str, s);
    bool round = style == 1;
    // a new size, digit count or position: erase and draw it whole
    if (cv.font || cv.s != s || strlen(cv.shown) != (size_t)len || cv.cx != ecx || cv.cy != cy)
      countClear();
    if (!cv.shown[0]) {
      segDigits(str, s, ecx, cy, c, round);
    } else {                // same layout: switch only the segments that change
      int x, y, w, h;
      segBox(len, s, ecx, cy, x, y, w, h);
      for (int i = 0; i < len; i++, x += 10 * s) {
        int nd = str[i] - '0', od = cv.shown[i] - '0';
        for (int k = 0; k < 7; k++) {
          bool on = segMap[nd][k], was = segMap[od][k];
          if (on && (!was || c != cv.color)) fillSegment(k, x, y, s, c, round);
          else if (!on && was) fillSegment(k, x, y, s, TFT_BLACK, round);
        }
      }
    }
    cv.font = nullptr; cv.s = s; cv.cx = ecx; cv.cy = cy;
  } else {
    const SPFont* f = style == 2 ? (large && !many ? &NUM_BOLD_L : &FONT_BIG)
                                 : (large && !many ? &NUM_LIGHT_L : &NUM_LIGHT_S);
    int ecx = cx - fontInkShift(*f, str);
    if (cv.s || cv.font != f || cv.cx != ecx || cv.cy != cy) countClear();
    if (strcmp(cv.shown, str) != 0 || c != cv.color)
      drawText(*f, str, ecx, cy, c, true, cv.shown[0] ? textW(*f, cv.shown) : 0);
    cv.s = 0; cv.font = f; cv.cx = ecx; cv.cy = cy;
  }
  strcpy(cv.shown, str);
  cv.color = c;
}

// Text with subpixel anti-aliasing (tracker_fonts.h): each pixel carries a
// coverage for its left, middle and right colour stripe, so glyph edges are
// placed at a third of a pixel. The panel's stripes run, left to right:
//   0 = R G B,  1 = B G R,  2 = no subpixels (plain greyscale smoothing)
// TFT_eSPI drives the GC9A01 at rotation 0 with MADCTL BGR (colours only
// come out right that way), i.e. the panel's stripes are B, G, R.
#ifndef SUBPIXEL_ORDER
#define SUBPIXEL_ORDER 1
#endif

const SPGlyph* findGlyph(const SPFont& f, char ch) {
  for (uint16_t i = 0; i < f.count; i++)
    if (f.glyphs[i].code == (uint8_t)ch) return &f.glyphs[i];
  return nullptr;
}

int textW(const SPFont& f, const char* s) {
  int w = 0;
  for (; *s; s++) { const SPGlyph* g = findGlyph(f, *s); if (g) w += g->adv; }
  return w;
}

int textH(const SPFont& f) { return f.asc + f.desc; }

// Draws `s` on black in one block write (no flicker): centred on cx
// (centre = true) or starting at cx, vertically centred on cy. The block is
// at least padW wide, so the old, longer text is overwritten too.
void drawText(const SPFont& f, const char* s, int cx, int cy, uint16_t fg,
              bool centre, int padW) {
  int W = textW(f, s), H = textH(f);
  int bw = max(W, padW);
  if (bw <= 0 || H <= 0) return;
  int x0 = centre ? cx - bw / 2 : cx, y0 = cy - H / 2;
  uint16_t* buf = (uint16_t*)calloc(bw * H, sizeof(uint16_t));
  if (!buf) return;
  int r5 = fg >> 11, g6 = (fg >> 5) & 63, b5 = fg & 31;
  int pen = centre ? (bw - W) / 2 : 0;
  for (; *s; s++) {
    const SPGlyph* g = findGlyph(f, *s);
    if (!g) continue;
    const uint8_t* d = f.data + g->off;
    const int ch = f.ch;               // 3 = subpixel stripes, 1 = greyscale
    int gx = pen + g->dx, gy = f.asc - g->dy;
    for (int j = 0; j < g->h; j++) {
      int y = gy + j;
      if (y < 0 || y >= H) { d += ch * g->w; continue; }
      for (int i = 0; i < g->w; i++, d += ch) {
        int x = gx + i;
        int aR, aG, aB;
        if (ch == 1) {
          if (!d[0]) continue;
          aR = aG = aB = d[0];
        } else {
          if ((d[0] | d[1] | d[2]) == 0) continue;
#if SUBPIXEL_ORDER == 0
          aR = d[0]; aG = d[1]; aB = d[2];
#elif SUBPIXEL_ORDER == 1
          aR = d[2]; aG = d[1]; aB = d[0];
#else
          aR = aG = aB = (d[0] + d[1] + d[2]) / 3;
#endif
        }
        if (x < 0 || x >= bw) continue;
        uint16_t* p = &buf[y * bw + x];
        // glyphs may touch: keep the brighter value per channel
        int r = max((int)(*p >> 11), (r5 * aR + 127) / 255);
        int gg = max((int)((*p >> 5) & 63), (g6 * aG + 127) / 255);
        int b = max((int)(*p & 31), (b5 * aB + 127) / 255);
        *p = (r << 11) | (gg << 5) | b;
      }
    }
    pen += g->adv;
  }
  // pushImage is not virtual: call the page's own when drawing off-screen
  if (gfxPage) {
    bool swap = gfxPage->getSwapBytes();
    gfxPage->setSwapBytes(true);
    gfxPage->pushImage(x0, y0, bw, H, buf);
    gfxPage->setSwapBytes(swap);
  } else {
    bool swap = tft.getSwapBytes();
    tft.setSwapBytes(true);
    tft.pushImage(x0, y0, bw, H, buf);
    tft.setSwapBytes(swap);
  }
  free(buf);
}

void say(const SPFont& f, const char* s, int x, int y, uint16_t fg) {
  drawText(f, s, x, y, fg, true, 0);
}

// Text at (x, y), middle-centre, replacing `shown` without clearing more
// than the old text covered. Returns true when it drew.
bool textDelta(char* shown, size_t cap, const char* now, int x, int y,
               const SPFont& f, uint16_t fg) {
  if (strcmp(shown, now) == 0) return false;
  drawText(f, now, x, y, fg, true, shown[0] ? textW(f, shown) : 0);
  strncpy(shown, now, cap - 1);
  shown[cap - 1] = 0;
  return true;
}

/* ================= IDLE DASHBOARD ================= */
// Between sets: today at a glance. Outer ring = reps against the daily goal,
// inner ring = muscle groups worked; battery and clock on top; sets, weight
// and this week's days below.
const uint16_t COL_GREEN  = 0x07F1;   // app neon green #00FF88
const uint16_t COL_BLUE   = 0x3D9F;
const uint16_t COL_ORANGE = 0xFC47;   // #FF8A3D
// Greys are tinted towards the accents so the screen reads as one palette
// (and RGB565, with its finer green, has no exact neutral grey anyway).
const uint16_t COL_TRACK  = 0x0968;   // ring background: deep blue-slate #082C41
const uint16_t COL_MUTED  = 0x6499;   // secondary text: blue-grey #6291CD
const uint16_t COL_MUTED_G = 0x6D91;  // clock: green-grey #6AB28B
const uint16_t COL_DOT_OFF = 0x22AE;  // empty week dots: blue-grey #205573
const uint32_t RING_A0 = 40, RING_SPAN = 280;   // gap at the bottom

// What the dashboard currently shows; valid = false redraws it all.
struct DashView {
  bool valid;
  bool synced;
  uint32_t ringOut, ringIn;         // end angle of each ring's fill
  int8_t bat; bool batPresent, charging, connected, linkDrawn;
  char top[24], big[8], goal[16], l1[24], l2[24], l3[32];
  uint8_t dots; int8_t today;
};
DashView dv;

uint32_t ringEnd(float frac) {
  if (frac <= 0.005f) return RING_A0;
  return RING_A0 + (uint32_t)(RING_SPAN * fminf(frac, 1.0f));
}

// Move a ring's fill from its old end angle to the new one: only the arc in
// between is painted.
void ringDelta(int r, int ir, uint32_t& shown, uint32_t now, uint16_t fg) {
  if (now == shown) return;
  // drawArc: smooth sides, square ends, so the pieces join without a seam
  if (now > shown) gfx->drawArc(120, 120, r, ir, shown, now, fg, TFT_BLACK, true);
  else gfx->drawArc(120, 120, r, ir, now, shown, COL_TRACK, TFT_BLACK, true);
  shown = now;
}

// Battery row, centred: icon then text. Clears only what it drew last time
// (the strip sits between the rings' top ends; layout checked in
// tools/check_tracker_layout.py).
// The icon holds BAT_BLOCKS blocks. Charging: the blocks above the charge
// already in the cell light up one after another and start again, like a
// phone; only the block that changes is repainted.
const int BAT_BLOCKS = 4, BAT_W = 25, BAT_H = 13;
int      batLeft = 0, batRight = 0;   // the battery row as drawn last
int      batX = 0, batY = 0;          // icon position
uint8_t  batLit = 0;                  // blocks lit now (bit mask)
uint16_t batLitColor = 0;

void batBlock(int i, uint16_t c) {
  int bw = (BAT_W - 6 - (BAT_BLOCKS - 1)) / BAT_BLOCKS;   // 1 px gaps
  gfx->fillRect(batX + 3 + i * (bw + 1), batY + 3, bw, BAT_H - 6, c);
}

uint16_t batColor() {
  int pct = batPct;
  return !batPresent || pct < 0 ? COL_MUTED
       : batCharging || pct > 50 ? COL_GREEN : pct > 20 ? TFT_YELLOW : TFT_RED;
}

// Blocks to show now: the charge, plus the running charge animation.
uint8_t batMask(uint32_t ms) {
  int pct = batPct;
  if (!batPresent || pct <= 0) return 0;
  int full = (pct * BAT_BLOCKS + BAT_BLOCKS - 1) / 100;     // round up: 1% = 1
  if (full > BAT_BLOCKS) full = BAT_BLOCKS;
  if (batCharging && pct < 100) {
    int base = pct * BAT_BLOCKS / 100;                      // fully charged ones
    int steps = BAT_BLOCKS - base + 1;                      // … then 1, 2, … more
    full = base + (int)((ms / 450) % steps);
  }
  uint8_t m = 0;
  for (int i = 0; i < full; i++) m |= 1 << i;
  return m;
}

// Outline and percentage: drawn when the value changes.
void drawBattery(int cy) {
  int pct = batPct;
  char txt[8];
  if (!batPresent) snprintf(txt, sizeof txt, "USB");
  else if (pct < 0) snprintf(txt, sizeof txt, "--%%");
  else snprintf(txt, sizeof txt, "%d%%", pct);
  uint16_t c = batColor();
  const int gap = 5;
  int total = BAT_W + 2 + gap + textW(FONT_TINY, txt);
  int x = 120 - total / 2;
  if (batRight > batLeft) gfx->fillRect(batLeft, cy - 8, batRight - batLeft, 17, TFT_BLACK);
  batLeft = x; batRight = x + total + 1;
  batX = x; batY = cy - BAT_H / 2;
  gfx->drawSmoothRoundRect(batX, batY, 3, 2, BAT_W, BAT_H, TFT_WHITE, TFT_BLACK);
  gfx->fillSmoothRoundRect(batX + BAT_W, batY + 4, 3, 5, 1, TFT_WHITE, TFT_BLACK);
  batLit = 0;                          // blocks drawn fresh below
  batLitColor = c;
  drawText(FONT_TINY, txt, x + BAT_W + 2 + gap, cy, c, false, 0);
}

// Blocks: repaint only those that switch (or all on a colour change).
void updateBatteryBlocks(uint32_t ms) {
  uint8_t want = batMask(ms);
  uint16_t c = batColor();
  for (int i = 0; i < BAT_BLOCKS; i++) {
    bool on = want & (1 << i), was = batLit & (1 << i);
    if (on && (!was || c != batLitColor)) batBlock(i, c);
    else if (!on && was) batBlock(i, TFT_BLACK);
  }
  batLit = want;
  batLitColor = c;
}

const int DOT_Y = 196;
void dashDot(int i, bool on, bool today) {
  int x = 120 + (i - 3) * 15;
  gfx->fillRect(x - 8, DOT_Y - 8, 17, 17, TFT_BLACK);
  if (today) gfx->drawSmoothCircle(x, DOT_Y, 7, TFT_WHITE, TFT_BLACK);
  if (on) gfx->fillSmoothCircle(x, DOT_Y, 5, COL_ORANGE, TFT_BLACK);
  else gfx->drawSmoothCircle(x, DOT_Y, 4, COL_DOT_OFF, TFT_BLACK);
}

void updateDashboard() {
  static const char* DAYS[] = {"Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"};
  bool synced = dayValid;
  if (dv.valid && dv.synced != synced) dv.valid = false;   // layout changes
  if (!dv.valid) {
    gfx->fillScreen(TFT_BLACK);
    memset(&dv, 0, sizeof dv);
    dv.bat = -2;
    dv.today = -2;
    dv.ringOut = dv.ringIn = RING_A0;
    gfx->drawSmoothArc(120, 120, 118, 108, RING_A0, RING_A0 + RING_SPAN, COL_TRACK, TFT_BLACK, true);
    gfx->drawSmoothArc(120, 120, 104, 98, RING_A0, RING_A0 + RING_SPAN, COL_TRACK, TFT_BLACK, true);
    batLeft = batRight = 0;
    dv.valid = true;
    dv.synced = synced;
  }

  // Today's numbers; a new day (or week) starts them from zero.
  uint16_t reps = 0, sets = 0, goal = 60, mAct = 0, mTot = 13;
  uint32_t kg = 0;
  uint8_t weekMask = 0, daysWeek = 0, weekGoal = 3, streak = 0;
  bool clock = clockValid;
  if (synced) {
    reps = day.reps; sets = day.sets; kg = day.volumeKg;
    goal = day.repGoal ? day.repGoal : 60;
    mAct = day.musclesActive; mTot = day.musclesTotal ? day.musclesTotal : 13;
    weekMask = day.weekMask; daysWeek = day.daysThisWeek;
    weekGoal = day.weekGoal ? day.weekGoal : 3; streak = day.weekStreak;
    if (clock) {
      uint32_t d0 = day.localEpoch / 86400, d1 = localNow() / 86400;
      if (d1 != d0) {
        reps = sets = mAct = 0; kg = 0;
        // 1 Jan 1970 was a Thursday: Monday-based week = (d + 3) / 7
        if ((d1 + 3) / 7 != (d0 + 3) / 7) { weekMask = 0; daysWeek = 0; }
      }
    }
  }

  ringDelta(118, 108, dv.ringOut, synced && goal ? ringEnd((float)reps / goal) : RING_A0, COL_GREEN);
  ringDelta(104, 98, dv.ringIn, synced && mTot ? ringEnd((float)mAct / mTot) : RING_A0, COL_BLUE);

  if (dv.bat != (int8_t)batPct || dv.batPresent != batPresent || dv.charging != batCharging) {
    drawBattery(44);
    dv.bat = (int8_t)batPct; dv.batPresent = batPresent; dv.charging = batCharging;
  }
  updateBatteryBlocks(millis());
  bool connected = bleServer && bleServer->getConnectedCount() > 0;
  if (connected != dv.connected || !dv.linkDrawn) {
    // app link: a dot at the top, between the rings' ends
    gfx->fillSmoothCircle(120, 30, 3, connected ? COL_GREEN : COL_DOT_OFF, TFT_BLACK);
    dv.connected = connected;
    dv.linkDrawn = true;
  }

  uint32_t t = clock ? localNow() : day.localEpoch;
  int wd = (int)((t / 86400 + 3) % 7);              // 0 = Monday
  char line[32];
  if (clock) snprintf(line, sizeof line, "%s  %02lu:%02lu", DAYS[wd],
                      (unsigned long)(t / 3600 % 24), (unsigned long)(t / 60 % 60));
  else if (synced) snprintf(line, sizeof line, "last sync: %s", DAYS[wd]);
  else snprintf(line, sizeof line, "Gympath");
  textDelta(dv.top, sizeof dv.top, line, 120, 66, FONT_SMALL, COL_MUTED_G);

  if (!synced) {
    textDelta(dv.l1, sizeof dv.l1, "READY", 120, 112, FONT_MED, TFT_WHITE);
    textDelta(dv.l2, sizeof dv.l2, "open the app to sync", 120, 145, FONT_SMALL, COL_MUTED);
    return;
  }

  snprintf(line, sizeof line, "%u", reps);
  textDelta(dv.big, sizeof dv.big, line, 120, 106, FONT_BIG, TFT_WHITE);
  snprintf(line, sizeof line, "reps / %u", goal);
  textDelta(dv.goal, sizeof dv.goal, line, 120, 138, FONT_SMALL, COL_GREEN);
  if (kg >= 1000) snprintf(line, sizeof line, "%u sets  %.1f t", sets, kg / 1000.0f);
  else snprintf(line, sizeof line, "%u sets  %lu kg", sets, (unsigned long)kg);
  textDelta(dv.l1, sizeof dv.l1, line, 120, 157, FONT_SMALL, TFT_WHITE);
  snprintf(line, sizeof line, "muscles %u/%u", mAct, mTot);
  textDelta(dv.l2, sizeof dv.l2, line, 120, 176, FONT_SMALL, COL_BLUE);

  // this week: Monday … Sunday, only the dots that changed
  int8_t today = clock ? wd : -1;
  for (int i = 0; i < 7; i++) {
    bool on = weekMask & (1 << i), was = dv.dots & (1 << i);
    bool isToday = i == today, wasToday = i == dv.today;
    if (on != was || isToday != wasToday || dv.today == -2) dashDot(i, on, isToday);
  }
  dv.dots = weekMask; dv.today = today;
  snprintf(line, sizeof line, "%u/%u - %u wk streak", daysWeek, weekGoal, streak);
  // colour flips when the week's goal is met: redraw the line then
  static bool metShown = false;
  bool met = daysWeek >= weekGoal;
  if (met != metShown) { dv.l3[0] = 0; metShown = met; }
  textDelta(dv.l3, sizeof dv.l3, line, 120, 215, FONT_TINY, met ? COL_GREEN : COL_MUTED);
}

/* ================= REP SCREEN THEMES ================= */
// What a theme last drew (reset when the screen is drawn fresh).
struct RepView {
  char     word[12];      // Tempo: LIFT / LOWER / HOLD
  char     tempo[32];     // Tempo: last rep's times
  uint32_t ringEnd;       // Stroke: end angle of the fill
  uint16_t ringCol;       // Stroke / Tempo: colour of the fill / ring
  int      dots;          // Minimal: dots drawn
};
RepView rv;

uint16_t phaseColor(int8_t ph) {
  return ph > 0 ? COL_GREEN : ph < 0 ? COL_BLUE : COL_MUTED_G;
}

void themeFresh(uint8_t th) {
  memset(&rv, 0, sizeof rv);
  rv.ringEnd = RING_A0;
  switch (th) {
    case 1:   // Stroke: an open ring that fills with the stack's travel
      gfx->drawSmoothArc(120, 120, 118, 104, RING_A0, RING_A0 + RING_SPAN, COL_TRACK, TFT_BLACK, true);
      say(FONT_SMALL, "reps", 120, 150, COL_MUTED);
      break;
    case 2:   // Tempo: a thin ring in the phase colour
      gfx->drawSmoothArc(120, 120, 118, 112, 0, 360, COL_TRACK, TFT_BLACK, false);
      rv.ringCol = COL_TRACK;
      say(FONT_TINY, "last rep", 120, 186, COL_MUTED);
      break;
    default:
      break;
  }
}

void themeStroke(const RepIn& in) {
  drawCount(in.reps, 120, 112, false, TFT_WHITE, in.style);
  uint32_t end = ringEnd(in.frac);
  end -= (end - RING_A0) % 2;                       // 2° steps
  uint16_t c = phaseColor(in.phase);
  if (c != rv.ringCol && end > RING_A0) {           // new phase: recolour the fill
    gfx->drawArc(120, 120, 118, 104, RING_A0, end, c, TFT_BLACK, true);
    if (rv.ringEnd > end)
      gfx->drawArc(120, 120, 118, 104, end, rv.ringEnd, COL_TRACK, TFT_BLACK, true);
    rv.ringEnd = end;
  } else {
    ringDelta(118, 104, rv.ringEnd, end, c);
  }
  rv.ringCol = c;
}

void themeTempo(const RepIn& in) {
  int8_t ph = in.phase;
  uint16_t c = phaseColor(ph);
  if (c != rv.ringCol) {
    gfx->drawSmoothArc(120, 120, 118, 112, 0, 360, c, TFT_BLACK, false);
    rv.ringCol = c;
  }
  textDelta(rv.word, sizeof rv.word, ph > 0 ? "LIFT" : ph < 0 ? "LOWER" : "HOLD", 120, 62, FONT_MED, c);
  drawCount(in.reps, 120, 118, false, TFT_WHITE, in.style);
  char line[32];
  if (in.upMs || in.downMs)
    snprintf(line, sizeof line, "up %.1fs  down %.1fs", in.upMs / 1000.0f, in.downMs / 1000.0f);
  else
    snprintf(line, sizeof line, "up -  down -");
  textDelta(rv.tempo, sizeof rv.tempo, line, 120, 166, FONT_SMALL, TFT_WHITE);
}

void themeMinimal(const RepIn& in) {
  drawCount(in.reps, 120, 120, true, TFT_WHITE, in.style);
  int want = in.reps > 30 ? 30 : in.reps;                       // one dot per rep, 12° apart
  for (; rv.dots < want; rv.dots++) {
    float a = rv.dots * 12.0f * DEG_TO_RAD;
    gfx->fillSmoothCircle(120 + (int)roundf(108 * sinf(a)), 120 - (int)roundf(108 * cosf(a)),
                         4, COL_GREEN, TFT_BLACK);
  }
}

// Classic: the ring repaints only when its colour changes (one arc).
void themeClassic(const RepIn& in, bool count) {
  if (in.speedCol != rv.ringCol) {
    gfx->drawSmoothArc(120, 120, 119, 105, 0, 360, in.speedCol, TFT_BLACK, false);
    rv.ringCol = in.speedCol;
  }
  if (count) drawCount(in.reps, 120, 120, true, in.speedCol, in.style);
}

void themeDraw(uint8_t th, const RepIn& in) {
  switch (th) {
    case 1:  themeStroke(in); break;
    case 2:  themeTempo(in); break;
    case 3:  themeMinimal(in); break;
    default: themeClassic(in, true); break;
  }
}

/* ================= LIVE PREVIEW (the app's theme / number carousels) ======= */
// While the app's Tracker screen is open it streams where its carousels
// stand: [2, axis, pos u16 LE] on …cdefd, pos = page × 256 (axis 0 = themes,
// 1 = number styles), and [3] when it closes. The rep screen is shown with
// sample numbers and follows the finger: themes slide sideways, the count
// slides up and down. Every page is rendered once into PSRAM; a frame is
// then only copied out of two pages, so the motion runs at the panel's
// speed (a full frame is ~12 ms at 80 MHz SPI, the count window ~3 ms).
volatile bool     previewActive = false;
volatile uint32_t previewMsgMs = 0;
volatile uint8_t  previewAxis = 0;
volatile uint16_t previewPos = 0;          // page × 256
const uint32_t    PREVIEW_HOLD_MS = 6000;  // app keep-alive every 2 s

const int PAGE_SLOTS = 8;                  // 8 × 115 KB of the 2 MB PSRAM
PageSlot pageSlot[PAGE_SLOTS];
int pageCount = 0;                         // slots allocated
bool pageFull = false;                     // no more memory for slots

void previewSample(RepIn& in, uint8_t style) {
  in.reps = 12; in.frac = 0.62f; in.phase = 1;
  in.upMs = 1200; in.downMs = 2400;
  in.speedCol = 0x07E0;                    // mid speed: green
  in.style = style;
}

// A rep screen with sample numbers on gfx (the panel or a page).
void drawRepPage(uint8_t th, uint8_t style) {
  RepIn in;
  previewSample(in, style);
  gfx->fillRect(0, 0, 240, 240, TFT_BLACK);
  countReset();
  themeFresh(th);
  themeDraw(th, in);
}

// The cached page for (theme, style), rendering it if needed; null when
// there is no PSRAM for it. `keep` (a slot) is never evicted.
PageSlot* findPage(int th, int st) {
  for (int i = 0; i < pageCount; i++)
    if (pageSlot[i].th == th && pageSlot[i].st == st) return &pageSlot[i];
  return nullptr;
}
PageSlot* getPage(int th, int st, const PageSlot* keep) {
  PageSlot* p = findPage(th, st);
  if (!p) {
    if (pageCount < PAGE_SLOTS && !pageFull && psramFound()) {
      TFT_eSprite* spr = new TFT_eSprite(&tft);
      spr->setColorDepth(16);
      if (spr->createSprite(240, 240)) {
        p = &pageSlot[pageCount++];
        p->spr = spr;
      } else {
        delete spr;
        pageFull = true;
      }
    }
    if (!p) {                              // reuse the least recently used
      for (int i = 0; i < pageCount; i++)
        if (&pageSlot[i] != keep && (!p || pageSlot[i].used < p->used)) p = &pageSlot[i];
      if (!p) return nullptr;
    }
    p->th = th; p->st = st;
    gfx = p->spr; gfxPage = p->spr;
    drawRepPage(th, st);
    gfx = &tft; gfxPage = nullptr;
  }
  p->used = millis();
  return p;
}

// Where the count can be, for the vertical slide: the union of its boxes in
// every style (sample count), so the window never takes in other text.
void countWindow(uint8_t th, int& wx, int& wy, int& ww, int& wh) {
  int cy = th == 1 ? 112 : th == 2 ? 118 : 120;
  bool large = th == 0 || th == 3;
  const char* str = "12";
  int x0 = 240, y0 = 240, x1 = 0, y1 = 0;
  for (uint8_t st = 0; st < NUM_STYLE_COUNT; st++) {
    int x, y, w, h;
    if (st <= 1) {
      int sz = large ? 6 : 3;
      segBox(strlen(str), sz, 120 - segInkShift(str, sz), cy, x, y, w, h);
    } else {
      const SPFont* f = st == 2 ? (large ? &NUM_BOLD_L : &FONT_BIG) : (large ? &NUM_LIGHT_L : &NUM_LIGHT_S);
      w = textW(*f, str); h = textH(*f);
      x = 120 - fontInkShift(*f, str) - w / 2; y = cy - h / 2;
    }
    x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x + w); y1 = max(y1, y + h);
  }
  wx = max(0, x0 - 1); wy = max(0, y0 - 1);
  ww = min(240, x1 + 1) - wx; wh = min(240, y1 + 1) - wy;
}

static uint16_t stripBuf[240 * 16];        // internal RAM: one strip on its way out

void pushStrip(int x, int y, int w, int h) {
  bool swap = tft.getSwapBytes();
  tft.setSwapBytes(false);                 // pages hold panel byte order already
  tft.pushImage(x, y, w, h, stripBuf);
  tft.setSwapBytes(swap);
}

// Themes: page A moved left by `off` px, page B following on its right.
void slideH(const uint16_t* A, const uint16_t* B, int off) {
  for (int y0 = 0; y0 < 240; y0 += 16) {
    for (int j = 0; j < 16; j++) {
      uint16_t* d = stripBuf + j * 240;
      int y = y0 + j;
      if (off < 240) memcpy(d, A + y * 240 + off, (240 - off) * 2);
      if (off > 0) {
        if (B) memcpy(d + 240 - off, B + y * 240, off * 2);
        else memset(d + 240 - off, 0, off * 2);
      }
    }
    pushStrip(0, y0, 240, 16);
  }
}

// Numbers: inside the count's window, A moved up by `off` px, B below it.
void slideV(const uint16_t* A, const uint16_t* B, int off, int wx, int wy, int ww, int wh) {
  int rows = (240 * 16) / ww;
  for (int r0 = 0; r0 < wh; r0 += rows) {
    int h = min(rows, wh - r0);
    for (int j = 0; j < h; j++) {
      int src = r0 + j + off;
      const uint16_t* S = src < wh ? A + (wy + src) * 240 + wx
                        : B ? B + (wy + src - wh) * 240 + wx : nullptr;
      if (S) memcpy(stripBuf + j * ww, S, ww * 2);
      else memset(stripBuf + j * ww, 0, ww * 2);
    }
    pushStrip(wx, wy + r0, ww, h);
  }
}

// One preview frame. Returns true while it is moving (draw again soon).
struct PreviewView {
  bool   fresh;                  // nothing of the preview on the panel yet
  int8_t axis, baseTh, baseSt;   // what is shown
  int    a, off;
  float  pos;                    // smoothed position, in pages
  uint32_t lastMs;
};
PreviewView pvw;

bool previewFrame() {
  uint32_t now = millis();
  uint8_t axis = previewAxis;
  uint8_t n = axis ? NUM_STYLE_COUNT : THEME_COUNT;
  float target = fminf(previewPos / 256.0f, n - 1);
  int baseTh = repTheme, baseSt = numStyle;
  // a new carousel, or the other one's setting changed: jump, redraw whole
  bool jump = pvw.fresh || axis != pvw.axis ||
              (axis == 0 && baseSt != pvw.baseSt) || (axis == 1 && baseTh != pvw.baseTh);
  if (jump) {
    pvw.pos = target;
  } else {                       // follow the finger smoothly between packets
    float dt = (now - pvw.lastMs) / 1000.0f;
    float k = 1.0f - expf(-dt / 0.035f);
    pvw.pos += (target - pvw.pos) * k;
    if (fabsf(target - pvw.pos) < 0.002f) pvw.pos = target;
  }
  pvw.lastMs = now;
  int a = (int)floorf(pvw.pos);
  if (a < 0) a = 0;
  if (a > n - 1) a = n - 1;
  float frac = a >= n - 1 ? 0 : pvw.pos - a;

  PageSlot* pa = axis ? getPage(baseTh, a, nullptr) : getPage(a, baseSt, nullptr);
  if (!pa) {                     // no PSRAM: no slide, show the nearest page
    int nearest = (int)roundf(pvw.pos);
    if (jump || nearest != pvw.a) {
      if (axis) drawRepPage(baseTh, nearest); else drawRepPage(nearest, baseSt);
      pvw.a = nearest;
    }
    pvw.fresh = false; pvw.axis = axis; pvw.baseTh = baseTh; pvw.baseSt = baseSt;
    return false;
  }
  PageSlot* pb = nullptr;
  if (frac > 0) pb = axis ? getPage(baseTh, a + 1, pa) : getPage(a + 1, baseSt, pa);
  const uint16_t* A = (const uint16_t*)pa->spr->getPointer();
  const uint16_t* B = pb ? (const uint16_t*)pb->spr->getPointer() : nullptr;

  int wx = 0, wy = 0, ww = 240, wh = 240;
  if (axis) countWindow(baseTh, wx, wy, ww, wh);
  int off = (int)roundf(frac * (axis ? wh : 240));
  bool moved = jump || a != pvw.a || off != pvw.off;
  if (moved) {
    if (axis == 0) slideH(A, B, off);
    else {
      if (jump) slideH(A, nullptr, 0);   // the rest of the screen, once
      slideV(A, B, off, wx, wy, ww, wh);
    }
  }
  pvw.fresh = false; pvw.axis = axis; pvw.baseTh = baseTh; pvw.baseSt = baseSt;
  pvw.a = a; pvw.off = off;
  if (!moved && pvw.pos == target) {
    // still: get the neighbours ready so the next swipe starts at once
    const int want[2] = {a + 1, a - 1};
    for (int i : want) {
      if (i < 0 || i >= n) continue;
      bool cached = axis ? findPage(baseTh, i) : findPage(i, baseSt);
      if (!cached && (pageCount < PAGE_SLOTS && !pageFull)) {
        if (axis) getPage(baseTh, i, pa); else getPage(i, baseSt, pa);
        break;                   // one per frame
      }
    }
  }
  return moved || pvw.pos != target;
}

void displayTask(void*) {
  uint8_t  shownState = 0xFF;   // which status screen is up
  bool     shownTest = false;
  uint16_t ringColor = 0;       // colour of the outer ring now
  int      lastPct = -1;        // OTA screens: −1 none, −2 failed, −3 sensor
  bool     dashOn = false;
  bool     previewShown = false;
  for (;;) {
    bool otaScreen = otaState == OTA_RECEIVING || otaState == OTA_DONE ||
                     (otaState == OTA_ERROR && sinceMs(otaErrorMs) < 3000);
    // leaving the dashboard (a set, an update, an error): clear its rings
    if (dashOn && (state != ST_IDLE || testMode || !imuOk || otaScreen)) {
      gfx->fillScreen(TFT_BLACK);
      dashOn = false;
      shownState = 0xFF;
      ringColor = 0;
      lastPct = -1;
    }
    // firmware update screen takes over while an update is running
    uint8_t os = otaState;
    if (os == OTA_RECEIVING || os == OTA_DONE) {
      int pct = otaSize ? (int)((uint64_t)otaWritten * 100 / otaSize) : 0;
      if (os == OTA_DONE) pct = 100;
      if (pct != lastPct) {
        if (lastPct < 0) gfx->fillCircle(120, 120, 104, TFT_BLACK);
        static char pctShown[8] = "";
        if (lastPct < 0) pctShown[0] = 0;
        say(FONT_MED, os == OTA_DONE ? "RESTART" : "UPDATE", 120, 100, TFT_WHITE);
        char ptxt[8];
        snprintf(ptxt, sizeof ptxt, "%d%%", pct);
        textDelta(pctShown, sizeof pctShown, ptxt, 120, 138, FONT_MED, TFT_WHITE);
        lastPct = pct;
        shownState = 0xFF;   // status screen redraws when the update ends
        previewShown = false;
      }
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    if (os == OTA_ERROR && sinceMs(otaErrorMs) < 3000) {
      if (lastPct != -2) {
        gfx->fillCircle(120, 120, 104, TFT_BLACK);
        say(FONT_MED, "UPDATE", 120, 100, TFT_RED);
        say(FONT_MED, "FAILED", 120, 138, TFT_RED);
        lastPct = -2;
        shownState = 0xFF;
        previewShown = false;
      }
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    // the app's theme / number carousels: the rep screen follows the finger
    bool pv = previewActive && sinceMs(previewMsgMs) < PREVIEW_HOLD_MS;
    if (pv) {
      if (!previewShown) { pvw.fresh = true; previewShown = true; dashOn = false; }
      bool moving = previewFrame();
      vTaskDelay(moving ? 1 : pdMS_TO_TICKS(15));
      continue;
    }
    if (previewShown) {             // back to what the tracker was showing
      previewShown = false;
      previewActive = false;
      tft.fillScreen(TFT_BLACK);
      shownState = 0xFF;
      ringColor = 0;
      lastPct = -1;
    }
    if (!imuOk) {
      if (lastPct != -3) {
        gfx->fillCircle(120, 120, 104, TFT_BLACK);
        say(FONT_MED, "SENSOR", 120, 100, TFT_RED);
        say(FONT_MED, "ERROR", 120, 138, TFT_RED);
        lastPct = -3;
      }
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    }
    if (lastPct != -1) {            // an update screen just ended
      gfx->fillScreen(TFT_BLACK);
      lastPct = -1;
      shownState = 0xFF;
      ringColor = 0;
      dv.valid = false;
    }

    // between sets: the day's dashboard
    if (state == ST_IDLE && !testMode) {
      if (!dashOn) { dv.valid = false; dashOn = true; }
      updateDashboard();
      vTaskDelay(pdMS_TO_TICKS(batCharging ? 150 : 250));
      continue;
    }

    uint8_t st = state;
    bool tm = testMode;
    // ring colour follows speed: blue (slow) → green → red (fast)
    float t = fminf(fabsf(vNow) / 0.8f, 1.0f);
    t = roundf(t * 10.0f) / 10.0f;
    uint8_t R = t < 0.5f ? 0 : (uint8_t)((t - 0.5f) * 2 * 255);
    uint8_t G = t < 0.5f ? (uint8_t)(t * 2 * 255) : (uint8_t)((1 - (t - 0.5f) * 2) * 255);
    uint8_t B = t < 0.5f ? (uint8_t)((1 - t * 2) * 255) : 0;
    uint16_t color = st == ST_TRACK ? gfx->color565(R, G, B) : 0x5E89;

    // a different status screen (or theme): clear once, draw its text
    static uint16_t shownTheme = 0xFFFF;
    static int lastReps = 0;
    int r = reps;
    bool themed = st == ST_TRACK && repTheme != 0;
    if (st != shownState || tm != shownTest || themeVersion != shownTheme ||
        (themed && r < lastReps)) {                 // count reset: start over
      gfx->fillScreen(TFT_BLACK);
      countReset();
      shownTheme = themeVersion;
      if (st == ST_TRACK) themeFresh(repTheme);
      switch (st) {
        case ST_IDLE:       say(FONT_MED, "READY", 120, 110, TFT_WHITE);   // USB test only
                            say(FONT_SMALL, "press Start", 120, 142, COL_MUTED); break;
        case ST_CALIB:      say(FONT_MED, "HOLD", 120, 110, TFT_WHITE);
                            say(FONT_SMALL, "keep still...", 120, 142, COL_MUTED); break;
        case ST_CALIB_FAIL: {
          say(FONT_MED, "MOVED", 120, 96, TFT_WHITE);
          say(FONT_SMALL, "retry Start", 120, 126, COL_MUTED);
          // what the sensor saw in its stillest moment (for support)
          char l1[24], l2[24];
          snprintf(l1, sizeof l1, "a %.2f sd %.2f", calBestAccMean, calBestAccStd);
          snprintf(l2, sizeof l2, "g %.1f sd %.1f dps", calBestGyroDps, calBestGyroStdDps);
          say(FONT_TINY, l1, 120, 154, COL_MUTED);
          say(FONT_TINY, l2, 120, 172, COL_MUTED);
          break;
        }
        default: break;
      }
      if (tm) say(FONT_SMALL, "USB TEST", 120, 40, TFT_YELLOW);
      shownState = st;
      shownTest = tm;
      ringColor = 0;
    }
    lastReps = r;
    RepIn in = {r, strokeFrac, phase, tempoUpMs, tempoDownMs, color, numStyle};
    if (themed) {
      themeDraw(repTheme, in);
      vTaskDelay(pdMS_TO_TICKS(40));
      continue;
    }
    // Classic: the ring repaints only when its colour changes (one arc)
    if (color != ringColor) {
      gfx->drawSmoothArc(120, 120, 119, 105, 0, 360, color, TFT_BLACK, false);
      ringColor = color;
    }
    // the rep count changes only the segments that switch
    if (st == ST_TRACK) drawCount(r, 120, 120, true, color, numStyle);
    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

/* ================= OTA (firmware update over BLE) ================= */
void otaNotify() {
  if (!otaChar) return;
  uint8_t b[6];
  b[0] = otaState;
  b[1] = otaErr;
  uint32_t w = otaWritten;
  memcpy(b + 2, &w, 4);
  otaChar->setValue(b, sizeof(b));
  otaChar->notify();
}

void otaFail(uint8_t code) {
  if (Update.isRunning()) Update.abort();
  otaErr = code;
  otaState = OTA_ERROR;
  otaErrorMs = millis();
  otaNotify();
}

// The write arrives on the NimBLE host task; flash writes happen right here so
// a write-with-response only completes once the chunk is in flash (= flow
// control). `override` makes the compiler reject a stale 1.x signature — the
// exact silent-no-call bug that once left deviceConnected false.
class OtaCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue val = c->getValue();
    const uint8_t* d = val.data();
    size_t n = val.length();
    if (n < 1) return;
    switch (d[0]) {
      case OTA_BEGIN: {
        if (n < 21) { otaFail(1); return; }       // [op, size u32, md5 16]
        uint32_t size;
        memcpy(&size, d + 1, 4);
        char md5[33];
        for (int i = 0; i < 16; i++) sprintf(md5 + i * 2, "%02x", d[5 + i]);
        if (Update.isRunning()) Update.abort();
        if (!Update.begin(size, U_FLASH)) { otaFail(2); return; }
        Update.setMD5(md5);
        state = ST_IDLE;                           // stop tracking while updating
        resetMotion();
        otaSize = size; otaWritten = 0; otaErr = 0;
        otaLastMs = millis();
        otaState = OTA_RECEIVING;
        otaNotify();
        break;
      }
      case OTA_DATA: {
        if (otaState != OTA_RECEIVING) return;
        size_t len = n - 1;
        if (otaWritten + len > otaSize) { otaFail(1); return; }  // more than announced
        if (Update.write((uint8_t*)d + 1, len) != len) { otaFail(3); return; }
        otaWritten = otaWritten + len;
        otaLastMs = millis();
        if (otaWritten % 16384 < len) otaNotify();  // progress every ~16 KB
        break;
      }
      case OTA_END: {
        if (otaState != OTA_RECEIVING) return;
        // end() checks the MD5 sent in BEGIN and the image itself
        if (otaWritten != otaSize || !Update.end(true)) { otaFail(4); return; }
        otaState = OTA_DONE;
        otaNotify();
        otaRebootPending = true;                   // reboot from loop()
        otaDoneMs = millis();
        break;
      }
      case OTA_ABORT:
        if (Update.isRunning()) Update.abort();
        otaState = OTA_IDLE;
        otaNotify();
        break;
    }
  }
};

// …cdefc: the app's numbers for today (DayPacket).
class DayCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue val = c->getValue();
    if (val.length() < sizeof(DayPacket) || val.data()[0] != 1) return;
    memcpy(&day, val.data(), sizeof(DayPacket));
    dayRxMs = millis();
    dayValid = true;
    clockValid = true;
    dayVersion = dayVersion + 1;
    daySavePending = true;     // written to flash from loop(), not here
  }
};

// …cdefd: [1, theme, number style] from the app (style optional, older
// apps send 2 bytes); reads back [1, theme, theme count, style, style count,
// flags] (flags bit 0: live preview). Live preview: [2, axis, pos u16 LE]
// (write without response, the app's carousel position) and [3] (closed).
NimBLECharacteristic* setChar = nullptr;
void setValueOfSettings() {
  if (!setChar) return;
  uint8_t b[6] = {1, repTheme, THEME_COUNT, numStyle, NUM_STYLE_COUNT, 1};
  setChar->setValue(b, 6);
}
class SettingsCallbacks : public NimBLECharacteristicCallbacks {
  void onWrite(NimBLECharacteristic* c, NimBLEConnInfo& info) override {
    NimBLEAttValue val = c->getValue();
    const uint8_t* d = val.data();
    if (val.length() >= 4 && d[0] == 2) {          // carousel position
      previewAxis = d[1] ? 1 : 0;
      previewPos = d[2] | (d[3] << 8);
      previewMsgMs = millis();
      previewActive = true;
      return;
    }
    if (val.length() >= 1 && d[0] == 3) { previewActive = false; return; }
    if (val.length() < 2 || d[0] != 1) { setValueOfSettings(); return; }
    uint8_t t = val.data()[1];
    if (t < THEME_COUNT && t != repTheme) {
      repTheme = t;
      themeSavePending = true;
      themeVersion = themeVersion + 1;
    }
    if (val.length() >= 3) {
      uint8_t n = val.data()[2];
      if (n < NUM_STYLE_COUNT && n != numStyle) {
        numStyle = n;
        themeSavePending = true;
        themeVersion = themeVersion + 1;
      }
    }
    setValueOfSettings();
  }
};

/* ================= BLE ================= */
void setupBLE() {
  NimBLEDevice::init("Smart Tracker");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(517);   // big MTU → 512-byte OTA chunks
  bleServer = NimBLEDevice::createServer();
  NimBLEService* s = bleServer->createService(SERVICE_UUID);
  motionChar = s->createCharacteristic(MOTION_CHAR_UUID,
                 NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  repChar    = s->createCharacteristic(REP_CHAR_UUID,
                 NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  velChar    = s->createCharacteristic(VEL_CHAR_UUID,
                 NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  ctrlChar   = s->createCharacteristic(CTRL_CHAR_UUID,
                 NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE |
                 NIMBLE_PROPERTY::WRITE_NR);
  trackChar  = s->createCharacteristic(TRACK_CHAR_UUID,
                 NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  otaChar    = s->createCharacteristic(OTA_CHAR_UUID,
                 NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR |
                 NIMBLE_PROPERTY::NOTIFY);
  otaChar->setCallbacks(new OtaCallbacks());
  verChar    = s->createCharacteristic(VER_CHAR_UUID, NIMBLE_PROPERTY::READ);
  verChar->setValue(FW_VERSION);
  batChar    = s->createCharacteristic(BAT_CHAR_UUID,
                 NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY);
  uint8_t unknown[2] = {0xFF, 0};   // 255 until the first reading
  batChar->setValue(unknown, 2);
  dayChar    = s->createCharacteristic(DAY_CHAR_UUID,
                 NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  dayChar->setCallbacks(new DayCallbacks());
  setChar    = s->createCharacteristic(SET_CHAR_UUID,
                 NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::WRITE | NIMBLE_PROPERTY::WRITE_NR);
  setChar->setCallbacks(new SettingsCallbacks());
  setValueOfSettings();
  s->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();
}

TrackPacket makeTrackPacket(uint32_t now) {
  TrackPacket tp;
  tp.t_ms  = now;
  tp.a     = aF;
  tp.v     = v;
  tp.p     = p;
  tp.reps  = (int16_t)reps;
  tp.state = state;
  tp.flags = zupt ? 1 : 0;
  return tp;
}

MotionPacket makeMotionPacket(uint32_t now) {
  MotionPacket mp = {};
  mp.ts_ms = now;
  mp.az = aF;  mp.accEnv = accEnv;
  mp.velZ = v; mp.posZ = p;
  mp.motionCount = reps;
  return mp;
}

// same packets as BLE, hex-encoded over USB (~9 KB/s at 50 Hz)
void testStream(uint32_t now) {
  if (!testMode || now - lastTestMs < 20) return;
  lastTestMs = now;
  TrackPacket tp = makeTrackPacket(now);
  sendHexLine('T', &tp, sizeof(tp));
  MotionPacket mp = makeMotionPacket(now);
  sendHexLine('M', &mp, sizeof(mp));
}

void bleNotify(uint32_t now) {
  bool connected = bleServer && bleServer->getConnectedCount() > 0;
  if (wasConnected && !connected) {
    NimBLEDevice::getAdvertising()->start();   // re-advertise after drop
    if (!testMode) { state = ST_IDLE; resetMotion(); }  // a new session needs START
    // The next app session numbers its commands from 1 again: forget the old
    // sequence and the stale command, or its first START could be ignored.
    lastSeq = -1;
    if (ctrlChar) { uint8_t none[1] = {0xFF}; ctrlChar->setValue(none, 1); }
    if (otaState == OTA_RECEIVING) {           // link lost mid-update: discard
      if (Update.isRunning()) Update.abort();  // the partial image; the old
      otaState = OTA_IDLE;                     // firmware keeps running
    }
  }
  wasConnected = connected;
  // keep the radio free for firmware chunks while an update is running
  if (otaState == OTA_RECEIVING) return;
  if (!connected || now - lastBleMs < 20) return;
  lastBleMs = now;

  TrackPacket tp = makeTrackPacket(now);
  trackChar->setValue((uint8_t*)&tp, sizeof(tp));
  trackChar->notify();

  MotionPacket mp = makeMotionPacket(now);
  motionChar->setValue((uint8_t*)&mp, sizeof(mp));
  motionChar->notify();

  int32_t r = reps;
  if (r != lastRepSent) {
    lastRepSent = r;
    repChar->setValue((uint8_t*)&r, sizeof(r));
    repChar->notify();
  }
  float sp = fabsf(v);
  velChar->setValue((uint8_t*)&sp, sizeof(sp));
  velChar->notify();
}

/* ================= SETUP / LOOP ================= */
void setup() {
  Serial.begin(SERIAL_BAUD);
  Wire.begin(6, 7);
  Wire.setClock(400000);
  imuOk = imu.begin(Wire);
  imu.setAccelRange(QMI8658_ACCEL_RANGE_4G);
  imu.setGyroRange(QMI8658_GYRO_RANGE_512DPS);
  imu.setAccelODR(QMI8658_ACCEL_ODR_1000HZ);
  imu.setGyroODR(QMI8658_GYRO_ODR_1000HZ);
  imu.setAccelUnit_mps2(true);
  imu.setGyroUnit_rads(false);          // library gives dps; converted below
  imu.enableSensors(QMI8658_ENABLE_ACCEL | QMI8658_ENABLE_GYRO);

  pinMode(40, OUTPUT);
  digitalWrite(40, HIGH);
  tft.init();
  tft.setRotation(0);
  tft.fillScreen(TFT_BLACK);

  // the last day summary survives a restart (the clock does not)
  prefs.begin("gympath", false);
  repTheme = prefs.getUChar("theme", 0);
  if (repTheme >= THEME_COUNT) repTheme = 0;
  numStyle = prefs.getUChar("num", 0);
  if (numStyle >= NUM_STYLE_COUNT) numStyle = 0;
  DayPacket saved;
  if (prefs.getBytes("day", &saved, sizeof saved) == sizeof saved && saved.ver == 1) {
    day = saved;
    dayValid = true;
    dayVersion = 1;
  }
  analogSetPinAttenuation(BAT_PIN, ADC_11db);

  setupBLE();
#if DEBUG_STREAM
  Serial.println("# GYMPATH TRACK fw=" FW_BUILD);
  Serial.println("# COLUMNS t,a,v,p,reps,state,zupt");
#endif
  lastSampleUs = micros();
  xTaskCreatePinnedToCore(displayTask, "display", 6144, NULL, 1, NULL, 0);
}

// arduino-esp32 hook: this firmware confirms a freshly installed image itself
// (see loop), so an image that crashes or hangs before that rolls back to the
// previous one on the next reset, where the bootloader supports rollback.
extern "C" bool verifyRollbackLater() { return true; }

void loop() {
  uint32_t now = millis();

  // new firmware verified and written → give the DONE notify time to go out
  if (otaRebootPending && sinceMs(otaDoneMs) > 1500) ESP.restart();

  if (themeSavePending) {
    themeSavePending = false;
    prefs.putUChar("theme", repTheme);
    prefs.putUChar("num", numStyle);
  }
  if (daySavePending) {
    daySavePending = false;
    DayPacket copy = day;
    prefs.putBytes("day", &copy, sizeof copy);
  }

  // battery every 2 s (8-sample average, smoothed)
  if (otaState != OTA_RECEIVING && (now - lastBatMs >= 2000 || lastBatMs == 0)) {
    lastBatMs = now;
    uint32_t mv = 0;
    for (int i = 0; i < 32; i++) mv += analogReadMilliVolts(BAT_PIN);
    float v = mv / 32.0f * 3.0f / 1000.0f;       // 200k/100k divider
    vbat = vbat == 0 ? v : vbat + 0.2f * (v - vbat);
    batPresent  = vbat > 2.5f;
    bool wasCharging = batCharging;
    chargeStep(v, now);
    // the charge current lifts the reading: estimate the resting voltage
    int pct = batPresent ? batteryPercent(batCharging ? vbat - 0.06f : vbat) : -1;
    if (pct != batPct || batCharging != wasCharging) {
      batPct = pct;
      if (batChar) {   // [percent (255 = unknown), flags: bit0 charging, bit1 USB host]
        uint8_t b[2] = {(uint8_t)(pct < 0 ? 0xFF : pct),
                        (uint8_t)((batCharging ? 1 : 0) | (usbHost ? 2 : 0))};
        batChar->setValue(b, 2);
        if (bleServer && bleServer->getConnectedCount() > 0) batChar->notify();
      }
    }
  }

  // running fine for 10 s with Bluetooth up: keep this image
  if (!fwConfirmed && now > 10000) {
    esp_ota_mark_app_valid_cancel_rollback();
    fwConfirmed = true;
  }

  // an update that stopped sending data: cancel it, the old image stays
  // (otaLastMs is set by the Bluetooth task: compare with a fresh clock, as
  // a stamp taken after `now` made this fire at random points before 1.3.1)
  if (otaState == OTA_RECEIVING && sinceMs(otaLastMs) > OTA_STALL_MS) {
    otaFail(5);
  }

  pollControl(now);
  pollSerial(now);

  if (otaState != OTA_RECEIVING && imuOk && imu.readSensorData(imuData)) {
    // integrate over the real time since the previous sample (the loop runs
    // faster than the IMU, so the loop period is not the sample period)
    uint32_t nowUs = micros();
    float dt = (nowUs - lastSampleUs) * 1e-6f;
    lastSampleUs = nowUs;
    if (dt <= 0) dt = 1e-3f;
    if (dt > 0.02f) dt = 0.02f;
    float a[3] = {imuData.accelX, imuData.accelY, imuData.accelZ};
    float w[3] = {(float)(imuData.gyroX * DEG_TO_RAD),
                  (float)(imuData.gyroY * DEG_TO_RAD),
                  (float)(imuData.gyroZ * DEG_TO_RAD)};
    if (state == ST_CALIB)      calibStep(a, w, now);
    else if (state == ST_TRACK) trackStep(a, w, dt);
  }

  bleNotify(now);
  testStream(now);

#if DEBUG_STREAM
  if (!testMode && now - lastDbgMs >= 20) {
    lastDbgMs = now;
    Serial.printf("%lu,%.3f,%.3f,%.4f,%d,%u,%u\n", now, aF, v, p,
                  (int)reps, (unsigned)state, (unsigned)(zupt ? 1 : 0));
  }
#endif
}
