#pragma once
#include "../include/frame_protocol_linux.h"
#include <memory>
#include <vector>

class VulkanReadback {
  public:
    static std::unique_ptr<VulkanReadback> create();
    virtual ~VulkanReadback() = default;
    chromium_linux::Hello hello;
    // Consumes fd on every path. Pixels retain the producer's channel order.
    virtual bool read(const chromium_linux::Frame &frame, int fd, std::vector<uint8_t> &pixels) = 0;
};
