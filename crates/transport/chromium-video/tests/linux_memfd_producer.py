"""Send two invalid descriptors followed by one immutable, odd-sized BGRA frame."""
import array
import fcntl
import os
import socket
import struct
import sys

peer = socket.socket(socket.AF_UNIX, socket.SOCK_SEQPACKET)
peer.settimeout(10)
peer.connect("\0" + sys.argv[1])
magic, version, kinds, *_ = struct.unpack("=III16s16s", peer.recv(44))
assert kinds & 2
width, height = 257, 193
pixels = bytes((200, 120, 32, 255)) * (width * height)
seals = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_GROW
for seq, extra, sealed in [(1, 0, False), (2, 4, True), (3, 0, True)]:
    fd = os.memfd_create("frame", os.MFD_ALLOW_SEALING)
    os.write(fd, pixels + bytes(extra))
    if sealed:
        fcntl.fcntl(fd, fcntl.F_ADD_SEALS, seals)
    header = struct.pack("=8I2Q", magic, version, 2, width, height, 1, 0, 0, seq, len(pixels))
    peer.sendmsg([header], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", [fd]))])
    os.close(fd)
    assert struct.unpack("=Q", peer.recv(8))[0] == seq
