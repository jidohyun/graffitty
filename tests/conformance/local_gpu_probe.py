"""Native GPU import probe using the production Mach/Metal implementation.

Loaded into the IPC client's process: kernel sender identity must match the
socket peer, so a helper process that only claims successful import cannot pass.
"""
import ctypes as c
import hashlib
import os
import shlex
import platform
from pathlib import Path
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]

class NativeGpu:
    def __init__(self, directory):
        assert sys.platform == "darwin", "Native GPU acceptance currently requires macOS Metal"
        source = ROOT / "crates/transport/chromium-video/src/shared_gpu.m"
        output = directory / "native-gpu-probe.dylib"
        prefix=ROOT / ".cache/chromium-video" / ("aarch64-apple-darwin" if platform.machine()=="arm64" else "x86_64-apple-darwin")
        env=dict(os.environ,PKG_CONFIG_PATH=str(prefix / "lib/pkgconfig"),PKG_CONFIG_LIBDIR=str(prefix / "lib/pkgconfig"))
        flags=shlex.split(subprocess.check_output(["pkg-config","--static","--cflags","--libs","libavcodec","libavutil","libswscale"],env=env,text=True))
        with (directory / "native-gpu-build.log").open("w") as log:
            subprocess.run(["clang", "-dynamiclib", "-O2", str(source),
                str(source.with_name("codec.c")), str(source.with_name("surface.m")), *flags, "-framework", "Foundation", "-framework", "Metal", "-framework", "MetalPerformanceShaders", "-framework", "IOSurface",
                "-lbsm", "-o", str(output)], check=True, stdout=log, stderr=log)
        self.source_sha256 = hashlib.sha256(source.read_bytes()).hexdigest()
        self.lib = c.CDLL(str(output))
        signatures = {
            "gv_decoder": (c.c_void_p,[c.c_int]),
            "gv_decode": (c.c_int,[c.c_void_p,c.c_void_p,c.c_int,c.c_int,c.POINTER(c.c_void_p),c.POINTER(c.c_int),c.POINTER(c.c_int)]),
            "gv_free": (None,[c.c_void_p]),
            "gg_receiver_new": (c.c_void_p, [c.c_void_p, c.c_size_t]),
            "gg_receiver_free": (None, [c.c_void_p]),
            "gg_receive": (c.c_void_p, [c.c_void_p, c.c_int, c.POINTER(c.c_int)]),
            "gg_frame_surface": (c.c_void_p, [c.c_void_p,c.POINTER(c.c_uint32),c.POINTER(c.c_uint32),c.POINTER(c.c_uint64),c.POINTER(c.c_int)]),
            "gg_frame_free": (None, [c.c_void_p]),
            "gg_frame_prove": (c.c_int, [c.c_void_p, c.c_void_p]),
            "gg_surface_sample": (c.c_int, [c.c_void_p,c.c_void_p,c.c_uint32,c.c_uint32,c.c_uint32,c.c_void_p]),
            "gg_default_device": (c.c_void_p, []),
            "gg_object_free": (None, [c.c_void_p]),
        }
        for name, (result, args) in signatures.items():
            function = getattr(self.lib, name); function.restype=result; function.argtypes=args
        self.foundation=c.CDLL("/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
        self.foundation.CFRelease.argtypes=[c.c_void_p]
        self.device=self.lib.gg_default_device()
        assert self.device, "No real Metal device"
        self.receivers=[]

    def decode_video(self, header, payload):
        decoder=self.lib.gv_decoder({"h264":0,"hevc":1,"av1":2}[header["format"]])
        assert decoder, "No hardware video decoder for delivered fallback"
        import time
        try:
            for attempt in range(200):
                output=c.c_void_p();w=c.c_int();h=c.c_int()
                data=payload if attempt==0 else b""
                size=self.lib.gv_decode(decoder,data,len(data),0,c.byref(output),c.byref(w),c.byref(h))
                assert size>=0, "Fallback video decode failed"
                if size:
                    return w.value,h.value,c.string_at(output,size)
                time.sleep(.005)
            raise AssertionError("Fallback video did not produce actual pixels")
        finally:self.lib.gv_free(decoder)

    def receiver(self):
        receiver=Receiver(self); self.receivers.append(receiver); return receiver

    def close(self):
        for receiver in self.receivers: receiver.close()
        if self.device: self.lib.gg_object_free(self.device); self.device=None

class Receiver:
    def __init__(self, owner):
        self.owner=owner; name=c.create_string_buffer(256)
        self.handle=owner.lib.gg_receiver_new(name, len(name))
        assert self.handle, "Cannot create native Mach receiver"
        self.endpoint=name.value.decode(); self.frames=[]

    def poll(self, peer_pid):
        error=c.c_int()
        frame=self.owner.lib.gg_receive(self.handle,peer_pid,c.byref(error))
        assert not error.value, "Native frame sender differs from socket peer or invalid native resource"
        if not frame:return None
        result=Frame(self.owner,frame); self.frames.append(result); return result

    def close(self):
        for frame in self.frames: frame.close()
        self.frames.clear()
        if self.handle:self.owner.lib.gg_receiver_free(self.handle); self.handle=None

class Frame:
    def __init__(self, owner, handle):
        self.owner=owner; self.handle=handle
        w,h,seq,probe=c.c_uint32(),c.c_uint32(),c.c_uint64(),c.c_int()
        self.surface=owner.lib.gg_frame_surface(handle,c.byref(w),c.byref(h),c.byref(seq),c.byref(probe))
        self.width,self.height,self.sequence,self.probe=w.value,h.value,seq.value,bool(probe.value)
    def prove(self, fail_import=False):
        result=self.owner.lib.gg_frame_prove(self.handle,None if fail_import else self.owner.device)
        if fail_import: assert result != 0, "Invalid GPU device unexpectedly imported a probe"
        else: assert result == 0, "Real Metal texture import/probe failed"
    def sample(self,x=0,y=0,count=1):
        out=(c.c_ubyte*(count*4))()
        assert self.owner.lib.gg_surface_sample(self.surface,self.owner.device,x,y,count,out)==0, "Metal GPU sample failed"
        return bytes(out)
    def close(self):
        if self.surface:self.owner.foundation.CFRelease(self.surface); self.surface=None
        if self.handle:self.owner.lib.gg_frame_free(self.handle); self.handle=None
