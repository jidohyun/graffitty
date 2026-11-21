#pragma once
#include <atomic>
#include <cstdint>
#include <memory>
#include <mutex>
#include <d3d11_1.h>
#include <wrl/client.h>

namespace graffitty {
struct WindowsDevice {
    Microsoft::WRL::ComPtr<ID3D11Device1> device;
    Microsoft::WRL::ComPtr<ID3D11DeviceContext> context;
    // FFmpeg's D3D11 callbacks require a recursive lock. Capture, preview
    // readback, GPU scaling, and encoder frame-pool operations share it.
    std::recursive_mutex mutex;
    std::atomic<uint64_t> readbacks{0};
    // Queried once per codec on this adapter, under mutex. -1 means unavailable.
    int minimum_dimensions[3][2]{};
};
struct WindowsSurface {
    std::shared_ptr<WindowsDevice> owner;
    Microsoft::WRL::ComPtr<ID3D11Texture2D> texture;
};
}
