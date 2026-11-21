#pragma once
#include <mach/mach.h>
#include <stdint.h>
// One immutable, GPU-copied IOSurface per message. MOVE_SEND transfers its
// lifetime to the receiver; no shared buffer may be rewritten after delivery.
struct ChromiumFrameMessage {
    mach_msg_header_t header;
    mach_msg_body_t body;
    mach_msg_port_descriptor_t surface;
    uint32_t width, height, bgra;
    uint64_t sequence;
};
