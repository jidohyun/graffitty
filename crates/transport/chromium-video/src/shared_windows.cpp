#define NOMINMAX
#include <windows.h>
#include "../include/windows_adapter.h"
#include <sddl.h>
#include <bcrypt.h>
#include <d3d11_1.h>
#include <d3d12.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <array>
#include <string>
#include <memory>
#include <mutex>
#include <cstring>
#include "../include/frame_protocol_windows.h"
#include "windows_surface.h"
using Microsoft::WRL::ComPtr;
namespace {
using Device = graffitty::WindowsDevice;
using Surface = graffitty::WindowsSurface;
struct Handle {
    HANDLE value = nullptr;
    ~Handle() { if (value && value != INVALID_HANDLE_VALUE) CloseHandle(value); }
};
std::wstring nonce_name() {
    unsigned char bytes[16];
    if (BCryptGenRandom(nullptr, bytes, sizeof(bytes), BCRYPT_USE_SYSTEM_PREFERRED_RNG)) return {};
    const wchar_t *hex = L"0123456789abcdef";
    std::wstring name = L"Local\\graffitty-gpu-";
    for (auto b : bytes) { name += hex[b >> 4]; name += hex[b & 15]; }
    return name;
}
std::shared_ptr<Device> make_device(HANDLE shared = nullptr, ID3D11Texture2D **texture = nullptr) {
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return {};
    for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        if (FAILED(factory->EnumAdapters1(index, &adapter))) return {};
        // A software compositor sends PNGs. A successful WARP texture challenge
        // would otherwise reserve a local GPU channel that never receives a surface.
        if (!graffitty::is_hardware_adapter(adapter.Get())) continue;
        auto result = std::make_shared<Device>();
        ComPtr<ID3D11Device> device;
        if (FAILED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
            &device, nullptr, &result->context)) || FAILED(device.As(&result->device))) continue;
        if (shared && FAILED(result->device->OpenSharedResource1(shared, IID_PPV_ARGS(texture)))) continue;
        return result;
    }
}
struct Capture {
    Handle mapping;
    ChromiumFrameSlot *slot = nullptr;
    std::shared_ptr<Device> owner;
    ~Capture() { if (slot) UnmapViewOfFile(slot); }
};
// Native packets contain names/metadata only. The pipe peer PID is checked in
// both directions, and a nonce must be read through the actual D3D12 device.
constexpr uint32_t magic = 0x47575031;
struct Packet {
    uint32_t magic_value = magic, probe = 0, width = 0, height = 0;
    uint64_t sequence = 0;
    wchar_t name[96]{};
};
struct Ack { uint32_t magic_value = magic, probe = 0; uint64_t sequence = 0; unsigned char proof[16]{}; };
bool write_packet(HANDLE pipe, const void *data, DWORD size) {
    DWORD count = 0;
    return WriteFile(pipe, data, size, &count, nullptr) && count == size;
}
int read_packet(HANDLE pipe, void *data, DWORD size) {
    DWORD available = 0, count = 0;
    if (!PeekNamedPipe(pipe, nullptr, 0, nullptr, &available, nullptr)) return -1;
    if (!available) return 0;
    if (!ReadFile(pipe, data, size, &count, nullptr) || count != size) return -1;
    return 1;
}
struct Channel {
    Handle pipe, shared;
    ComPtr<ID3D11Texture2D> pending;
    unsigned char proof[16]{};
    bool active = false, waiting = false;
    uint64_t sequence = 0;
    bool publish(Surface &surface, uint64_t seq, bool probe) {
        ComPtr<IDXGIResource1> resource;
        if (FAILED(surface.texture.As(&resource))) return false;
        auto name = nonce_name();
        if (name.empty()) return false;
        if (shared.value) { CloseHandle(shared.value); shared.value = nullptr; }
        if (FAILED(resource->CreateSharedHandle(nullptr,
            DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, name.c_str(), &shared.value))) return false;
        D3D11_TEXTURE2D_DESC desc; surface.texture->GetDesc(&desc);
        Packet packet; packet.probe = probe; packet.width = desc.Width; packet.height = desc.Height; packet.sequence = seq;
        wcscpy_s(packet.name, name.c_str());
        if (!write_packet(pipe.value, &packet, sizeof(packet))) return false;
        pending = surface.texture; sequence = seq; waiting = true;
        return true;
    }
    int acknowledge() {
        if (!waiting) return 1;
        Ack ack; int result = read_packet(pipe.value, &ack, sizeof(ack));
        if (result <= 0) return result;
        if (ack.magic_value != magic || ack.sequence != sequence || ack.probe != uint32_t(!active)) return -1;
        if (!active && memcmp(proof, ack.proof, sizeof(proof))) return -1;
        waiting = false; active = true; pending.Reset();
        if (shared.value) { CloseHandle(shared.value); shared.value = nullptr; }
        return 1;
    }
};
// Imports transition on a dedicated queue, created once per Godot device:
// creating a queue, allocator, list and fence for every frame cost about
// 29 ms and held local chromium panes near 21 fps.
struct Transitions {
    ID3D12Device *device = nullptr;
    ComPtr<ID3D12CommandQueue> queue;
    ComPtr<ID3D12CommandAllocator> allocator;
    ComPtr<ID3D12GraphicsCommandList> commands;
    ComPtr<ID3D12Fence> fence;
    Handle done;
    UINT64 value = 0;
    bool prepare(ID3D12Device *next) {
        if (device == next && queue) return true;
        device = nullptr; queue.Reset(); allocator.Reset(); commands.Reset(); fence.Reset(); value = 0;
        D3D12_COMMAND_QUEUE_DESC q{};
        if (FAILED(next->CreateCommandQueue(&q, IID_PPV_ARGS(&queue))) ||
            FAILED(next->CreateCommandAllocator(D3D12_COMMAND_LIST_TYPE_DIRECT, IID_PPV_ARGS(&allocator))) ||
            FAILED(next->CreateCommandList(0, D3D12_COMMAND_LIST_TYPE_DIRECT, allocator.Get(), nullptr, IID_PPV_ARGS(&commands))) ||
            FAILED(commands->Close()) ||
            FAILED(next->CreateFence(0, D3D12_FENCE_FLAG_NONE, IID_PPV_ARGS(&fence)))) { queue.Reset(); return false; }
        if (!done.value) done.value = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!done.value) { queue.Reset(); return false; }
        device = next;
        return true;
    }
};
struct Receiver {
    Handle pipe;
    bool connected = false;
    ComPtr<ID3D12Resource> imported;
    Transitions transitions;
};
// Each copy completes on the dedicated queue before exposing the resource.
// Godot's deferred destruction keeps imported source storage alive afterwards.
bool execute(Transitions &transitions, ID3D12Device *device, ID3D12Resource *source, unsigned char *proof) {
    if (!transitions.prepare(device) || FAILED(transitions.allocator->Reset()) ||
        FAILED(transitions.commands->Reset(transitions.allocator.Get(), nullptr))) return false;
    auto commands = transitions.commands.Get();
    ComPtr<ID3D12Resource> readback;
    D3D12_RESOURCE_BARRIER barrier{};
    barrier.Type = D3D12_RESOURCE_BARRIER_TYPE_TRANSITION;
    barrier.Transition.pResource = source;
    barrier.Transition.Subresource = D3D12_RESOURCE_BARRIER_ALL_SUBRESOURCES;
    barrier.Transition.StateBefore = D3D12_RESOURCE_STATE_COMMON;
    barrier.Transition.StateAfter = proof ? D3D12_RESOURCE_STATE_COPY_SOURCE : D3D12_RESOURCE_STATE_RENDER_TARGET;
    commands->ResourceBarrier(1, &barrier);
    if (proof) {
        D3D12_HEAP_PROPERTIES heap{}; heap.Type = D3D12_HEAP_TYPE_READBACK;
        D3D12_RESOURCE_DESC buffer{}; buffer.Dimension = D3D12_RESOURCE_DIMENSION_BUFFER;
        buffer.Width = 256; buffer.Height = buffer.DepthOrArraySize = buffer.MipLevels = 1;
        buffer.SampleDesc.Count = 1; buffer.Layout = D3D12_TEXTURE_LAYOUT_ROW_MAJOR;
        if (FAILED(device->CreateCommittedResource(&heap, D3D12_HEAP_FLAG_NONE, &buffer,
            D3D12_RESOURCE_STATE_COPY_DEST, nullptr, IID_PPV_ARGS(&readback)))) return false;
        D3D12_TEXTURE_COPY_LOCATION from{}, to{};
        from.pResource = source; from.Type = D3D12_TEXTURE_COPY_TYPE_SUBRESOURCE_INDEX;
        to.pResource = readback.Get(); to.Type = D3D12_TEXTURE_COPY_TYPE_PLACED_FOOTPRINT;
        to.PlacedFootprint.Footprint = {source->GetDesc().Format, 1, 1, 1, 256};
        D3D12_BOX pixel{0, 0, 0, 1, 1, 1};
        commands->CopyTextureRegion(&to, 0, 0, 0, &from, &pixel);
    }
    if (FAILED(commands->Close())) return false;
    ID3D12CommandList *list[] = {commands}; transitions.queue->ExecuteCommandLists(1, list);
    const UINT64 value = ++transitions.value;
    if (FAILED(transitions.queue->Signal(transitions.fence.Get(), value)) ||
        FAILED(transitions.fence->SetEventOnCompletion(value, transitions.done.value)) ||
        WaitForSingleObject(transitions.done.value, 3000) != WAIT_OBJECT_0) return false;
    if (proof) {
        void *bytes = nullptr; D3D12_RANGE range{0, 16};
        if (FAILED(readback->Map(0, &range, &bytes))) return false;
        memcpy(proof, bytes, 16); D3D12_RANGE empty{}; readback->Unmap(0, &empty);
    }
    return true;
}
}
extern "C" void *gw_capture_new(const char *name) {
    auto capture = std::make_unique<Capture>();
    std::wstring path = L"Local\\"; while (*name) path += wchar_t(*name++);
    capture->mapping.value = CreateFileMappingW(INVALID_HANDLE_VALUE, nullptr, PAGE_READWRITE, 0, sizeof(ChromiumFrameSlot), path.c_str());
    if (!capture->mapping.value || GetLastError() == ERROR_ALREADY_EXISTS) return nullptr;
    capture->slot = static_cast<ChromiumFrameSlot *>(MapViewOfFile(capture->mapping.value, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(ChromiumFrameSlot)));
    if (!capture->slot) return nullptr;
    capture->slot->owner_pid = GetCurrentProcessId(); capture->slot->magic = ChromiumFrameMagic;
    return capture.release();
}
extern "C" void gw_capture_free(void *p) { delete static_cast<Capture *>(p); }
extern "C" void *gw_capture_receive(void *p, uint32_t *width, uint32_t *height) {
    auto capture = static_cast<Capture *>(p);
    auto &slot = *capture->slot;
    if (InterlockedCompareExchange(&slot.state, 2, 1) != 1) return nullptr;
    struct Unlock { ChromiumFrameSlot &slot; ~Unlock() { InterlockedExchange(&slot.state, 0); } } unlock{slot};
    if (!slot.width || !slot.height || slot.width > 8192 || slot.height > 8192 || slot.texture_name[191]) return nullptr;
    auto surface = std::make_unique<Surface>();
    if (capture->owner) {
        surface->owner = capture->owner;
        if (FAILED(surface->owner->device->OpenSharedResourceByName(slot.texture_name,
            DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, IID_PPV_ARGS(&surface->texture)))) return nullptr;
    } else {
    // Open the immutable shared texture on its actual adapter, once.
    ComPtr<IDXGIFactory1> factory;
    if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory)))) return nullptr;
    for (UINT index = 0;; ++index) {
        ComPtr<IDXGIAdapter1> adapter;
        if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND) return nullptr;
        auto owner = std::make_shared<Device>(); ComPtr<ID3D11Device> device;
        if (FAILED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr, D3D11_CREATE_DEVICE_BGRA_SUPPORT | D3D11_CREATE_DEVICE_VIDEO_SUPPORT,
            nullptr, 0, D3D11_SDK_VERSION, &device, nullptr, &owner->context)) || FAILED(device.As(&owner->device))) continue;
        if (FAILED(owner->device->OpenSharedResourceByName(slot.texture_name, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE,
            IID_PPV_ARGS(&surface->texture)))) continue;
        surface->owner = owner; capture->owner = owner; break;
    }
    }
    D3D11_TEXTURE2D_DESC desc; surface->texture->GetDesc(&desc);
    if (desc.Width != slot.width || desc.Height != slot.height || desc.MipLevels != 1 || desc.ArraySize != 1 ||
        (desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM && desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM)) return nullptr;
    *width = desc.Width; *height = desc.Height; return surface.release();
}
extern "C" void *gw_surface_clone(void *p) { return new Surface(*static_cast<Surface *>(p)); }
extern "C" void gw_surface_free(void *p) { delete static_cast<Surface *>(p); }
// Diagnostic fixture upload. Live browser encoding only consumes captured GPU
// textures; this entry point lets tests check both texture layouts and resizing.
extern "C" void *gw_surface_from_rgba(void *reference, uint32_t width, uint32_t height, const uint8_t *rgba, int bgra) {
    if (!rgba || !width || !height || width > 8192 || height > 8192) return nullptr;
    auto surface = std::make_unique<Surface>();
    surface->owner = reference ? static_cast<Surface *>(reference)->owner : make_device();
    if (!surface->owner) return nullptr;
    std::lock_guard lock(surface->owner->mutex);
    D3D11_TEXTURE2D_DESC desc{};
    desc.Width = width; desc.Height = height; desc.MipLevels = desc.ArraySize = 1;
    desc.Format = bgra ? DXGI_FORMAT_B8G8R8A8_UNORM : DXGI_FORMAT_R8G8B8A8_UNORM;
    desc.SampleDesc.Count = 1; desc.Usage = D3D11_USAGE_DEFAULT;
    desc.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
    auto pixels = std::make_unique<uint8_t[]>(size_t(width) * height * 4);
    std::memcpy(pixels.get(), rgba, size_t(width) * height * 4);
    if (bgra) for (size_t i = 0; i < size_t(width) * height * 4; i += 4) std::swap(pixels[i], pixels[i + 2]);
    D3D11_SUBRESOURCE_DATA data{pixels.get(), width * 4, 0};
    if (FAILED(surface->owner->device->CreateTexture2D(&desc, &data, &surface->texture))) return nullptr;
    return surface.release();
}
extern "C" int gw_surface_rgba(void *p, unsigned char *out) {
    auto &surface = *static_cast<Surface *>(p); std::lock_guard lock(surface.owner->mutex);
    ++surface.owner->readbacks;
    D3D11_TEXTURE2D_DESC desc; surface.texture->GetDesc(&desc);
    bool bgra = desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM;
    desc.Usage = D3D11_USAGE_STAGING; desc.BindFlags = desc.MiscFlags = 0; desc.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    ComPtr<ID3D11Texture2D> staging;
    if (FAILED(surface.owner->device->CreateTexture2D(&desc, nullptr, &staging))) return -1;
    surface.owner->context->CopyResource(staging.Get(), surface.texture.Get());
    D3D11_MAPPED_SUBRESOURCE mapped{};
    if (FAILED(surface.owner->context->Map(staging.Get(), 0, D3D11_MAP_READ, 0, &mapped))) return -1;
    for (UINT y = 0; y < desc.Height; ++y) {
        auto row = static_cast<unsigned char *>(mapped.pData) + y * mapped.RowPitch;
        for (UINT x = 0; x < desc.Width; ++x) {
            auto pixel = out + (size_t(y) * desc.Width + x) * 4;
            memcpy(pixel, row + x * 4, 4); if (bgra) std::swap(pixel[0], pixel[2]);
        }
    }
    surface.owner->context->Unmap(staging.Get(), 0); return 0;
}
extern "C" void *gw_channel_new(const char *endpoint, uint32_t expected_peer) {
    std::wstring name; while (*endpoint) name += wchar_t(*endpoint++);
    if (!name.starts_with(L"\\\\.\\pipe\\graffitty-gpu-")) return nullptr;
    auto channel = std::make_unique<Channel>();
    channel->pipe.value = CreateFileW(name.c_str(), GENERIC_READ | GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
        SECURITY_SQOS_PRESENT | SECURITY_IDENTIFICATION, nullptr);
    if (channel->pipe.value == INVALID_HANDLE_VALUE) return nullptr;
    ULONG pid = 0; DWORD mode = PIPE_READMODE_MESSAGE | PIPE_NOWAIT;
    if (!GetNamedPipeServerProcessId(channel->pipe.value, &pid) || pid != expected_peer ||
        !SetNamedPipeHandleState(channel->pipe.value, &mode, nullptr, nullptr)) return nullptr;
    Surface probe; probe.owner = make_device(); if (!probe.owner) return nullptr;
    if (BCryptGenRandom(nullptr, channel->proof, 16, BCRYPT_USE_SYSTEM_PREFERRED_RNG)) return nullptr;
    D3D11_TEXTURE2D_DESC desc{}; desc.Width = desc.Height = desc.MipLevels = desc.ArraySize = desc.SampleDesc.Count = 1;
    desc.Format = DXGI_FORMAT_R32G32B32A32_UINT; desc.BindFlags = D3D11_BIND_SHADER_RESOURCE;
    desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
    D3D11_SUBRESOURCE_DATA data{channel->proof, 16, 16};
    if (FAILED(probe.owner->device->CreateTexture2D(&desc, &data, &probe.texture))) return nullptr;
    ComPtr<ID3D11Query> fence; D3D11_QUERY_DESC query{D3D11_QUERY_EVENT, 0};
    if (FAILED(probe.owner->device->CreateQuery(&query, &fence))) return nullptr;
    probe.owner->context->End(fence.Get()); probe.owner->context->Flush();
    auto deadline = GetTickCount64() + 3000;
    HRESULT completed;
    while ((completed = probe.owner->context->GetData(fence.Get(), nullptr, 0, 0)) == S_FALSE) {
        if (GetTickCount64() >= deadline) return nullptr;
        Sleep(1);
    }
    if (FAILED(completed) || !channel->publish(probe, 0, true)) return nullptr;
    return channel.release();
}
extern "C" void gw_channel_free(void *p) { delete static_cast<Channel *>(p); }
extern "C" int gw_channel_confirm(void *p) { return static_cast<Channel *>(p)->acknowledge(); }
extern "C" int gw_channel_send(void *p, void *surface, uint64_t sequence) {
    auto channel = static_cast<Channel *>(p);
    if (!channel->active) return -1;
    int ready = channel->acknowledge(); if (ready <= 0) return ready;
    return channel->publish(*static_cast<Surface *>(surface), sequence, false) ? 1 : -1;
}
extern "C" void *gw_receiver_new(const char *endpoint) {
    std::wstring name; while (*endpoint) name += wchar_t(*endpoint++);
    auto receiver = std::make_unique<Receiver>();
    // Owner Rights resolves to the creating token's user, not a PID claim.
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;;GA;;;OW)", SDDL_REVISION_1, &descriptor, nullptr)) return nullptr;
    SECURITY_ATTRIBUTES security{sizeof(SECURITY_ATTRIBUTES), descriptor, FALSE};
    receiver->pipe.value = CreateNamedPipeW(name.c_str(), PIPE_ACCESS_DUPLEX | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_NOWAIT | PIPE_REJECT_REMOTE_CLIENTS, 1, 65536, 65536, 0, &security);
    LocalFree(descriptor);
    if (receiver->pipe.value == INVALID_HANDLE_VALUE) return nullptr;
    return receiver.release();
}
extern "C" void gw_receiver_free(void *p) { delete static_cast<Receiver *>(p); }
extern "C" int gw_receive(void *p, uint32_t expected_server, void *device_pointer,
    uint64_t *texture, uint32_t *width, uint32_t *height, uint32_t *bgra, uint64_t *sequence) {
    auto receiver = static_cast<Receiver *>(p); auto device = static_cast<ID3D12Device *>(device_pointer);
    if (!device) return -1;
    if (!receiver->connected) {
        if (!ConnectNamedPipe(receiver->pipe.value, nullptr) && GetLastError() != ERROR_PIPE_CONNECTED) {
            return GetLastError() == ERROR_PIPE_LISTENING ? 0 : -1;
        }
        ULONG pid = 0;
        if (!GetNamedPipeClientProcessId(receiver->pipe.value, &pid) || pid != expected_server) return -1;
        receiver->connected = true;
    }
    Packet packet; int ready = read_packet(receiver->pipe.value, &packet, sizeof(packet)); if (ready <= 0) return ready;
    if (packet.magic_value != magic || packet.probe > 1 || !packet.width || !packet.height ||
        packet.width > 8192 || packet.height > 8192 || packet.name[95]) return -1;
    Handle handle;
    if (FAILED(device->OpenSharedHandleByName(packet.name, GENERIC_ALL, &handle.value))) return -1;
    ComPtr<ID3D12Resource> resource;
    if (FAILED(device->OpenSharedHandle(handle.value, IID_PPV_ARGS(&resource)))) return -1;
    auto desc = resource->GetDesc();
    if (desc.Width != packet.width || desc.Height != packet.height || desc.Dimension != D3D12_RESOURCE_DIMENSION_TEXTURE2D ||
        desc.MipLevels != 1 || desc.DepthOrArraySize != 1) return -1;
    Ack ack; ack.probe = packet.probe; ack.sequence = packet.sequence;
    if (packet.probe) {
        if (desc.Width != 1 || desc.Height != 1 || desc.Format != DXGI_FORMAT_R32G32B32A32_UINT || !execute(receiver->transitions, device, resource.Get(), ack.proof)) return -1;
    } else {
        if ((desc.Format != DXGI_FORMAT_B8G8R8A8_UNORM && desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM) || !execute(receiver->transitions, device, resource.Get(), nullptr)) return -1;
        receiver->imported = resource;
        *texture = reinterpret_cast<uint64_t>(resource.Get()); *width = packet.width; *height = packet.height;
        *bgra = desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM; *sequence = packet.sequence;
    }
    if (!write_packet(receiver->pipe.value, &ack, sizeof(ack))) return -1;
    return packet.probe ? 2 : 1;
}
extern "C" bool gw_bind_lifetime(void *p, uint64_t destination) {
    auto receiver = static_cast<Receiver *>(p);
    if (!receiver->imported || !destination) return false;
    const GUID lifetime = {0x537c09a5, 0x69df, 0x4c19, {0xae, 0xb3, 0x42, 0x1a, 0xee, 0xc6, 0xd3, 0x7f}};
    auto resource = reinterpret_cast<ID3D12Resource *>(destination);
    if (FAILED(resource->SetPrivateDataInterface(lifetime, receiver->imported.Get()))) return false;
    receiver->imported.Reset(); return true;
}
extern "C" void *gw_probe_device_new() {
    ID3D12Device *device = nullptr;
    return SUCCEEDED(D3D12CreateDevice(nullptr, D3D_FEATURE_LEVEL_11_0, IID_PPV_ARGS(&device))) ? device : nullptr;
}
extern "C" void gw_probe_device_free(void *p) { if (p) static_cast<ID3D12Device *>(p)->Release(); }
