#include <algorithm>
#include <atomic>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <string>
#include <thread>
#include <vector>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <avrt.h>
#include <ksmedia.h>

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "avrt.lib")

namespace {

constexpr int kPort = 50005;
constexpr int kSampleRate = 48000;
constexpr int kChannels = 2;
constexpr int kFrameSamples = 960;
constexpr int kFrameBytes = kFrameSamples * kChannels * sizeof(int16_t);

std::atomic<bool> g_running{true};

int16_t ClampToInt16(float value) {
  value = std::max(-1.0f, std::min(1.0f, value));
  return static_cast<int16_t>(std::lrintf(value * 32767.0f));
}

uint64_t NowNs() {
  static LARGE_INTEGER freq = [] {
    LARGE_INTEGER value;
    QueryPerformanceFrequency(&value);
    return value;
  }();
  LARGE_INTEGER counter;
  QueryPerformanceCounter(&counter);
  return static_cast<uint64_t>((counter.QuadPart * 1000000000ull) / freq.QuadPart);
}

bool IsFloatFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_IEEE_FLOAT) return true;
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_IEEE_FLOAT);
  }
  return false;
}

bool IsPcmFormat(const WAVEFORMATEX* format) {
  if (format->wFormatTag == WAVE_FORMAT_PCM) return true;
  if (format->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
    const auto* ext = reinterpret_cast<const WAVEFORMATEXTENSIBLE*>(format);
    return IsEqualGUID(ext->SubFormat, KSDATAFORMAT_SUBTYPE_PCM);
  }
  return false;
}

void AppendConvertedFrames(
    const BYTE* data,
    UINT32 frames,
    const WAVEFORMATEX* format,
    std::vector<int16_t>& pcm) {
  const int sourceRate = static_cast<int>(format->nSamplesPerSec);
  const int sourceChannels = std::max<int>(1, format->nChannels);
  const int bits = format->wBitsPerSample;
  const int blockAlign = format->nBlockAlign;
  const bool isFloat = IsFloatFormat(format);
  const bool isPcm = IsPcmFormat(format);

  if (sourceRate <= 0 || blockAlign <= 0 || (!isFloat && !isPcm)) return;

  const int outFrames = static_cast<int>(
      (static_cast<int64_t>(frames) * kSampleRate + sourceRate - 1) / sourceRate);
  pcm.reserve(pcm.size() + outFrames * kChannels);

  for (int out = 0; out < outFrames; ++out) {
    const int inFrame = std::min<int>(
        frames - 1,
        static_cast<int>((static_cast<int64_t>(out) * sourceRate) / kSampleRate));
    const BYTE* frame = data + inFrame * blockAlign;

    int16_t left = 0;
    int16_t right = 0;
    if (isFloat && bits == 32) {
      const float* samples = reinterpret_cast<const float*>(frame);
      left = ClampToInt16(samples[0]);
      right = ClampToInt16(samples[sourceChannels > 1 ? 1 : 0]);
    } else if (isPcm && bits == 16) {
      const int16_t* samples = reinterpret_cast<const int16_t*>(frame);
      left = samples[0];
      right = samples[sourceChannels > 1 ? 1 : 0];
    } else if (isPcm && bits == 32) {
      const int32_t* samples = reinterpret_cast<const int32_t*>(frame);
      left = static_cast<int16_t>(samples[0] >> 16);
      right = static_cast<int16_t>(samples[sourceChannels > 1 ? 1 : 0] >> 16);
    } else {
      continue;
    }

    pcm.push_back(left);
    pcm.push_back(right);
  }
}

void SendFrame(
    SOCKET socket,
    const std::vector<sockaddr_in>& targets,
    const int16_t* pcm,
    int sequence) {
  std::vector<uint8_t> packet(11 + kFrameBytes);
  const uint64_t timestamp = NowNs();
  packet[0] = 0x01;
  packet[1] = static_cast<uint8_t>((sequence >> 8) & 0xFF);
  packet[2] = static_cast<uint8_t>(sequence & 0xFF);
  for (int i = 0; i < 8; ++i) {
    packet[3 + i] = static_cast<uint8_t>((timestamp >> ((7 - i) * 8)) & 0xFF);
  }
  std::memcpy(packet.data() + 11, pcm, kFrameBytes);

  for (const auto& target : targets) {
    sendto(socket, reinterpret_cast<const char*>(packet.data()),
           static_cast<int>(packet.size()), 0,
           reinterpret_cast<const sockaddr*>(&target), sizeof(target));
  }
}

}  // namespace

int main(int argc, char* argv[]) {
  std::vector<std::string> targetIps;
  int port = kPort;

  for (int i = 1; i < argc; ++i) {
    std::string arg = argv[i];
    if ((arg == "--target" || arg == "-t") && i + 1 < argc) {
      targetIps.emplace_back(argv[++i]);
    } else if ((arg == "--port" || arg == "-p") && i + 1 < argc) {
      port = std::stoi(argv[++i]);
    }
  }

  if (targetIps.empty()) {
    std::cerr << "Usage: ZapShareAudioSender.exe --target <ip> [--target <ip>] [--port 50005]\n";
    return 2;
  }

  WSADATA wsaData;
  if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) return 1;
  SOCKET udpSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
  if (udpSocket == INVALID_SOCKET) {
    WSACleanup();
    return 1;
  }

  int sendBuffer = 512 * 1024;
  setsockopt(udpSocket, SOL_SOCKET, SO_SNDBUF,
             reinterpret_cast<const char*>(&sendBuffer), sizeof(sendBuffer));
  int tos = 0xB8;
  setsockopt(udpSocket, IPPROTO_IP, IP_TOS,
             reinterpret_cast<const char*>(&tos), sizeof(tos));

  std::vector<sockaddr_in> targets;
  for (const auto& ip : targetIps) {
    sockaddr_in addr{};
    addr.sin_family = AF_INET;
    addr.sin_port = htons(static_cast<u_short>(port));
    if (inet_pton(AF_INET, ip.c_str(), &addr.sin_addr) == 1) {
      targets.push_back(addr);
    }
  }

  if (targets.empty()) {
    std::cerr << "No valid IPv4 targets.\n";
    closesocket(udpSocket);
    WSACleanup();
    return 2;
  }

  std::thread stdinThread([] {
    int ch;
    while ((ch = std::cin.get()) != EOF) {
      if (ch == 'q' || ch == 'Q') break;
    }
    g_running = false;
  });

  HRESULT hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED);
  if (FAILED(hr)) {
    g_running = false;
    stdinThread.join();
    closesocket(udpSocket);
    WSACleanup();
    return 1;
  }

  IMMDeviceEnumerator* enumerator = nullptr;
  IMMDevice* device = nullptr;
  IAudioClient* audioClient = nullptr;
  IAudioCaptureClient* captureClient = nullptr;
  WAVEFORMATEX* mixFormat = nullptr;
  HANDLE captureEvent = nullptr;
  HANDLE avrtHandle = nullptr;
  DWORD avrtTaskIndex = 0;

  hr = CoCreateInstance(__uuidof(MMDeviceEnumerator), nullptr, CLSCTX_ALL,
                        __uuidof(IMMDeviceEnumerator),
                        reinterpret_cast<void**>(&enumerator));
  if (SUCCEEDED(hr)) {
    hr = enumerator->GetDefaultAudioEndpoint(eRender, eConsole, &device);
  }
  if (SUCCEEDED(hr)) {
    hr = device->Activate(__uuidof(IAudioClient), CLSCTX_ALL, nullptr,
                          reinterpret_cast<void**>(&audioClient));
  }
  if (SUCCEEDED(hr)) hr = audioClient->GetMixFormat(&mixFormat);

  captureEvent = CreateEvent(nullptr, FALSE, FALSE, nullptr);
  if (SUCCEEDED(hr) && captureEvent) {
    REFERENCE_TIME bufferDuration = 200000;  // 20 ms
    hr = audioClient->Initialize(
        AUDCLNT_SHAREMODE_SHARED,
        AUDCLNT_STREAMFLAGS_LOOPBACK | AUDCLNT_STREAMFLAGS_EVENTCALLBACK,
        bufferDuration, 0, mixFormat, nullptr);
  }
  if (SUCCEEDED(hr)) hr = audioClient->SetEventHandle(captureEvent);
  if (SUCCEEDED(hr)) {
    hr = audioClient->GetService(__uuidof(IAudioCaptureClient),
                                 reinterpret_cast<void**>(&captureClient));
  }
  if (SUCCEEDED(hr)) hr = audioClient->Start();

  if (FAILED(hr)) {
    std::cerr << "WASAPI loopback capture failed: 0x" << std::hex << hr << "\n";
    g_running = false;
  } else {
    avrtHandle = AvSetMmThreadCharacteristicsW(L"Pro Audio", &avrtTaskIndex);
    std::cout << "Streaming Windows system audio to " << targets.size()
              << " target(s) on UDP " << port << ".\n";
  }

  std::vector<int16_t> pcmQueue;
  int sequence = 0;
  while (g_running) {
    DWORD wait = WaitForSingleObject(captureEvent, 50);
    if (wait != WAIT_OBJECT_0) continue;

    for (;;) {
      UINT32 packetFrames = 0;
      hr = captureClient->GetNextPacketSize(&packetFrames);
      if (FAILED(hr) || packetFrames == 0) break;

      BYTE* data = nullptr;
      UINT32 frames = 0;
      DWORD flags = 0;
      hr = captureClient->GetBuffer(&data, &frames, &flags, nullptr, nullptr);
      if (FAILED(hr)) break;

      if ((flags & AUDCLNT_BUFFERFLAGS_SILENT) != 0) {
        const int outFrames = static_cast<int>(
            (static_cast<int64_t>(frames) * kSampleRate + mixFormat->nSamplesPerSec - 1) /
            mixFormat->nSamplesPerSec);
        std::vector<int16_t> silence(outFrames * kChannels, 0);
        pcmQueue.insert(pcmQueue.end(), silence.begin(), silence.end());
      } else {
        AppendConvertedFrames(data, frames, mixFormat, pcmQueue);
      }
      captureClient->ReleaseBuffer(frames);

      while (pcmQueue.size() >= kFrameSamples * kChannels) {
        SendFrame(udpSocket, targets, pcmQueue.data(), sequence);
        sequence = (sequence + 1) & 0xFFFF;
        pcmQueue.erase(pcmQueue.begin(), pcmQueue.begin() + kFrameSamples * kChannels);
      }
    }
  }

  if (audioClient) audioClient->Stop();
  if (avrtHandle) AvRevertMmThreadCharacteristics(avrtHandle);
  if (captureEvent) CloseHandle(captureEvent);
  if (mixFormat) CoTaskMemFree(mixFormat);
  if (captureClient) captureClient->Release();
  if (audioClient) audioClient->Release();
  if (device) device->Release();
  if (enumerator) enumerator->Release();
  CoUninitialize();
  closesocket(udpSocket);
  WSACleanup();
  if (stdinThread.joinable()) stdinThread.join();
  return 0;
}
