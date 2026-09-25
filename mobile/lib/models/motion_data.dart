import 'dart:typed_data';

class MotionData {
  final int timestampMs;
  final double ax;
  final double ay;
  final double az;
  final double gx;
  final double gy;
  final double gz;
  final double accEnv;
  final double velX;
  final double velY;
  final double velZ;
  final double posX;
  final double posY;
  final double posZ;
  final int motionCount;

  // v2 fields (B8 firmware, packet >= 104 bytes). Defaults when v1 firmware.
  final bool isV2;
  final double roll;
  final double pitch;
  final double yaw;
  final double originX;
  final double originY;
  final double originZ;
  final double dx;
  final double dy;
  final double dz;
  final double dispMag;
  final int repPhase; // 0=REST, 1=ACTIVE
  final bool zuptActive;

  MotionData({
    required this.timestampMs,
    required this.ax,
    required this.ay,
    required this.az,
    required this.gx,
    required this.gy,
    required this.gz,
    required this.accEnv,
    required this.velX,
    required this.velY,
    required this.velZ,
    required this.posX,
    required this.posY,
    required this.posZ,
    required this.motionCount,
    this.isV2 = false,
    this.roll = 0,
    this.pitch = 0,
    this.yaw = 0,
    this.originX = 0,
    this.originY = 0,
    this.originZ = 0,
    this.dx = 0,
    this.dy = 0,
    this.dz = 0,
    this.dispMag = 0,
    this.repPhase = 0,
    this.zuptActive = false,
  });

  static MotionData? fromBytes(Uint8List bytes) {
    const int v1Length = 60;
    const int v2Length = 104;
    if (bytes.lengthInBytes < v1Length) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    int o = 0;
    final ts = data.getUint32(o, Endian.little);
    o += 4;
    final ax = data.getFloat32(o, Endian.little); o += 4;
    final ay = data.getFloat32(o, Endian.little); o += 4;
    final az = data.getFloat32(o, Endian.little); o += 4;
    final gx = data.getFloat32(o, Endian.little); o += 4;
    final gy = data.getFloat32(o, Endian.little); o += 4;
    final gz = data.getFloat32(o, Endian.little); o += 4;
    final accEnv = data.getFloat32(o, Endian.little); o += 4;
    final velX = data.getFloat32(o, Endian.little); o += 4;
    final velY = data.getFloat32(o, Endian.little); o += 4;
    final velZ = data.getFloat32(o, Endian.little); o += 4;
    final posX = data.getFloat32(o, Endian.little); o += 4;
    final posY = data.getFloat32(o, Endian.little); o += 4;
    final posZ = data.getFloat32(o, Endian.little); o += 4;
    final count = data.getInt32(o, Endian.little); o += 4;

    final isV2 = bytes.lengthInBytes >= v2Length;
    double roll = 0, pitch = 0, yaw = 0;
    double originX = 0, originY = 0, originZ = 0;
    double dx = 0, dy = 0, dz = 0, dispMag = 0;
    int repPhase = 0;
    bool zuptActive = false;
    if (isV2) {
      roll = data.getFloat32(o, Endian.little); o += 4;
      pitch = data.getFloat32(o, Endian.little); o += 4;
      yaw = data.getFloat32(o, Endian.little); o += 4;
      originX = data.getFloat32(o, Endian.little); o += 4;
      originY = data.getFloat32(o, Endian.little); o += 4;
      originZ = data.getFloat32(o, Endian.little); o += 4;
      dx = data.getFloat32(o, Endian.little); o += 4;
      dy = data.getFloat32(o, Endian.little); o += 4;
      dz = data.getFloat32(o, Endian.little); o += 4;
      dispMag = data.getFloat32(o, Endian.little); o += 4;
      repPhase = data.getUint8(o); o += 1;
      zuptActive = data.getUint8(o) != 0;
    }

    return MotionData(
      timestampMs: ts,
      ax: ax,
      ay: ay,
      az: az,
      gx: gx,
      gy: gy,
      gz: gz,
      accEnv: accEnv,
      velX: velX,
      velY: velY,
      velZ: velZ,
      posX: posX,
      posY: posY,
      posZ: posZ,
      motionCount: count,
      isV2: isV2,
      roll: roll,
      pitch: pitch,
      yaw: yaw,
      originX: originX,
      originY: originY,
      originZ: originZ,
      dx: dx,
      dy: dy,
      dz: dz,
      dispMag: dispMag,
      repPhase: repPhase,
      zuptActive: zuptActive,
    );
  }
}
