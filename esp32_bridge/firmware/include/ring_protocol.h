#pragma once
#include <cstdint>
#include <cstddef>
namespace ring {
constexpr uint64_t EPOCH = 1577793600ULL;
constexpr const char* SERVICE_UUID = "8327ad99-2d87-4a22-a8ce-6dd7971c0437";
constexpr const char* WRITE_UUID   = "8327ad98-2d87-4a22-a8ce-6dd7971c0437";
constexpr const char* NOTIFY_UUID  = "8327ad97-2d87-4a22-a8ce-6dd7971c0437";
uint8_t xorChecksum(const uint8_t* bytes, size_t len);
bool validFrame(const uint8_t* bytes, size_t len);
void sm3(const uint8_t* bytes, size_t len, uint8_t out[32]);
void authResponse(const uint8_t mac[6], uint8_t challenge, uint8_t out[6]);
void syncOpen(uint64_t utc, uint8_t channel, uint8_t out[9]);
}