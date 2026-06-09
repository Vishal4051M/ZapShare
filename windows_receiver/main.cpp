#include <iostream>
#include <vector>
#include <queue>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <chrono>
#include <array>
#include <unordered_map>
#include <string>

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <winsock2.h>
#include <ws2tcpip.h>
#include <mmdeviceapi.h>
#include <audioclient.h>
#include <combaseapi.h>

#include "opus.h"

#pragma comment(lib, "ws2_32.lib")
#pragma comment(lib, "ole32.lib")

#define REFTIMES_PER_SEC  10000000
#define SAMPLE_RATE 48000
#define CHANNELS 2
#define FRAME_SIZE 960 // 20ms at 48kHz
#define FEC_GROUP_SIZE 4
#define FEC_SIZE_TABLE_BYTES (FEC_GROUP_SIZE * 2)

const IID IID_IAudioClient = __uuidof(IAudioClient);
const IID IID_IAudioRenderClient = __uuidof(IAudioRenderClient);
const IID IID_IMMDeviceEnumerator = __uuidof(IMMDeviceEnumerator);
const CLSID CLSID_MMDeviceEnumerator = __uuidof(MMDeviceEnumerator);

// Global settings with default fallback values
int g_port = 50005;
int g_cushionMs = 30;

struct AudioPacket {
    int seqNum;
    uint64_t timestamp;
    std::vector<uint8_t> payload;

    bool operator<(const AudioPacket& other) const {
        return seqNum > other.seqNum; // For min-heap priority queue
    }
};

std::priority_queue<AudioPacket> jitterBuffer;
std::mutex jbMutex;
std::condition_variable jbCv;
bool isRunning = true;

struct FecGroup {
    int startSeq = 0;
    std::array<std::vector<uint8_t>, FEC_GROUP_SIZE> packets;
    std::array<bool, FEC_GROUP_SIZE> hasPacket{ false, false, false, false };
    std::array<int, FEC_GROUP_SIZE> sizes{ 0, 0, 0, 0 };
    std::vector<uint8_t> parity;
    bool hasParity = false;
    uint64_t lastUpdateMs = 0;
};

std::unordered_map<int, FecGroup> fecGroups;

int SeqDistance(int a, int b) {
    int dist = a - b;
    if (dist > 32767) return dist - 65536;
    if (dist < -32768) return dist + 65536;
    return dist;
}

int GroupStartSeq(int seq) {
    return seq - (seq % FEC_GROUP_SIZE);
}

int GroupIndex(int startSeq, int seq) {
    int diff = (seq - startSeq + 65536) % 65536;
    return (diff >= 0 && diff < FEC_GROUP_SIZE) ? diff : -1;
}

void PruneFecGroups(uint64_t nowMs) {
    if (fecGroups.size() <= 64) return;
    std::vector<int> toRemove;
    for (const auto& kv : fecGroups) {
        if (nowMs - kv.second.lastUpdateMs > 2000) {
            toRemove.push_back(kv.first);
        }
    }
    for (int key : toRemove) {
        fecGroups.erase(key);
    }
}

void EnqueueAudioPacket(int seq, uint64_t timestamp, const std::vector<uint8_t>& payload) {
    AudioPacket packet;
    packet.seqNum = seq;
    packet.timestamp = timestamp;
    packet.payload = payload;

    std::lock_guard<std::mutex> lock(jbMutex);
    jitterBuffer.push(packet);
    jbCv.notify_one();
}

void TryRecoverFecGroup(FecGroup& group) {
    if (!group.hasParity) return;
    int missingIndex = -1;
    int presentCount = 0;
    for (int i = 0; i < FEC_GROUP_SIZE; ++i) {
        if (group.hasPacket[i]) {
            presentCount++;
        } else {
            missingIndex = i;
        }
    }
    if (presentCount != FEC_GROUP_SIZE - 1 || missingIndex < 0) return;

    int missingSize = group.sizes[missingIndex];
    if (missingSize <= 0 || group.parity.empty()) return;

    std::vector<uint8_t> recovered(missingSize, 0);
    const int maxSize = static_cast<int>(group.parity.size());
    for (int i = 0; i < maxSize; ++i) {
        uint8_t value = group.parity[i];
        for (int k = 0; k < FEC_GROUP_SIZE; ++k) {
            if (group.hasPacket[k] && i < static_cast<int>(group.packets[k].size())) {
                value ^= group.packets[k][i];
            }
        }
        if (i < missingSize) {
            recovered[i] = value;
        }
    }

    group.packets[missingIndex] = recovered;
    group.hasPacket[missingIndex] = true;

    if (recovered.size() >= 11 && recovered[0] == 0x01) {
        int seq = ((recovered[1] & 0xFF) << 8) | (recovered[2] & 0xFF);
        uint64_t ts = 0;
        for (int i = 0; i < 8; ++i) {
            ts = (ts << 8) | (recovered[3 + i] & 0xFF);
        }
        std::vector<uint8_t> payload(recovered.begin() + 11, recovered.end());
        EnqueueAudioPacket(seq, ts, payload);
    }
}

void HandleFecPacket(int seqStart, const std::vector<uint8_t>& payload) {
    if (payload.size() <= FEC_SIZE_TABLE_BYTES) return;

    FecGroup& group = fecGroups[seqStart];
    group.startSeq = seqStart;
    group.hasParity = true;
    group.lastUpdateMs = GetTickCount64();

    int maxSize = 0;
    for (int i = 0; i < FEC_GROUP_SIZE; ++i) {
        int hi = payload[i * 2] & 0xFF;
        int lo = payload[i * 2 + 1] & 0xFF;
        int size = (hi << 8) | lo;
        group.sizes[i] = size;
        if (size > maxSize) maxSize = size;
    }
    if (payload.size() < static_cast<size_t>(FEC_SIZE_TABLE_BYTES + maxSize)) return;

    group.parity.assign(payload.begin() + FEC_SIZE_TABLE_BYTES, payload.begin() + FEC_SIZE_TABLE_BYTES + maxSize);
    TryRecoverFecGroup(group);
    bool allPresent = true;
    for (int i = 0; i < FEC_GROUP_SIZE; ++i) {
        if (!group.hasPacket[i]) {
            allPresent = false;
            break;
        }
    }
    if (allPresent) {
        fecGroups.erase(seqStart);
    }
}

void HandleFecAudioPacket(int seq, const std::vector<uint8_t>& packetBytes) {
    int startSeq = GroupStartSeq(seq);
    int index = GroupIndex(startSeq, seq);
    if (index < 0) return;

    FecGroup& group = fecGroups[startSeq];
    group.startSeq = startSeq;
    group.packets[index] = packetBytes;
    group.hasPacket[index] = true;
    group.lastUpdateMs = GetTickCount64();
    TryRecoverFecGroup(group);
    bool allPresent = true;
    for (int i = 0; i < FEC_GROUP_SIZE; ++i) {
        if (!group.hasPacket[i]) {
            allPresent = false;
            break;
        }
    }
    if (allPresent) {
        fecGroups.erase(startSeq);
    }
}

void UdpReceiverThread() {
    WSADATA wsaData;
    if (WSAStartup(MAKEWORD(2, 2), &wsaData) != 0) {
        std::cerr << "WSAStartup failed." << std::endl;
        return;
    }

    SOCKET recvSocket = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (recvSocket == INVALID_SOCKET) {
        std::cerr << "Socket failed." << std::endl;
        WSACleanup();
        return;
    }

    sockaddr_in recvAddr;
    recvAddr.sin_family = AF_INET;
    recvAddr.sin_port = htons(g_port);
    recvAddr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(recvSocket, (SOCKADDR*)&recvAddr, sizeof(recvAddr)) == SOCKET_ERROR) {
        std::cerr << "Bind failed." << std::endl;
        closesocket(recvSocket);
        WSACleanup();
        return;
    }

    std::cout << "Listening for ZapShare Audio on UDP port " << g_port << "..." << std::endl;

    std::vector<uint8_t> buffer(8192);
    sockaddr_in senderAddr;
    int senderAddrSize = sizeof(senderAddr);
    int packetCount = 0;

    while (isRunning) {
        int bytesReceived = recvfrom(recvSocket, (char*)buffer.data(), buffer.size(), 0, (SOCKADDR*)&senderAddr, &senderAddrSize);
        if (bytesReceived > 11) {
            packetCount++;
            uint8_t type = buffer[0];
            int seq = ((buffer[1] & 0xFF) << 8) | (buffer[2] & 0xFF);

            if (type == 0x02) {
                continue;
            }

            if (type == 0x03) {
                std::vector<uint8_t> payload(buffer.begin() + 11, buffer.begin() + bytesReceived);
                HandleFecPacket(seq, payload);
            } else if (type == 0x01) {
                uint64_t timestamp = 0;
                for (int i = 0; i < 8; i++) {
                    timestamp = (timestamp << 8) | (buffer[3 + i] & 0xFF);
                }
                std::vector<uint8_t> payload(buffer.begin() + 11, buffer.begin() + bytesReceived);
                std::vector<uint8_t> packetBytes(buffer.begin(), buffer.begin() + bytesReceived);

                HandleFecAudioPacket(seq, packetBytes);
                EnqueueAudioPacket(seq, timestamp, payload);
            }

            if (packetCount % 200 == 0) {
                PruneFecGroups(GetTickCount64());
            }
        }
    }

    closesocket(recvSocket);
    WSACleanup();
}

void WasapiPlayerThread() {
    HRESULT hr = CoInitializeEx(NULL, COINIT_MULTITHREADED);
    if (FAILED(hr)) return;

    IMMDeviceEnumerator *pEnumerator = NULL;
    IMMDevice *pDevice = NULL;
    IAudioClient *pAudioClient = NULL;
    IAudioRenderClient *pRenderClient = NULL;
    WAVEFORMATEX *pwfx = NULL;

    hr = CoCreateInstance(CLSID_MMDeviceEnumerator, NULL, CLSCTX_ALL, IID_IMMDeviceEnumerator, (void**)&pEnumerator);
    if (FAILED(hr)) goto Exit;

    hr = pEnumerator->GetDefaultAudioEndpoint(eRender, eConsole, &pDevice);
    if (FAILED(hr)) goto Exit;

    hr = pDevice->Activate(IID_IAudioClient, CLSCTX_ALL, NULL, (void**)&pAudioClient);
    if (FAILED(hr)) goto Exit;

    hr = pAudioClient->GetMixFormat(&pwfx);
    if (FAILED(hr)) goto Exit;

    // Use shared mode format but adapt for our PCM data 
    // We expect 48000Hz, 16-bit, 2-channel
    pwfx->nSamplesPerSec = SAMPLE_RATE;
    pwfx->nChannels = CHANNELS;
    pwfx->wBitsPerSample = 16;
    pwfx->nBlockAlign = CHANNELS * (16 / 8);
    pwfx->nAvgBytesPerSec = SAMPLE_RATE * pwfx->nBlockAlign;
    if (pwfx->wFormatTag == WAVE_FORMAT_EXTENSIBLE) {
        WAVEFORMATEXTENSIBLE *pEx = (WAVEFORMATEXTENSIBLE *)pwfx;
        pEx->SubFormat = KSDATAFORMAT_SUBTYPE_PCM;
        pEx->Samples.wValidBitsPerSample = 16;
    } else {
        pwfx->wFormatTag = WAVE_FORMAT_PCM;
    }

    hr = pAudioClient->Initialize(AUDCLNT_SHAREMODE_SHARED, 0, REFTIMES_PER_SEC, 0, pwfx, NULL);
    if (FAILED(hr)) {
        std::cerr << "WASAPI Initialize failed." << std::endl;
        goto Exit;
    }

    UINT32 bufferFrameCount;
    hr = pAudioClient->GetBufferSize(&bufferFrameCount);
    if (FAILED(hr)) goto Exit;

    hr = pAudioClient->GetService(IID_IAudioRenderClient, (void**)&pRenderClient);
    if (FAILED(hr)) goto Exit;

    hr = pAudioClient->Start();
    if (FAILED(hr)) goto Exit;

    // OPUS Setup
    {
        int err;
        OpusDecoder* decoder = opus_decoder_create(SAMPLE_RATE, CHANNELS, &err);
        if (err != OPUS_OK) {
            std::cerr << "Failed to create OPUS Decoder. Error code: " << err << std::endl;
            goto Exit;
        }

        std::cout << "Audio player and OPUS decoder initialized. Waiting for stream..." << std::endl;

        // Jitter buffer initial wait (dynamic based on g_cushionMs parameter)
        std::this_thread::sleep_for(std::chrono::milliseconds(g_cushionMs));

        int expectedSeq = -1;
        std::vector<int16_t> pcmOut(5760 * CHANNELS); 

        auto WritePcm = [&](int framesDecoded) {
            if (framesDecoded <= 0) return;
            for (;;) {
                UINT32 numFramesPadding;
                hr = pAudioClient->GetCurrentPadding(&numFramesPadding);
                if (FAILED(hr)) break;

                UINT32 numFramesAvailable = bufferFrameCount - numFramesPadding;
                if (numFramesAvailable >= static_cast<UINT32>(framesDecoded)) {
                    BYTE *pData;
                    hr = pRenderClient->GetBuffer(framesDecoded, &pData);
                    if (SUCCEEDED(hr)) {
                        memcpy(pData, pcmOut.data(), framesDecoded * CHANNELS * sizeof(int16_t));
                        hr = pRenderClient->ReleaseBuffer(framesDecoded, 0);
                    }
                    break;
                }
                std::this_thread::sleep_for(std::chrono::milliseconds(1));
            }
        };

        while (isRunning) {
            std::unique_lock<std::mutex> lock(jbMutex);
            if (jitterBuffer.empty()) {
                jbCv.wait_for(lock, std::chrono::milliseconds(5));
                continue;
            }

            AudioPacket packet = jitterBuffer.top();
            jitterBuffer.pop();
            lock.unlock();

            if (expectedSeq != -1) {
                int dist = SeqDistance(packet.seqNum, expectedSeq);
                if (dist < 0 && dist > -300) {
                    continue; // Skip late packets
                } else if (dist > 0) {
                    int plcCount = (dist < 50) ? dist : 50;
                    for (int i = 0; i < plcCount; ++i) {
                        int plcFrames = opus_decode(decoder, nullptr, 0, pcmOut.data(), 5760, 0);
                        WritePcm(plcFrames);
                    }
                }
            }
            expectedSeq = (packet.seqNum + 1) % 65536;

            int framesDecoded = opus_decode(decoder, packet.payload.data(), packet.payload.size(), pcmOut.data(), 5760, 0);
            if (framesDecoded < 0) {
                // Not OPUS encoded, maybe raw PCM fallback?
                if (packet.payload.size() == FRAME_SIZE * CHANNELS * sizeof(int16_t)) {
                    framesDecoded = FRAME_SIZE;
                    memcpy(pcmOut.data(), packet.payload.data(), packet.payload.size());
                } else {
                    continue;
                }
            }

            WritePcm(framesDecoded);
        }

        opus_decoder_destroy(decoder);
    }

Exit:
    if (pRenderClient) pRenderClient->Release();
    if (pAudioClient) pAudioClient->Release();
    if (pDevice) pDevice->Release();
    if (pEnumerator) pEnumerator->Release();
    if (pwfx) CoTaskMemFree(pwfx);
    CoUninitialize();
}

int main(int argc, char* argv[]) {
    // Parse arguments
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        if ((arg == "--port" || arg == "-p") && i + 1 < argc) {
            try {
                g_port = std::stoi(argv[++i]);
            } catch (...) {}
        } else if ((arg == "--cushion" || arg == "-c") && i + 1 < argc) {
            try {
                g_cushionMs = std::stoi(argv[++i]);
            } catch (...) {}
        }
    }

    std::thread playerThread(WasapiPlayerThread);
    std::thread udpThread(UdpReceiverThread);

    // Stdin monitoring thread: when stdin closes (EOF) or 'q' is received, clean up and exit
    std::thread stdinThread([]() {
        int ch;
        while ((ch = std::cin.get()) != EOF) {
            if (ch == 'q' || ch == 'Q') {
                break;
            }
        }
        isRunning = false;
        jbCv.notify_all();
    });

    if (stdinThread.joinable()) stdinThread.join();
    if (udpThread.joinable()) udpThread.join();
    if (playerThread.joinable()) playerThread.join();

    return 0;
}
