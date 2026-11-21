#pragma once
#include <dxgi1_2.h>

namespace graffitty {
inline bool is_hardware_adapter(IDXGIAdapter1 *adapter) {
    DXGI_ADAPTER_DESC1 desc{};
    // Hyper-V can expose the Basic Render Driver twice, once without SOFTWARE.
    return SUCCEEDED(adapter->GetDesc1(&desc)) && !(desc.Flags & DXGI_ADAPTER_FLAG_SOFTWARE) &&
           !(desc.VendorId == 0x1414 && desc.DeviceId == 0x008c);
}
}
