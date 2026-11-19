// TFT_eSPI setup for the Gympath tracker board: Waveshare ESP32-S3-LCD-1.28
// (round 240x240 GC9A01A, QMI8658 on I2C SDA 6 / SCL 7, backlight GPIO 40,
// driven by the sketch). Copy over libraries/TFT_eSPI/User_Setup.h before
// building; the firmware CI (.github/workflows/firmware.yml) does this.
// Pins: https://docs.waveshare.com/ESP32-S3-LCD-1.28
#define GC9A01_DRIVER

#define TFT_WIDTH  240
#define TFT_HEIGHT 240

#define TFT_MISO -1
#define TFT_MOSI 11
#define TFT_SCLK 10
#define TFT_CS    9
#define TFT_DC    8
#define TFT_RST  12

#define LOAD_GLCD
#define LOAD_FONT2
#define LOAD_FONT4
#define LOAD_FONT6
#define LOAD_FONT7
#define LOAD_FONT8
#define LOAD_GFXFF
#define SMOOTH_FONT

#define SPI_FREQUENCY  40000000
#define SPI_READ_FREQUENCY 20000000
