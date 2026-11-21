#pragma once
#include <windows.h>
#include <cstdint>
// One immutable texture in flight. Interlocked operations publish/consume the
// slot; the producer retains its NT handle until the receiver opens the
// texture. No pixels cross this mapping.
//
// Names are unguessable and local to this session.
struct ChromiumFrameSlot {
    uint32_t magic;
    uint32_t owner_pid;
    volatile LONG state; // 0 empty, 1 published, 2 owned by producer/consumer
    uint32_t width, height, bgra;
    uint64_t sequence;
    wchar_t texture_name[192];
};
constexpr uint32_t ChromiumFrameMagic = 0x414C4D31;
