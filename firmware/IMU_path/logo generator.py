from PIL import Image

# CONFIG
INPUT_IMAGE = "./logo_3.png"   # <-- your image
OUTPUT_FILE = "logo200.h"
W, H = 240, 240

def rgb888_to_rgb565(r, g, b):
    return ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)

img = Image.open(INPUT_IMAGE).convert("RGB")
img = img.resize((W, H), Image.LANCZOS)

with open(OUTPUT_FILE, "w") as f:
    f.write("#pragma once\n")
    f.write("#include <stdint.h>\n\n")
    f.write("const uint16_t logo200[240][240] = {\n")

    for y in range(H):
        f.write("  {")
        for x in range(W):
            r, g, b = img.getpixel((x, y))
            c = rgb888_to_rgb565(r, g, b)
            f.write(f"0x{c:04X}")
            if x < W - 1:
                f.write(", ")
        f.write("}")
        if y < H - 1:
            f.write(",")
        f.write("\n")

    f.write("};\n")

print("logo200.h generated successfully")
