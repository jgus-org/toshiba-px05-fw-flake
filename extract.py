#!/usr/bin/env python3
"""Extract the raw Toshiba microcode from a Dell SAS-drive firmware DUP."""
import sys, io, gzip, tarfile, struct, hashlib

src, out = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()

# The DUP is a shell stub followed by a gzipped tar after this marker.
marker = b"#####Startofarchive#####"
pos = data.rfind(marker)
if pos < 0:
    sys.exit("archive marker not found")
gz = data.find(b"\x1f\x8b\x08", pos)
if gz < 0:
    sys.exit("gzip stream not found after marker")

tf = tarfile.open(fileobj=io.BytesIO(data[gz:]), mode="r:gz")
member = next((m for m in tf.getmembers() if m.name.endswith(".fwh")), None)
if member is None:
    sys.exit("no .fwh image in DUP payload")
fwh = tf.extractfile(member).read()

# The .fwh is the raw Toshiba image behind a 1024-byte Dell header (model table + zero pad).
raw = fwh[0x400:]
if raw[:8] != b"PM04DHWF":
    sys.exit("unexpected firmware signature: %r" % raw[:8])
declared = struct.unpack_from("<I", raw, 0xFC)[0]
if declared != len(raw):
    sys.exit("image length field %d != actual %d" % (declared, len(raw)))

EXPECT = "0ead7c04075cbb1c7602cbdf1cf7e65b382e29cc61ab2ff9a86398d8ff98c799"
got = hashlib.sha256(raw).hexdigest()
if got != EXPECT:
    sys.exit("sha256 %s != expected %s" % (got, EXPECT))

open(out, "wb").write(raw)
print("extracted %s: %d bytes, sha256 %s" % (member.name, len(raw), got))
