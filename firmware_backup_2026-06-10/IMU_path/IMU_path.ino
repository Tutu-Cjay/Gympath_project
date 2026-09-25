#include <Wire.h>
#include <QMI8658.h>
#include <MahonyAHRS.h>
#include <TFT_eSPI.h>
#include <math.h>
#include <NimBLEDevice.h>

// ===== Size reduction toggles =====
#define USE_BOOT_LOGO 1  // set to 1 to show logo (adds ~450KB flash)
#define ENABLE_SERIAL 0   // set to 1 to enable Serial prints

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
Mahony filter;
TFT_eSPI tft;

/* ================= BLE ================= */
#define SERVICE_UUID       "12345678-1234-5678-1234-56789abcdef0"
#define MOTION_CHAR_UUID   "12345678-1234-5678-1234-56789abcdef1"
#define REP_CHAR_UUID      "12345678-1234-5678-1234-56789abcdef2"
#define VEL_CHAR_UUID      "12345678-1234-5678-1234-56789abcdef3"

struct __attribute__((packed)) MotionPacket {
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

/* ================= VELOCITY / POSITION ================= */
float velX=0, velY=0, velZ=0;
float posX=0, posY=0, posZ=0;
float accX_f=0, accY_f=0, accZ_f=0;
float meanVelocity = 0.0f;
int restCounter = 0;
const float accelLPF = 0.70f;
const float velDamp = 0.98f;
const float posDamp = 0.995f;

/* ================= RHYTHM ================= */
float accEnv = 0;
int motionCount = 0;
int prevMotionCount = -1;
bool beatLock = false;

/* thresholds (tune if needed) */
float slowTh = 0.2;
float goodTh = 1.0;
float fastTh = 3.80;
uint16_t ring_color = 0x5E89;
/* ================= TIMING ================= */
unsigned long lastIMU=0;

/* ================= INITIAL ORIENTATION CALIBRATION ================= */
void calibrateInitialOrientation() {
  DBG_PRINTLN("Hold device still...");
  const int N = 400;
  float ax=0, ay=0, az=0;

  for(int i=0;i<N;i++){
    if(imu.readSensorData(imuData)){
      ax += imuData.accelX;
      ay += imuData.accelY;
      az += imuData.accelZ;
    }
    delay(5);
  }

  ax/=N; ay/=N; az/=N;
  float norm = sqrt(ax*ax + ay*ay + az*az);
  ax/=norm; ay/=norm; az/=norm;

  float s = sqrt((1 - az) * 2);
  qInit[0] = s/2;
  qInit[1] = ay/s;
  qInit[2] = -ax/s;
  qInit[3] = 0;

  initOrientationCalibrated = true;
  rotateToEarth(0, 0, 9.81, qInit, gInitX, gInitY, gInitZ);
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

/* ================= SETUP ================= */
void setup() {
  Serial.begin(115200);
  delay(300);

  Wire.begin(6,7);
  imu.begin(Wire);
  imu.setAccelRange(QMI8658_ACCEL_RANGE_4G);
  imu.setGyroRange(QMI8658_GYRO_RANGE_512DPS);
  imu.setAccelODR(QMI8658_ACCEL_ODR_1000HZ);
  imu.setGyroODR(QMI8658_GYRO_ODR_1000HZ);
  imu.setAccelUnit_mps2(true);
  imu.setGyroUnit_rads(false);
  imu.enableSensors(QMI8658_ENABLE_ACCEL | QMI8658_ENABLE_GYRO);

  filter.begin(500.0f);   // 100 Hz
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

  tft.fillScreen(TFT_BLACK);



  lastIMU = millis();
  setupBLE();
}

/* ================= LOOP ================= */
void loop() {
  unsigned long now = millis();
  float dt = (now-lastIMU)*0.001f;
  if(dt<=0) dt=0.01;
  lastIMU = now;

  if(!imu.readSensorData(imuData)) return;

  float ax = imuData.accelX;
  float ay = imuData.accelY;
  float az = imuData.accelZ;

  float gx = imuData.gyroX*DEG_TO_RAD;
  float gy = imuData.gyroY*DEG_TO_RAD;
  float gz = imuData.gyroZ*DEG_TO_RAD;

  filter.updateIMU(gx,gy,gz,ax,ay,az);

  float q[4] = {filter.q0,filter.q1,filter.q2,filter.q3};

  float ax_e, ay_e, az_e;
  rotateToEarth(ax,ay,az,q,ax_e,ay_e,az_e);
  float ax_lin = ax_e - gInitX;
  float ay_lin = ay_e - gInitY;
  float az_lin = az_e - gInitZ;

  // simple low-pass filter
  accX_f = accelLPF * accX_f + (1.0f - accelLPF) * ax_lin;
  accY_f = accelLPF * accY_f + (1.0f - accelLPF) * ay_lin;
  accZ_f = accelLPF * accZ_f + (1.0f - accelLPF) * az_lin;

  // integrate to velocity and position
  velX += accX_f * dt;
  velY += accY_f * dt;
  velZ += accZ_f * dt;
  velX *= velDamp;
  velY *= velDamp;
  velZ *= velDamp;

  posX += velX * dt;
  posY += velY * dt;
  posZ += velZ * dt;

  /* ===== RHYTHM ===== */
  float mag = fabs(sqrt(ax_e*ax_e + ay_e*ay_e + az_e*az_e)-9.81);
  accEnv = 0.60*accEnv + 0.40*mag;
    // accEnv = mag;

  if(accEnv > goodTh && !beatLock){
    motionCount++;
    beatLock = true;
  }
  if(accEnv < 0.8) beatLock=false;
  if (accEnv < slowTh) {
    restCounter++;
  } else {
    restCounter = 0;
  }
  if (restCounter > 10) {
    velX = 0; velY = 0; velZ = 0;
    posX *= posDamp; posY *= posDamp; posZ *= posDamp;
  }

  meanVelocity = 0.85f * meanVelocity + 0.15f * fabs(velZ);

  /* ===== DYNAMIC COLOR BLENDING ONLY ===== */
  uint16_t color;
  float normEnv = (accEnv - slowTh) / (fastTh - slowTh);
  if(normEnv < 0) normEnv = 0;
  if(normEnv > 1) normEnv = 1;

  uint8_t r, g, b;
  if(normEnv < 0.5){ 
    // Blue -> Green
    float t = normEnv / 0.5;
    r = 0;
    g = (uint8_t)(t * 255);
    b = (uint8_t)((1-t) * 255);
  } else {
    // Green -> Red
    float t = (normEnv - 0.5) / 0.5;
    r = (uint8_t)(t * 255);
    g = (uint8_t)((1-t) * 255);
    b = 0;
  }

  color = tft.color565(r, g, b);

  /* ===== DISPLAY ===== */
//   tft.fillScreen(TFT_BLACK);  // clear previous frame
/* ===== DISPLAY ===== */
    if (motionCount != prevMotionCount) {
       tft.fillCircle(120, 120, 100, TFT_BLACK);  // clear center only
       prevMotionCount = motionCount; 
    }
    // draw outer ring FIRST
    for(int r = 105; r < 121; r++){
    tft.drawSmoothCircle(120, 120, r, color, color);
    }

    // draw number LAST
    draw7SegNumber(motionCount, 120, 120, 6, color);
    // if (motionCount != segTarget)
    //   setSegNumber(motionCount);

    // draw7SegSmooth(120, 120, 6, color);


  DBG_PRINT("ENV: "); DBG_PRINTF(accEnv,3);
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
      motionChar->setValue((uint8_t*)&pkt, sizeof(pkt));
      motionChar->notify();
      if (repChar && motionCount != lastRepSent) {
        lastRepSent = motionCount;
        repChar->setValue((uint8_t*)&motionCount, sizeof(motionCount));
        repChar->notify();
      }
      if (velChar) {
        velChar->setValue((uint8_t*)&meanVelocity, sizeof(meanVelocity));
        velChar->notify();
      }
    }
  }

  delay(2);
}
