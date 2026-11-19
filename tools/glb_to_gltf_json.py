"""Turn a .glb into a self-contained glTF JSON file (buffer as a data URI).

Used for the web preview, whose host serves JSON but not binary model files:
the 3D viewer reads either form. Usage: glb_to_gltf_json.py in.glb out.json
"""
import base64
import json
import struct
import sys

src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
magic, version, length = struct.unpack("<4sII", data[:12])
assert magic == b"glTF" and version == 2, "not a glTF 2.0 binary"
pos, gltf, binary = 12, None, b""
while pos < length:
    size, kind = struct.unpack("<I4s", data[pos:pos + 8])
    chunk = data[pos + 8:pos + 8 + size]
    if kind == b"JSON":
        gltf = json.loads(chunk)
    elif kind == b"BIN\x00":
        binary = chunk
    pos += 8 + size
gltf["buffers"][0]["uri"] = "data:application/octet-stream;base64," + base64.b64encode(binary).decode()
json.dump(gltf, open(dst, "w"), separators=(",", ":"))
