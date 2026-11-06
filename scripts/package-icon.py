"""Package the generated PNG representations into a modern ICNS container."""
from pathlib import Path
import struct
import sys

source, destination = map(Path, sys.argv[1:])
representations = {
    b"ic07": "icon_128x128.png",
    b"ic08": "icon_256x256.png",
    b"ic09": "icon_512x512.png",
    b"ic10": "icon_512x512@2x.png",
    b"ic11": "icon_16x16@2x.png",
    b"ic12": "icon_32x32@2x.png",
    b"ic13": "icon_128x128@2x.png",
    b"ic14": "icon_256x256@2x.png",
}
chunks = []
for key, filename in representations.items():
    data = (source / filename).read_bytes()
    chunks.append(key + struct.pack(">I", len(data) + 8) + data)
payload = b"".join(chunks)
destination.write_bytes(b"icns" + struct.pack(">I", len(payload) + 8) + payload)
