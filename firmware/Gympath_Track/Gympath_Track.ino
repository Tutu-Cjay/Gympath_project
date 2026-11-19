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
#include <math.h>

#define FW_VERSION   "1.1.1"     // bump on every release; the app compares it
                                 // with the published manifest.json to offer
                                 // updates (.github/workflows/firmware.yml)
#define FW_BUILD     "TRACK-1D-3"
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

/* ================= BLE ================= */
#define SERVICE_UUID     "12345678-1234-5678-1234-56789abcdef0"
#define MOTION_CHAR_UUID "12345678-1234-5678-1234-56789abcdef1"  // legacy 60 B
#define REP_CHAR_UUID    "12345678-1234-5678-1234-56789abcdef2"
#define VEL_CHAR_UUID    "12345678-1234-5678-1234-56789abcdef3"
#define CTRL_CHAR_UUID   "12345678-1234-5678-1234-56789abcdef8"  // app → device
#define TRACK_CHAR_UUID  "12345678-1234-5678-1234-56789abcdef9"  // device → app
#define OTA_CHAR_UUID    "12345678-1234-5678-1234-56789abcdefa"  // firmware update
#define VER_CHAR_UUID    "12345678-1234-5678-1234-56789abcdefb"  // FW_VERSION

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
const float    ACC_DEADBAND     = 0.04f;  // m/s²  ignore residual bias
const float    VEL_LEAK         = 0.30f;  // 1/s   light drift damping
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

/* ================= HELPERS ================= */
static inline float dot3(const float a[3], const float b[3]) {
  return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}
static inline void norm3(float a[3]) {
  float n = sqrtf(dot3(a, a));
  if (n > 1e-6f) { a[0] /= n; a[1] /= n; a[2] /= n; }
}

void resetReps() {
  repBase = p; repPeak = 0; repDir = 0; lastDir = 0;
}

void resetMotion() {
  aF = v = p = accEnv = 0;
  stillT = 0; zupt = false;
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
    case CMD_ZERO:  if (state == ST_TRACK) { p = 0; v = 0; resetReps(); }
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
  if (fabsf(mag - gMag) < ZUPT_ACC_TH && wm < ZUPT_GYRO_TH) stillT += dt;
  else stillT = 0;
  zupt = stillT > ZUPT_TIME_S;

  // ---- project onto the gravity axis ----
  float aUp = dot3(a, up) - gMag;
  aF += ACC_LPF * (aUp - aF);
  float aUse = fabsf(aF) < ACC_DEADBAND ? 0.0f : aF;
  accEnv = 0.9f * accEnv + 0.1f * fabsf(aF);

  if (zupt) {
    v = 0;
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
    v += aUse * dt;
    v *= expf(-VEL_LEAK * dt);
  }
  p += v * dt;
  vNow = v;
  repStep();
}

void repStep() {
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
    }
    return;
  }
  float out = (p - repBase) * repDir;  // distance from the start, outwards
  if (out > repPeak) repPeak = out;
  if (out <= (1.0f - REP_RETURN_FRAC) * repPeak) {
    reps = reps + 1;
    lastDir = repDir;
    repDir = 0;
    repBase = p;
  }
}

/* ================= DISPLAY (core 0) ================= */
const bool segMap[10][7] = {
  {1,1,1,1,1,1,0},{0,1,1,0,0,0,0},{1,1,0,1,1,0,1},{1,1,1,1,0,0,1},
  {0,1,1,0,0,1,1},{1,0,1,1,0,1,1},{1,0,1,1,1,1,1},{1,1,1,0,0,0,0},
  {1,1,1,1,1,1,1},{1,1,1,1,0,1,1}
};

void draw7SegDigit(int dgt, int x, int y, int s, uint16_t c) {
  if (dgt < 0 || dgt > 9) return;
  int w = 6 * s, h = s, vv = 7 * s;
  if (segMap[dgt][0]) tft.fillRect(x + h, y, w, h, c);
  if (segMap[dgt][1]) tft.fillRect(x + w + h, y + h, h, vv, c);
  if (segMap[dgt][2]) tft.fillRect(x + w + h, y + vv + 2*h, h, vv, c);
  if (segMap[dgt][3]) tft.fillRect(x + h, y + 2*vv + 2*h, w, h, c);
  if (segMap[dgt][4]) tft.fillRect(x, y + vv + 2*h, h, vv, c);
  if (segMap[dgt][5]) tft.fillRect(x, y + h, h, vv, c);
  if (segMap[dgt][6]) tft.fillRect(x + h, y + vv + h, w, h, c);
}

void draw7SegNumber(int n, int cx, int cy, int s, uint16_t c) {
  String str = String(n);
  int dw = 8 * s, dh = 17 * s, sp = 2 * s;
  int tw = str.length() * dw + (str.length() - 1) * sp;
  int x = cx - tw / 2, y = cy - dh / 2;
  for (unsigned i = 0; i < str.length(); i++) {
    draw7SegDigit(str[i] - '0', x, y, s, c);
    x += dw + sp;
  }
}

void displayTask(void*) {
  uint8_t lastState = 0xFF;
  int lastReps = -1;
  uint16_t lastColor = 0;
  int lastPct = -1;
  bool lastTest = false;
  for (;;) {
    // firmware update screen takes over while an update is running
    uint8_t os = otaState;
    if (os == OTA_RECEIVING || os == OTA_DONE) {
      int pct = otaSize ? (int)((uint64_t)otaWritten * 100 / otaSize) : 0;
      if (os == OTA_DONE) pct = 100;
      if (pct != lastPct) {
        if (lastPct < 0) tft.fillCircle(120, 120, 100, TFT_BLACK);
        tft.setTextDatum(MC_DATUM);
        tft.setTextColor(TFT_WHITE, TFT_BLACK);
        tft.drawString(os == OTA_DONE ? "RESTART" : "UPDATE", 120, 100, 4);
        tft.drawString(String("  ") + pct + "%  ", 120, 140, 4);
        lastPct = pct;
        lastState = 0xFF;   // force a full redraw when the update ends
      }
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    if (os == OTA_ERROR && millis() - otaErrorMs < 3000) {
      if (lastPct != -2) {
        tft.fillCircle(120, 120, 100, TFT_BLACK);
        tft.setTextDatum(MC_DATUM);
        tft.setTextColor(TFT_RED, TFT_BLACK);
        tft.drawString("UPDATE", 120, 100, 4);
        tft.drawString("FAILED", 120, 140, 4);
        lastPct = -2;
        lastState = 0xFF;
      }
      vTaskDelay(pdMS_TO_TICKS(100));
      continue;
    }
    if (!imuOk) {
      if (lastPct != -3) {
        tft.fillCircle(120, 120, 100, TFT_BLACK);
        tft.setTextDatum(MC_DATUM);
        tft.setTextColor(TFT_RED, TFT_BLACK);
        tft.drawString("SENSOR", 120, 100, 4);
        tft.drawString("ERROR", 120, 140, 4);
        lastPct = -3;
      }
      vTaskDelay(pdMS_TO_TICKS(200));
      continue;
    }
    lastPct = -1;
    uint8_t st = state;
    int r = reps;
    // ring colour follows speed: blue (slow) → green → red (fast)
    float t = fminf(fabsf(vNow) / 0.8f, 1.0f);
    t = roundf(t * 10.0f) / 10.0f;
    uint8_t R = t < 0.5f ? 0 : (uint8_t)((t - 0.5f) * 2 * 255);
    uint8_t G = t < 0.5f ? (uint8_t)(t * 2 * 255) : (uint8_t)((1 - (t - 0.5f) * 2) * 255);
    uint8_t B = t < 0.5f ? (uint8_t)((1 - t * 2) * 255) : 0;
    uint16_t color = st == ST_TRACK ? tft.color565(R, G, B) : 0x5E89;

    bool tm = testMode;
    if (st != lastState || r != lastReps || color != lastColor || tm != lastTest) {
      if (st != lastState || r != lastReps || tm != lastTest)
        tft.fillCircle(120, 120, 100, TFT_BLACK);
      for (int rad = 105; rad < 121; rad++) tft.drawSmoothCircle(120, 120, rad, color, color);
      tft.setTextDatum(MC_DATUM);
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      switch (st) {
        case ST_IDLE:       tft.drawString("READY", 120, 112, 4);
                            tft.drawString("press Start", 120, 145, 2); break;
        case ST_CALIB:      tft.drawString("HOLD", 120, 112, 4);
                            tft.drawString("still...", 120, 145, 2); break;
        case ST_CALIB_FAIL: {
          tft.drawString("MOVED", 120, 100, 4);
          tft.drawString("retry Start", 120, 130, 2);
          // what the sensor saw in its stillest moment (for support)
          char l1[24], l2[24];
          snprintf(l1, sizeof l1, "a %.2f sd %.2f", calBestAccMean, calBestAccStd);
          snprintf(l2, sizeof l2, "g %.1f sd %.1f dps", calBestGyroDps, calBestGyroStdDps);
          tft.setTextColor(TFT_DARKGREY, TFT_BLACK);
          tft.drawString(l1, 120, 160, 2);
          tft.drawString(l2, 120, 178, 2);
          tft.setTextColor(TFT_WHITE, TFT_BLACK);
          break;
        }
        default:            draw7SegNumber(r, 120, 120, 6, color); break;
      }
      if (tm) {
        tft.setTextColor(TFT_YELLOW, TFT_BLACK);
        tft.drawString("USB TEST", 120, 38, 2);
      }
      lastState = st; lastReps = r; lastColor = color; lastTest = tm;
    }
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
  if (otaRebootPending && now - otaDoneMs > 1500) ESP.restart();

  // running fine for 10 s with Bluetooth up: keep this image
  if (!fwConfirmed && now > 10000) {
    esp_ota_mark_app_valid_cancel_rollback();
    fwConfirmed = true;
  }

  // an update that stopped sending data: cancel it, the old image stays
  if (otaState == OTA_RECEIVING && now - otaLastMs > OTA_STALL_MS) {
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
