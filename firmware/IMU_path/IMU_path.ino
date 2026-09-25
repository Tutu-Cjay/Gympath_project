#include <Wire.h>
#include <QMI8658.h>
#include <TFT_eSPI.h>
#include <math.h>
#include <NimBLEDevice.h>

// ===== Size reduction toggles =====
#define USE_BOOT_LOGO 1  // set to 1 to show logo (adds ~450KB flash)
#define ENABLE_SERIAL 0   // set to 1 to enable Serial prints
#define DEBUG_STREAM 1    // set to 1 to stream CSV debug data for tools/imu_debug_viewer.py (set 0 for production)
#define FW_BUILD "B8-F16" // bump on every flash-worthy change — shown in # CALIB so logs identify the build

#if USE_BOOT_LOGO
#include "logo200.h"
#endif

#if ENABLE_SERIAL
#define DBG_PRINT(x) Serial.print(x)
#define DBG_PRINTLN(x) Serial.println(x)
#define DBG_PRINTF(val, digits) Serial.print(val, digits)
#else
#define DBG_PRINT(x)
#define DBG_PRINTLN(x)
#define DBG_PRINTF(val, digits)
#endif
/* ================= OBJECTS ================= */
QMI8658 imu;
QMI8658_Data imuData;
TFT_eSPI tft;

/* ================= BLE ================= */
#define SERVICE_UUID       "12345678-1234-5678-1234-56789abcdef0"
#define MOTION_CHAR_UUID   "12345678-1234-5678-1234-56789abcdef1"
#define REP_CHAR_UUID      "12345678-1234-5678-1234-56789abcdef2"
#define VEL_CHAR_UUID      "12345678-1234-5678-1234-56789abcdef3"

struct __attribute__((packed)) MotionPacket {
  // ── v1 fields (60 bytes, unchanged for backwards compatibility) ──
  uint32_t ts_ms;
  float ax;
  float ay;
  float az;
  float gx;
  float gy;
  float gz;
  float accEnv;
  float velX;
  float velY;
  float velZ;
  float posX;
  float posY;
  float posZ;
  int32_t motionCount;
  // ── v2 fields (B8, +44 bytes = 104 total) ──
  float roll;        // Euler ZYX [deg]
  float pitch;       // Euler ZYX [deg]
  float yaw;         // Euler ZYX [deg] — relative, drifts (no magnetometer)
  float originX;     // ZUPT-estimated rest origin [m]
  float originY;
  float originZ;
  float dx;          // displacement from origin [m]
  float dy;
  float dz;
  float dispMag;     // |displacement| [m]
  uint8_t repPhase;  // 0=REST, 1=ACTIVE
  uint8_t zuptActive;
  uint16_t _pad;
};

NimBLEServer* bleServer = nullptr;
NimBLECharacteristic* motionChar = nullptr;
NimBLECharacteristic* repChar = nullptr;
NimBLECharacteristic* velChar = nullptr;
bool deviceConnected = false;
uint32_t lastBleMs = 0;
int lastRepSent = -1;

class ServerCallbacks : public NimBLEServerCallbacks {
public:
  // Support multiple NimBLE-Arduino versions by avoiding strict override signatures.
  void onConnect(NimBLEServer* pServer) {
    deviceConnected = true;
  }
  void onDisconnect(NimBLEServer* pServer) {
    deviceConnected = false;
    NimBLEDevice::getAdvertising()->start();
  }
  void onConnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    deviceConnected = true;
  }
  void onDisconnect(NimBLEServer* pServer, ble_gap_conn_desc* desc) {
    deviceConnected = false;
    NimBLEDevice::getAdvertising()->start();
  }
};

void setupBLE() {
  NimBLEDevice::init("Smart Tracker");
  NimBLEDevice::setPower(ESP_PWR_LVL_P9);
  NimBLEDevice::setMTU(185);

  bleServer = NimBLEDevice::createServer();
  bleServer->setCallbacks(new ServerCallbacks());

  NimBLEService* service = bleServer->createService(SERVICE_UUID);
  motionChar = service->createCharacteristic(
    MOTION_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  repChar = service->createCharacteristic(
    REP_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );
  velChar = service->createCharacteristic(
    VEL_CHAR_UUID,
    NIMBLE_PROPERTY::READ | NIMBLE_PROPERTY::NOTIFY
  );

  service->start();
  NimBLEAdvertising* adv = NimBLEDevice::getAdvertising();
  adv->addServiceUUID(SERVICE_UUID);
  adv->start();
}


#if USE_BOOT_LOGO
void drawLogo200(int x0, int y0) {
  for (int y = 0; y < 240; y++) {
    for (int x = 0; x < 240; x++) {
      uint16_t c = logo200[y][x];
      if (c != 0x0000) {        // optional transparency
        tft.drawPixel(x0 + x, y0 + y, c);
      }
    }
  }
}
#endif


// A B C D E F G
const bool segMap[10][7] = {
  {1,1,1,1,1,1,0}, // 0
  {0,1,1,0,0,0,0}, // 1
  {1,1,0,1,1,0,1}, // 2
  {1,1,1,1,0,0,1}, // 3
  {0,1,1,0,0,1,1}, // 4
  {1,0,1,1,0,1,1}, // 5
  {1,0,1,1,1,1,1}, // 6
  {1,1,1,0,0,0,0}, // 7
  {1,1,1,1,1,1,1}, // 8
  {1,1,1,1,0,1,1}  // 9
};


void draw7SegDigit(
  int digit,
  int x,
  int y,
  int scale,
  uint16_t color
) {
  if (digit < 0 || digit > 9) return;

  int w = 6 * scale;   // segment length
  int h = scale;       // segment thickness
  int v = 7 * scale;   // vertical length

  // A
  if (segMap[digit][0])
    tft.fillRect(x + h, y, w, h, color);

  // B
  if (segMap[digit][1])
    tft.fillRect(x + w + h, y + h, h, v, color);

  // C
  if (segMap[digit][2])
    tft.fillRect(x + w + h, y + v + 2*h, h, v, color);

  // D
  if (segMap[digit][3])
    tft.fillRect(x + h, y + 2*v + 2*h, w, h, color);

  // E
  if (segMap[digit][4])
    tft.fillRect(x, y + v + 2*h, h, v, color);

  // F
  if (segMap[digit][5])
    tft.fillRect(x, y + h, h, v, color);

  // G
  if (segMap[digit][6])
    tft.fillRect(x + h, y + v + h, w, h, color);
}


void draw7SegNumber(
  int number,
  int cx,
  int cy,
  int scale,
  uint16_t color
) {
  String s = String(number);

  int digitW = (6 + 2) * scale;  // width + margins
  int digitH = (2 * 7 + 3) * scale;

  int spacing = 2 * scale;
  int totalW = s.length() * digitW + (s.length() - 1) * spacing;

  int x = cx - totalW / 2;
  int y = cy - digitH / 2;

  for (int i = 0; i < s.length(); i++) {
    draw7SegDigit(s[i] - '0', x, y, scale, color);
    x += digitW + spacing;
  }
}


int segCurrent = 0;
int segTarget = 0;
float segAnim = 1.0f;

void setSegNumber(int n) {
  if (n != segTarget) {
    segTarget = n;
    segAnim = 0.0f;
  }
}

void draw7SegSmooth(
  int cx,
  int cy,
  int scale,
  uint16_t color
) {
  if (segAnim < 1.0f) segAnim += 0.15f;
  if (segAnim > 1.0f) segAnim = 1.0f;

  int dy = (1.0f - segAnim) * 30;

  tft.fillCircle(cx, cy, 95, TFT_BLACK);

  draw7SegNumber(segCurrent, cx, cy - dy, scale, color);
  draw7SegNumber(segTarget, cx, cy + (30 - dy), scale, color);

  if (segAnim >= 1.0f)
    segCurrent = segTarget;
}



/* ================= INITIAL ORIENTATION ================= */
float qInit[4] = {1,0,0,0};
bool initOrientationCalibrated = false;
float gInitX = 0.0f, gInitY = 0.0f, gInitZ = 9.81f;
float gravityMag = 9.81f;   // calibrated at startup (M4 fix)

/* ================= MAHONY AHRS (dt-aware, B8) =================
   Replaces the MahonyAHRS library: it integrated the gyro with a FIXED
   500 Hz assumption, so whenever the real loop rate differed the attitude
   over/under-rotated — corrupting gravity subtraction exactly during
   rotation (the observed "position jumps when I rotate the device"). */
float q0g = 1.0f, q1g = 0.0f, q2g = 0.0f, q3g = 0.0f;
const float MAHONY_TWO_KP      = 1.0f;  // 2 × proportional gain while moving
const float MAHONY_TWO_KP_REST = 4.0f;  // stronger pull to gravity while still —
                                        // snaps residual tilt away after rotation
const float ACC_GATE_FRAC = 0.15f;    // skip accel correction when |a| deviates
                                      // >15% from gravity (centripetal forces)

/* Gyro bias: never calibrated before — rotation-test logs showed a truly
   still device with ZUPT only 39% active and a persistent 0.55 m/s² fake
   linear accel: uncorrected bias kept gyroMag above the ZUPT threshold and
   tilted Mahony's equilibrium off gravity. Averaged at boot, refined online
   while ZUPT confirms stillness (tracks temperature drift). */
float gyroBiasX = 0.0f, gyroBiasY = 0.0f, gyroBiasZ = 0.0f;  // [rad/s]
const float GYRO_BIAS_TAU = 10.0f;    // [s] online refinement time constant

void mahonyUpdateIMU(float gx, float gy, float gz,
                     float ax, float ay, float az, float dt, float twoKp) {
  // Accel tilt correction — only when the accelerometer is plausibly
  // measuring gravity alone. During fast rotation it also measures
  // centripetal/tangential force and would drag the attitude away.
  float norm = sqrtf(ax*ax + ay*ay + az*az);
  if (norm > 1e-6f && fabsf(norm - gravityMag) < ACC_GATE_FRAC * gravityMag) {
    float rn = 1.0f / norm;
    ax *= rn; ay *= rn; az *= rn;
    // estimated gravity direction in body frame from quaternion
    float vx = 2.0f*(q1g*q3g - q0g*q2g);
    float vy = 2.0f*(q0g*q1g + q2g*q3g);
    float vz = q0g*q0g - q1g*q1g - q2g*q2g + q3g*q3g;
    // error = measured × estimated
    gx += twoKp * (ay*vz - az*vy);
    gy += twoKp * (az*vx - ax*vz);
    gz += twoKp * (ax*vy - ay*vx);
  }
  // quaternion rate integration with the REAL dt
  float halfDt = 0.5f * dt;
  float qa = q0g, qb = q1g, qc = q2g, qd = q3g;
  q0g += (-qb*gx - qc*gy - qd*gz) * halfDt;
  q1g += ( qa*gx + qc*gz - qd*gy) * halfDt;
  q2g += ( qa*gy - qb*gz + qd*gx) * halfDt;
  q3g += ( qa*gz + qb*gy - qc*gx) * halfDt;
  float qn = 1.0f / sqrtf(q0g*q0g + q1g*q1g + q2g*q2g + q3g*q3g);
  q0g *= qn; q1g *= qn; q2g *= qn; q3g *= qn;
}

/* ================= VELOCITY / POSITION ================= */
float velX=0, velY=0, velZ=0;
float posX=0, posY=0, posZ=0;
float accX_f=0, accY_f=0, accZ_f=0;
float meanVelocity = 0.0f;
const float accelLPF = 0.70f;
const float VEL_DAMP_LAMBDA = 1.2f;   // [1/s] time-based velocity decay (loop-rate independent)
const float GYRO_DAMP_GAIN  = 3.0f;   // extra velocity damping per rad/s of rotation —
                                      // centripetal/lever-arm accel during rotation is
                                      // indistinguishable from linear motion
const float GYRO_FREEZE_TH  = 2.0f;   // [rad/s] freeze velocity integration while the
                                      // gyro ENVELOPE exceeds this (~115°/s). Rotation-test
                                      // data showed attitude tracks correctly (gyro↔euler
                                      // corr +0.98) — remaining drift came from real
                                      // hand-arc centripetal accel + integration error at
                                      // swing reversals where instantaneous ω dips to 0.
const float GYRO_ENV_TAU    = 0.4f;   // [s] envelope decay — bridges reversal gaps
float gyroEnv = 0.0f;

/* ================= ZUPT + ORIGIN (B8) ================= */
// Stationary = accel magnitude near gravity AND gyro near zero, sustained.
const float ZUPT_ACC_TH        = 0.25f;  // [m/s²] |accel| deviation from gravityMag
const float ZUPT_GYRO_TH       = 0.10f;  // [rad/s] gyro magnitude
const uint32_t ZUPT_TIME_MS    = 150;    // stillness before velocity hard-reset
const uint32_t ORIGIN_SETTLE_MS = 400;   // stillness before origin starts adapting
const float ORIGIN_TAU         = 1.5f;   // [s] origin convergence time constant

uint32_t stillStartMs = 0;               // 0 = currently moving
bool zuptActive = false;
bool originSeeded = false;
float originX = 0, originY = 0, originZ = 0;
float dispX = 0, dispY = 0, dispZ = 0, dispMag = 0;

/* ================= REP STATE MACHINE (B8) ================= */
const float REP_START_TH         = 0.05f;  // [m] leave origin by 5cm to start rep
const float REP_END_TH           = 0.03f;  // [m] absolute return threshold
const float REP_END_PEAK_FRAC    = 0.35f;  // adaptive end: below 35% of rep peak
const float REP_MIN_PEAK         = 0.08f;  // [m] min peak displacement to count
const uint32_t REP_MIN_DURATION_MS = 300;  // reject vibration spikes
const uint32_t REP_TIMEOUT_MS      = 8000; // stuck-ACTIVE recovery (drift escape)
const uint32_t REP_REFRACTORY_MS   = 250;  // min gap between counted reps

uint8_t repPhase = 0;        // 0=REST, 1=ACTIVE
float repPeakDisp = 0;
uint32_t repStartMs = 0;
uint32_t lastRepMs = 0;

/* ================= EULER ANGLES (B8) ================= */
float rollDeg = 0, pitchDeg = 0, yawDeg = 0;

/* ================= RHYTHM (legacy envelope, kept for ring color + app accuracy) ===== */
// volatile: written by the IMU loop (core 1), read by the display task (core 0)
volatile float accEnv = 0;
volatile int motionCount = 0;

/* thresholds (tune if needed) */
float slowTh = 0.2;
float fastTh = 3.80;
uint16_t ring_color = 0x5E89;

/* ================= DEBUG STREAM (serial CSV @ 50 Hz) ================= */
uint32_t lastDbgMs = 0;
/* ================= TIMING ================= */
unsigned long lastIMU=0;

/* ================= INITIAL ORIENTATION CALIBRATION ================= */
void calibrateInitialOrientation() {
  DBG_PRINTLN("Hold device still...");
  const int N = 400;
  float ax=0, ay=0, az=0;
  float gxs=0, gys=0, gzs=0;

  for(int i=0;i<N;i++){
    if(imu.readSensorData(imuData)){
      ax += imuData.accelX;
      ay += imuData.accelY;
      az += imuData.accelZ;
      gxs += imuData.gyroX;
      gys += imuData.gyroY;
      gzs += imuData.gyroZ;
    }
    delay(5);
  }

  // gyro bias from the same still window (gyro unit is dps here)
  gyroBiasX = (gxs / N) * DEG_TO_RAD;
  gyroBiasY = (gys / N) * DEG_TO_RAD;
  gyroBiasZ = (gzs / N) * DEG_TO_RAD;

  ax/=N; ay/=N; az/=N;
  float norm = sqrt(ax*ax + ay*ay + az*az);
  gravityMag = norm;   // calibrated gravity magnitude (M4 fix)
  ax/=norm; ay/=norm; az/=norm;

  float s2 = (1.0f - az) * 2.0f;
  if (s2 < 1e-6f) {
    // device already level (az ≈ +1) — identity rotation (C1 fix)
    qInit[0] = 1; qInit[1] = 0; qInit[2] = 0; qInit[3] = 0;
  } else {
    float s = sqrt(s2);
    qInit[0] = s/2;
    qInit[1] = ay/s;
    qInit[2] = -ax/s;
    qInit[3] = 0;
  }

  initOrientationCalibrated = true;
  // Mahony's earth frame has gravity on +Z by construction, so the linear-
  // acceleration reference is simply (0,0,gravityMag). Rotating it by qInit
  // (previous code) injected a constant ax/ay bias whenever the device did
  // not boot lying flat — the source of steady position drift at rest.
  gInitX = 0.0f;
  gInitY = 0.0f;
  gInitZ = gravityMag;
  DBG_PRINTLN("Initial orientation OK");
}

/* ================= ROTATION ================= */
void rotateToEarth(float ax,float ay,float az,float q[4],
                   float &x,float &y,float &z){
  float q0=q[0], q1=q[1], q2=q[2], q3=q[3];
  x = (1-2*q2*q2-2*q3*q3)*ax + (2*q1*q2-2*q0*q3)*ay + (2*q1*q3+2*q0*q2)*az;
  y = (2*q1*q2+2*q0*q3)*ax + (1-2*q1*q1-2*q3*q3)*ay + (2*q2*q3-2*q0*q1)*az;
  z = (2*q1*q3-2*q0*q2)*ax + (2*q2*q3+2*q0*q1)*ay + (1-2*q1*q1-2*q2*q2)*az;
}

/* ================= DISPLAY TASK (core 0, B8) =================
   A full ring redraw takes ~200ms and was starving the IMU loop down to
   ~4.5 Hz. TFT rendering now runs on core 0 while the IMU/BLE loop stays
   on core 1. Only this task touches the TFT after setup() finishes. */
void displayTask(void *param) {
  int lastCount = -1;
  uint16_t lastColor = 0xFFFF;
  for (;;) {
    int count = motionCount;   // 32-bit reads are atomic on ESP32
    float env = accEnv;

    float normEnv = (env - slowTh) / (fastTh - slowTh);
    if (normEnv < 0) normEnv = 0;
    if (normEnv > 1) normEnv = 1;
    // quantize so the ring is only redrawn on visible color steps
    normEnv = roundf(normEnv * 12.0f) / 12.0f;

    uint8_t r, g, b;
    if (normEnv < 0.5f) {
      // Blue -> Green
      float t = normEnv / 0.5f;
      r = 0;
      g = (uint8_t)(t * 255);
      b = (uint8_t)((1 - t) * 255);
    } else {
      // Green -> Red
      float t = (normEnv - 0.5f) / 0.5f;
      r = (uint8_t)(t * 255);
      g = (uint8_t)((1 - t) * 255);
      b = 0;
    }
    uint16_t color = tft.color565(r, g, b);

    if (count != lastCount || color != lastColor) {
      if (count != lastCount) {
        tft.fillCircle(120, 120, 100, TFT_BLACK);  // clear center only
      }
      for (int rad = 105; rad < 121; rad++) {
        tft.drawSmoothCircle(120, 120, rad, color, color);
      }
      draw7SegNumber(count, 120, 120, 6, color);
      lastCount = count;
      lastColor = color;
    }
    vTaskDelay(pdMS_TO_TICKS(50));
  }
}

/* ================= SETUP ================= */
void setup() {
#if DEBUG_STREAM
  // 24-column CSV @50Hz needs ~10 KB/s — at 115200 baud Serial.printf was
  // blocking the loop (rate fell to ~40 Hz, attitude lagged during rotation)
  Serial.begin(921600);
#else
  Serial.begin(115200);
#endif
  delay(300);

  Wire.begin(6,7);
  Wire.setClock(400000);   // 400 kHz fast mode — I2C reads were a big chunk of loop time
  imu.begin(Wire);
  imu.setAccelRange(QMI8658_ACCEL_RANGE_4G);
  imu.setGyroRange(QMI8658_GYRO_RANGE_1024DPS);  // 512dps clipped at measured 533°/s swings
  imu.setAccelODR(QMI8658_ACCEL_ODR_1000HZ);
  imu.setGyroODR(QMI8658_GYRO_ODR_1000HZ);
  imu.setAccelUnit_mps2(true);
  imu.setGyroUnit_rads(false);
  imu.enableSensors(QMI8658_ENABLE_ACCEL | QMI8658_ENABLE_GYRO);

  pinMode(40, OUTPUT);
  digitalWrite(40, HIGH);

  tft.init();
  tft.setRotation(0);
  tft.fillScreen(TFT_BLACK);
  for(int r = 110; r < 121; r++){
    tft.drawSmoothCircle(120, 120, r, ring_color, ring_color);
  }
#if USE_BOOT_LOGO
  drawLogo200(0, 0);
  for(int r = 110; r < 121; r++){
    tft.drawSmoothCircle(120, 120, r, ring_color, ring_color);
  }
  delay(5000);
#endif
  calibrateInitialOrientation();

  // Seed Mahony with the measured boot orientation so its earth frame is
  // valid immediately instead of converging from identity over seconds.
  q0g = qInit[0];
  q1g = qInit[1];
  q2g = qInit[2];
  q3g = qInit[3];

#if DEBUG_STREAM
  // Metadata for tools/imu_debug_viewer.py — lines starting with '#'
  Serial.println();
  Serial.println("# GYMPATH IMU DEBUG STREAM v1");
  Serial.printf("# CALIB fw=" FW_BUILD " qInit=%.4f,%.4f,%.4f,%.4f gravityMag=%.4f gInit=%.4f,%.4f,%.4f gyroBias=%.4f,%.4f,%.4f\n",
                qInit[0], qInit[1], qInit[2], qInit[3],
                gravityMag, gInitX, gInitY, gInitZ,
                gyroBiasX, gyroBiasY, gyroBiasZ);
  Serial.println("# COLUMNS t,ax,ay,az,vx,vy,vz,px,py,pz,ox,oy,oz,disp,roll,pitch,yaw,env,phase,zupt,reps,rax,ray,raz,rgx,rgy,rgz");
#endif

  tft.fillScreen(TFT_BLACK);



  lastIMU = millis();
  setupBLE();

  // TFT rendering moves to core 0; the IMU/BLE loop stays on core 1
  xTaskCreatePinnedToCore(displayTask, "display", 6144, NULL, 1, NULL, 0);
}

/* ================= LOOP ================= */
void loop() {
  unsigned long now = millis();
  float dt = (now-lastIMU)*0.001f;
  if(dt<=0) dt=0.01;
  if(dt>0.05f) dt=0.05f;   // clamp stalls — no giant integration steps
  lastIMU = now;

  if(!imu.readSensorData(imuData)) return;

  float ax = imuData.accelX;
  float ay = imuData.accelY;
  float az = imuData.accelZ;

  float gx = imuData.gyroX*DEG_TO_RAD - gyroBiasX;
  float gy = imuData.gyroY*DEG_TO_RAD - gyroBiasY;
  float gz = imuData.gyroZ*DEG_TO_RAD - gyroBiasZ;

  // stronger gravity pull while confirmed still (zuptActive lags one tick)
  mahonyUpdateIMU(gx, gy, gz, ax, ay, az, dt,
                  zuptActive ? MAHONY_TWO_KP_REST : MAHONY_TWO_KP);

  float q[4] = {q0g, q1g, q2g, q3g};

  float ax_e, ay_e, az_e;
  rotateToEarth(ax,ay,az,q,ax_e,ay_e,az_e);
  float ax_lin = ax_e - gInitX;
  float ay_lin = ay_e - gInitY;
  float az_lin = az_e - gInitZ;

  // simple low-pass filter
  accX_f = accelLPF * accX_f + (1.0f - accelLPF) * ax_lin;
  accY_f = accelLPF * accY_f + (1.0f - accelLPF) * ay_lin;
  accZ_f = accelLPF * accZ_f + (1.0f - accelLPF) * az_lin;

  /* ===== ZUPT — Zero Velocity Update (B8) =====
     Checked BEFORE integration so a stationary device cannot leak
     bias-driven velocity into position within the same tick. */
  // rotation preserves vector norm, so body-frame magnitude == earth-frame magnitude
  float accelMag = sqrt(ax*ax + ay*ay + az*az);
  float gyroMag  = sqrt(gx*gx + gy*gy + gz*gz);
  // rotation envelope: holds the recent gyro peak across swing reversals
  gyroEnv *= expf(-dt / GYRO_ENV_TAU);
  if (gyroMag > gyroEnv) gyroEnv = gyroMag;
  bool stationaryNow = (fabs(accelMag - gravityMag) < ZUPT_ACC_TH)
                    && (gyroMag < ZUPT_GYRO_TH);

  if (stationaryNow) {
    if (stillStartMs == 0) stillStartMs = now;
  } else {
    stillStartMs = 0;
    zuptActive = false;
  }

  if (stillStartMs != 0 && (now - stillStartMs) >= ZUPT_TIME_MS) {
    zuptActive = true;

    // refine gyro bias while confirmed still (gx/gy/gz are the corrected
    // residuals, so this is an EMA of the remaining bias)
    float kb = dt / GYRO_BIAS_TAU;
    if (kb > 1.0f) kb = 1.0f;
    gyroBiasX += gx * kb;
    gyroBiasY += gy * kb;
    gyroBiasZ += gz * kb;

    /* ===== ORIGIN ESTIMATION (B8) ===== */
    if ((now - stillStartMs) >= ORIGIN_SETTLE_MS) {
      if (!originSeeded) {
        originX = posX; originY = posY; originZ = posZ;
        originSeeded = true;
      } else {
        float k = dt / ORIGIN_TAU;
        if (k > 1.0f) k = 1.0f;
        originX += (posX - originX) * k;
        originY += (posY - originY) * k;
        originZ += (posZ - originZ) * k;
      }
    }
  }

  if (zuptActive || gyroEnv > GYRO_FREEZE_TH) {
    // hard reset — velocity zeroed and position frozen while at rest,
    // AND during fast-rotation episodes (envelope, so reversal moments
    // where instantaneous ω dips to zero stay frozen too): the
    // accelerometer is then dominated by hand-arc centripetal force
    velX = 0; velY = 0; velZ = 0;
  } else {
    velX += accX_f * dt;
    velY += accY_f * dt;
    velZ += accZ_f * dt;
    // trust velocity less while rotating fast
    float damp = expf(-(VEL_DAMP_LAMBDA * (1.0f + GYRO_DAMP_GAIN * gyroMag)) * dt);
    velX *= damp;
    velY *= damp;
    velZ *= damp;

    posX += velX * dt;
    posY += velY * dt;
    posZ += velZ * dt;
  }

  /* ===== 3D DISPLACEMENT FROM ORIGIN (B8) ===== */
  dispX = posX - originX;
  dispY = posY - originY;
  dispZ = posZ - originZ;
  dispMag = sqrt(dispX*dispX + dispY*dispY + dispZ*dispZ);

  /* ===== ENVELOPE (ring color + app accuracy metric) ===== */
  float mag = fabs(accelMag - gravityMag);
  accEnv = 0.60*accEnv + 0.40*mag;

  /* ===== DISPLACEMENT-BASED REP DETECTION (B8) ===== */
  if (repPhase == 0) {            // REST
    if (originSeeded && dispMag > REP_START_TH
        && (now - lastRepMs) > REP_REFRACTORY_MS) {
      repPhase = 1;
      repStartMs = now;
      repPeakDisp = dispMag;
    }
  } else {                        // ACTIVE
    if (dispMag > repPeakDisp) repPeakDisp = dispMag;
    float endTh = REP_END_PEAK_FRAC * repPeakDisp;
    if (endTh < REP_END_TH) endTh = REP_END_TH;
    if (dispMag < endTh) {
      if (repPeakDisp >= REP_MIN_PEAK
          && (now - repStartMs) >= REP_MIN_DURATION_MS) {
        motionCount++;            // rep = leave origin → move → return
        lastRepMs = now;
      }
      repPhase = 0;
      repPeakDisp = 0;
    } else if ((now - repStartMs) > REP_TIMEOUT_MS) {
      // drift escaped the end threshold — re-anchor origin here, no count
      originX = posX; originY = posY; originZ = posZ;
      repPhase = 0;
      repPeakDisp = 0;
    }
  }

  meanVelocity = 0.85f * meanVelocity
               + 0.15f * sqrt(velX*velX + velY*velY + velZ*velZ);

  /* ===== EULER ZYX FROM MAHONY QUATERNION (B8) =====
     Shared by BLE packet + debug stream. Yaw is relative and drifts
     slowly (6-axis IMU, no magnetometer). */
  float sinp = 2.0f*(q[0]*q[2] - q[3]*q[1]);
  if (sinp > 1.0f) sinp = 1.0f;        // clamp avoids NaN at gimbal lock
  if (sinp < -1.0f) sinp = -1.0f;
  rollDeg  = atan2f(2.0f*(q[0]*q[1] + q[2]*q[3]),
                    1.0f - 2.0f*(q[1]*q[1] + q[2]*q[2])) * RAD_TO_DEG;
  pitchDeg = asinf(sinp) * RAD_TO_DEG;
  yawDeg   = atan2f(2.0f*(q[0]*q[3] + q[1]*q[2]),
                    1.0f - 2.0f*(q[2]*q[2] + q[3]*q[3])) * RAD_TO_DEG;

#if DEBUG_STREAM
  /* ===== SERIAL DEBUG STREAM for tools/imu_debug_viewer.py =====
     5ms gate → every fresh IMU sample passes (line t-deltas then expose the
     TRUE sensor ODR; fits 921600 baud up to ~200 Hz) */
  if (now - lastDbgMs >= 5) {
    lastDbgMs = now;
    Serial.printf("%lu,%.3f,%.3f,%.3f,%.3f,%.3f,%.3f,"
                  "%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,%.4f,"
                  "%.1f,%.1f,%.1f,%.3f,%u,%u,%d,"
                  "%.3f,%.3f,%.3f,%.4f,%.4f,%.4f\n",
                  now,
                  ax_lin, ay_lin, az_lin,
                  velX, velY, velZ,
                  posX, posY, posZ,
                  originX, originY, originZ,
                  dispMag,
                  rollDeg, pitchDeg, yawDeg,
                  accEnv,
                  (unsigned)repPhase,
                  (unsigned)(zuptActive ? 1 : 0),
                  motionCount,
                  ax, ay, az,    // raw body-frame accel [m/s²]
                  gx, gy, gz);   // bias-corrected gyro [rad/s]
  }
#endif

  // display rendering runs in displayTask on core 0 (B8)

  DBG_PRINT("ENV: "); DBG_PRINTF(accEnv,3);
  DBG_PRINT("  DISP: "); DBG_PRINTF(dispMag,3);
  DBG_PRINT("  COUNT: "); DBG_PRINTLN(motionCount);

  // BLE notify @ 50Hz
  // Gate on the actual connected count, not the deviceConnected flag: newer
  // NimBLE-Arduino versions don't call the old onConnect signatures, so the
  // flag could stay false and no packets would ever be sent. Also re-advertise
  // on disconnect without relying on the (possibly-uncalled) onDisconnect.
  bool bleConnected = (bleServer && bleServer->getConnectedCount() > 0);
  static bool wasBleConnected = false;
  if (wasBleConnected && !bleConnected) {
    NimBLEDevice::getAdvertising()->start();
  }
  wasBleConnected = bleConnected;

  if (bleConnected && motionChar != nullptr) {
    if (now - lastBleMs >= 20) {
      lastBleMs = now;

      MotionPacket pkt;
      pkt.ts_ms = now;
      pkt.ax = ax_lin;
      pkt.ay = ay_lin;
      pkt.az = az_lin;
      pkt.gx = gx;
      pkt.gy = gy;
      pkt.gz = gz;
      pkt.accEnv = accEnv;
      pkt.velX = velX;
      pkt.velY = velY;
      pkt.velZ = velZ;
      pkt.posX = posX;
      pkt.posY = posY;
      pkt.posZ = posZ;
      pkt.motionCount = motionCount;
      pkt.roll = rollDeg;
      pkt.pitch = pitchDeg;
      pkt.yaw = yawDeg;
      pkt.originX = originX;
      pkt.originY = originY;
      pkt.originZ = originZ;
      pkt.dx = dispX;
      pkt.dy = dispY;
      pkt.dz = dispZ;
      pkt.dispMag = dispMag;
      pkt.repPhase = repPhase;
      pkt.zuptActive = zuptActive ? 1 : 0;
      pkt._pad = 0;
      motionChar->setValue((uint8_t*)&pkt, sizeof(pkt));
      motionChar->notify();
      if (repChar && motionCount != lastRepSent) {
        lastRepSent = motionCount;
        int32_t repVal = lastRepSent;   // local copy (motionCount is volatile)
        repChar->setValue((uint8_t*)&repVal, sizeof(repVal));
        repChar->notify();
      }
      if (velChar) {
        velChar->setValue((uint8_t*)&meanVelocity, sizeof(meanVelocity));
        velChar->notify();
      }
    }
  }

  delay(1);
}
