#pragma once
#include <d3d11_1.h>
#include <dxgi1_2.h>
#include <wrl/client.h>
#include <string>
#include "../../../crates/transport/chromium-video/include/frame_protocol_windows.h"
using Microsoft::WRL::ComPtr;
class GpuSender {
    HANDLE mapping_ = nullptr, pending_ = nullptr, queued_ = nullptr, owner_ = nullptr;
    ChromiumFrameSlot *slot_ = nullptr;
    UINT width_ = 0, height_ = 0;
    bool bgra_ = false;
    uint64_t sequence_ = 0;
    std::wstring name_;
    ComPtr<ID3D11Device1> device_;
    ComPtr<ID3D11DeviceContext> context_;
    ComPtr<ID3D11Query> fence_;
    std::wstring prefix_;
    bool open(HANDLE handle, ComPtr<ID3D11Texture2D> &source) {
        if (device_)
            return SUCCEEDED(device_->OpenSharedResource1(handle, IID_PPV_ARGS(&source)));
        ComPtr<IDXGIFactory1> factory;
        if (FAILED(CreateDXGIFactory1(IID_PPV_ARGS(&factory))))
            return false;
        for (UINT index = 0;; ++index) {
            ComPtr<IDXGIAdapter1> adapter;
            if (factory->EnumAdapters1(index, &adapter) == DXGI_ERROR_NOT_FOUND)
                break;
            ComPtr<ID3D11Device> candidate;
            ComPtr<ID3D11DeviceContext> context;
            if (FAILED(D3D11CreateDevice(adapter.Get(), D3D_DRIVER_TYPE_UNKNOWN, nullptr,
                                         D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0,
                                         D3D11_SDK_VERSION, &candidate, nullptr, &context)))
                continue;
            ComPtr<ID3D11Device1> next;
            if (FAILED(candidate.As(&next)) ||
                FAILED(next->OpenSharedResource1(handle, IID_PPV_ARGS(&source))))
                continue;
            D3D11_QUERY_DESC query = {D3D11_QUERY_EVENT, 0};
            if (FAILED(next->CreateQuery(&query, &fence_)))
                return false;
            device_ = next;
            context_ = context;
            return true;
        }
        return false;
    }

  public:
    uint64_t frames = 0, sent = 0, dropped = 0, errors = 0;
    ~GpuSender() {
        discard();
        if (pending_)
            CloseHandle(pending_);
        if (slot_)
            UnmapViewOfFile(slot_);
        if (mapping_)
            CloseHandle(mapping_);
        if (owner_)
            CloseHandle(owner_);
    }
    bool start(const std::string &endpoint) {
        prefix_ = L"Local\\" + std::wstring(endpoint.begin(), endpoint.end());
        mapping_ = OpenFileMappingW(FILE_MAP_ALL_ACCESS, FALSE, prefix_.c_str());
        if (!mapping_)
            return false;
        slot_ = static_cast<ChromiumFrameSlot *>(
            MapViewOfFile(mapping_, FILE_MAP_ALL_ACCESS, 0, 0, sizeof(ChromiumFrameSlot)));
        if (!slot_ || slot_->magic != ChromiumFrameMagic)
            return false;
        owner_ = OpenProcess(SYNCHRONIZE, FALSE, slot_->owner_pid);
        return owner_ != nullptr;
    }
    bool owner_alive() const { return owner_ && WaitForSingleObject(owner_, 0) == WAIT_TIMEOUT; }
    void discard() {
        if (queued_) { CloseHandle(queued_); queued_ = nullptr; ++dropped; }
    }
    bool publish() {
        if (!queued_) return false;
        if (InterlockedCompareExchange(&slot_->state, 2, 0) != 0) {
            return false;
        }
        if (pending_) CloseHandle(pending_);
        pending_ = queued_;
        queued_ = nullptr;
        slot_->width = width_;
        slot_->height = height_;
        slot_->bgra = bgra_;
        slot_->sequence = sequence_;
        wcsncpy_s(slot_->texture_name, name_.c_str(), _TRUNCATE);
        InterlockedExchange(&slot_->state, 1);
        ++sent;
        return true;
    }
    bool transfer(HANDLE borrowed) {
        ++frames;
        ComPtr<ID3D11Texture2D> source;
        if (!open(borrowed, source)) {
            ++errors;
            return false;
        }
        D3D11_TEXTURE2D_DESC desc;
        source->GetDesc(&desc);
        if (!desc.Width || !desc.Height || desc.Width > 8192 || desc.Height > 8192 ||
            desc.ArraySize != 1 || desc.MipLevels != 1) {
            ++errors;
            return false;
        }
        const bool bgra = desc.Format == DXGI_FORMAT_B8G8R8A8_UNORM;
        if (!bgra && desc.Format != DXGI_FORMAT_R8G8B8A8_UNORM) {
            ++errors;
            return false;
        }
        desc.Usage = D3D11_USAGE_DEFAULT;
        desc.CPUAccessFlags = 0;
        desc.BindFlags = D3D11_BIND_SHADER_RESOURCE | D3D11_BIND_RENDER_TARGET;
        desc.MiscFlags = D3D11_RESOURCE_MISC_SHARED_NTHANDLE | D3D11_RESOURCE_MISC_SHARED;
        ComPtr<ID3D11Texture2D> owned;
        if (FAILED(device_->CreateTexture2D(&desc, nullptr, &owned))) {
            ++errors;
            return false;
        }
        context_->CopyResource(owned.Get(), source.Get());
        context_->End(fence_.Get());
        context_->Flush();
        const auto deadline = GetTickCount64() + 3000;
        HRESULT hr;
        while ((hr = context_->GetData(fence_.Get(), nullptr, 0, 0)) == S_FALSE) {
            if (GetTickCount64() > deadline) {
                ++errors;
                return false;
            }
            Sleep(1);
        }
        if (FAILED(hr)) {
            ++errors;
            return false;
        }
        ComPtr<IDXGIResource1> resource;
        auto name = prefix_ + L".texture." + std::to_wstring(frames);
        HANDLE next = nullptr;
        if (FAILED(owned.As(&resource)) ||
            FAILED(resource->CreateSharedHandle(
                nullptr, DXGI_SHARED_RESOURCE_READ | DXGI_SHARED_RESOURCE_WRITE, name.c_str(),
                &next))) {
            ++errors;
            return false;
        }
        // CEF owns the borrowed texture only during this callback. Keep one
        // owned latest frame until the receiver releases its previous frame.
        // A static page may never produce another paint after a resize.
        discard();
        queued_ = next;
        width_ = desc.Width;
        height_ = desc.Height;
        bgra_ = bgra;
        sequence_ = frames;
        name_ = std::move(name);
        return true;
    }
};
