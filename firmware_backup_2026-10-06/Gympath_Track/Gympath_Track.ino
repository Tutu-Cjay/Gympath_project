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
 */
#include <Wire.h>
#include <QMI8658.h>
#include <TFT_eSPI.h>
#include <NimBLEDevice.h>
#include <Update.h>
#include <math.h>

#define FW_VERSION   "1.0.0"     // bump on every release; the app compares it
                                 // with firmware/manifest.json to offer updates
#define FW_BUILD     "TRACK-1D-1"
#define DEBUG_STREAM 0   // 1 = CSV over serial (t,a,v,p,reps,state) @ 50 Hz

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

/* ================= TUNING ================= */
const uint32_t CALIB_WINDOW_MS  = 600;    // still window used for gravity
const uint32_t CALIB_TIMEOUT_MS = 6000;   // give up if never still
const float    CALIB_ACC_STD    = 0.10f;  // m/s²  max |a| std-dev while "still"
const float    CALIB_GYRO_MAX   = 0.06f;  // rad/s max mean |ω| while "still"

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
const float    DIR_VEL_TH       = 0.04f;  // m/s  velocity that counts as moving

/* ================= STATE ================= */
volatile uint8_t state = ST_IDLE;
volatile int32_t reps = 0;
volatile float   vNow = 0;     // read by the display task

// calibration accumulators
uint32_t calStartMs = 0, calWinStartMs = 0;
uint32_t calN = 0;
double   cSum[3], cMagSum, cMagSq, cGyro[3], cGyroMag;

// tracking
float up[3]    = {0, 0, 1};   // gravity-opposite unit vector, body frame
float gMag     = 9.81f;
float gBias[3] = {0, 0, 0};   // rad/s
float aF = 0, v = 0, p = 0, accEnv = 0;
float stillT = 0;
bool  zupt = false;

// direction-agnostic rep counter: one rep = go out ≥ REP_MIN_DISP, come back
int8_t outDir = 0;            // +1 / −1 direction of the current excursion
float  outDisp = 0, backDisp = 0;
bool   counted = false;

uint32_t lastUs = 0, lastBleMs = 0, lastDbgMs = 0;
int32_t  lastRepSent = -1;
int      lastSeq = -1;
bool     wasConnected = false;

/* ================= HELPERS ================= */
static inline float dot3(const float a[3], const float b[3]) {
  return a[0]*b[0] + a[1]*b[1] + a[2]*b[2];
}
static inline void norm3(float a[3]) {
  float n = sqrtf(dot3(a, a));
  if (n > 1e-6f) { a[0] /= n; a[1] /= n; a[2] /= n; }
}

void resetMotion() {
  aF = v = p = accEnv = 0;
  stillT = 0; zupt = false;
  outDir = 0; outDisp = backDisp = 0; counted = false;
}

void beginCalibration(uint32_t now) {
  state = ST_CALIB;
  calStartMs = calWinStartMs = now;
  calN = 0;
  for (int i = 0; i < 3; i++) { cSum[i] = 0; cGyro[i] = 0; }
  cMagSum = cMagSq = cGyroMag = 0;
  reps = 0;
  resetMotion();
}

/* ================= CONTROL (polled, callback-free) ================= */
void pollControl(uint32_t now) {
  if (!ctrlChar) return;
  auto val = ctrlChar->getValue();
  if (val.length() < 2) return;
  const uint8_t* d = (const uint8_t*)val.data();
  int seq = d[1];
  if (seq == lastSeq) return;          // already handled
  lastSeq = seq;
  switch (d[0]) {
    case CMD_START: beginCalibration(now); break;
    case CMD_STOP:  state = ST_IDLE; resetMotion(); break;
    case CMD_ZERO:  if (state == ST_TRACK) { p = 0; v = 0;
                      outDir = 0; outDisp = backDisp = 0; counted = false; }
                    break;
  }
}

/* ================= CALIBRATION ================= */
void calibStep(const float a[3], const float w[3], uint32_t now) {
  float mag = sqrtf(dot3(a, a));
  float wm  = sqrtf(dot3(w, w));
  for (int i = 0; i < 3; i++) { cSum[i] += a[i]; cGyro[i] += w[i]; }
  cMagSum += mag; cMagSq += (double)mag * mag; cGyroMag += wm;
  calN++;

  if (now - calWinStartMs < CALIB_WINDOW_MS) return;

  double mean = cMagSum / calN;
  double var  = cMagSq / calN - mean * mean;
  double std  = var > 0 ? sqrt(var) : 0;
  double gAvg = cGyroMag / calN;

  if (std < CALIB_ACC_STD && gAvg < CALIB_GYRO_MAX && calN > 50) {
    for (int i = 0; i < 3; i++) {
      up[i]    = (float)(cSum[i] / calN);   // accel at rest points "up"
      gBias[i] = (float)(cGyro[i] / calN);
    }
    gMag = sqrtf(dot3(up, up));
    norm3(up);
    resetMotion();
    state = ST_TRACK;
  } else if (now - calStartMs > CALIB_TIMEOUT_MS) {
    state = ST_CALIB_FAIL;               // app shows "keep still, retry"
  } else {
    // not still enough — start a fresh window
    calWinStartMs = now; calN = 0;
    for (int i = 0; i < 3; i++) { cSum[i] = 0; cGyro[i] = 0; }
    cMagSum = cMagSq = cGyroMag = 0;
  }
}

/* ================= TRACKING ================= */
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
  float dp = v * dt;
  p += dp;
  vNow = v;

  // ---- rep counter: out-and-back excursion, direction agnostic ----
  if (zupt) {
    outDir = 0; outDisp = backDisp = 0; counted = false;
    return;
  }
  int8_t dir = v > DIR_VEL_TH ? 1 : (v < -DIR_VEL_TH ? -1 : 0);
  if (outDir == 0) {
    if (dir != 0) { outDir = dir; outDisp = backDisp = 0; counted = false; }
    return;
  }
  if (dp * outDir > 0) {               // moving out
    if (counted) {                     // previous rep done → new excursion
      outDisp = backDisp = 0; counted = false;
    } else if (backDisp > 0 && backDisp < REP_RETURN_FRAC * outDisp) {
      backDisp = 0;                    // partial return, keep going out
    }
    outDisp += fabsf(dp);
  } else if (dp * outDir < 0) {        // coming back
    backDisp += fabsf(dp);
    if (!counted && outDisp >= REP_MIN_DISP &&
        backDisp >= REP_RETURN_FRAC * outDisp) {
      reps = reps + 1;
      counted = true;
    }
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

    if (st != lastState || r != lastReps || color != lastColor) {
      if (st != lastState || r != lastReps) tft.fillCircle(120, 120, 100, TFT_BLACK);
      for (int rad = 105; rad < 121; rad++) tft.drawSmoothCircle(120, 120, rad, color, color);
      tft.setTextDatum(MC_DATUM);
      tft.setTextColor(TFT_WHITE, TFT_BLACK);
      switch (st) {
        case ST_IDLE:       tft.drawString("READY", 120, 112, 4);
                            tft.drawString("press Start", 120, 145, 2); break;
        case ST_CALIB:      tft.drawString("HOLD", 120, 112, 4);
                            tft.drawString("still...", 120, 145, 2); break;
        case ST_CALIB_FAIL: tft.drawString("MOVED", 120, 112, 4);
                            tft.drawString("retry Start", 120, 145, 2); break;
        default:            draw7SegNumber(r, 120, 120, 6, color); break;
      }
      lastState = st; lastReps = r; lastColor = color;
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
        otaState = OTA_RECEIVING;
        otaNotify();
        break;
      }
      case OTA_DATA: {
        if (otaState != OTA_RECEIVING) return;
        size_t len = n - 1;
        if (Update.write((uint8_t*)d + 1, len) != len) { otaFail(3); return; }
        otaWritten = otaWritten + len;
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

void bleNotify(uint32_t now) {
  bool connected = bleServer && bleServer->getConnectedCount() > 0;
  if (wasConnected && !connected) {
    NimBLEDevice::getAdvertising()->start();   // re-advertise after drop
    state = ST_IDLE; resetMotion();            // a new session needs START
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

  TrackPacket tp;
  tp.t_ms  = now;
  tp.a     = aF;
  tp.v     = v;
  tp.p     = p;
  tp.reps  = (int16_t)reps;
  tp.state = state;
  tp.flags = zupt ? 1 : 0;
  trackChar->setValue((uint8_t*)&tp, sizeof(tp));
  trackChar->notify();

  MotionPacket mp = {};
  mp.ts_ms = now;
  mp.az = aF;  mp.accEnv = accEnv;
  mp.velZ = v; mp.posZ = p;
  mp.motionCount = reps;
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
  Serial.begin(DEBUG_STREAM ? 921600 : 115200);
  Wire.begin(6, 7);
  Wire.setClock(400000);
  imu.begin(Wire);
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
  lastUs = micros();
  xTaskCreatePinnedToCore(displayTask, "display", 6144, NULL, 1, NULL, 0);
}

void loop() {
  uint32_t nowUs = micros();
  float dt = (nowUs - lastUs) * 1e-6f;
  if (dt <= 0) dt = 1e-3f;
  if (dt > 0.02f) dt = 0.02f;
  lastUs = nowUs;
  uint32_t now = millis();

  // new firmware verified and written → give the DONE notify time to go out
  if (otaRebootPending && now - otaDoneMs > 1500) ESP.restart();

  pollControl(now);

  if (otaState != OTA_RECEIVING && imu.readSensorData(imuData)) {
    float a[3] = {imuData.accelX, imuData.accelY, imuData.accelZ};
    float w[3] = {imuData.gyroX * DEG_TO_RAD, imuData.gyroY * DEG_TO_RAD,
                  imuData.gyroZ * DEG_TO_RAD};
    if (state == ST_CALIB)      calibStep(a, w, now);
    else if (state == ST_TRACK) trackStep(a, w, dt);
  }

  bleNotify(now);

#if DEBUG_STREAM
  if (now - lastDbgMs >= 20) {
    lastDbgMs = now;
    Serial.printf("%lu,%.3f,%.3f,%.4f,%d,%u,%u\n", now, aF, v, p,
                  (int)reps, (unsigned)state, (unsigned)(zupt ? 1 : 0));
  }
#endif
}
