# AITRIP 30-pin CP2102 ESP-WROOM-32: USB flashing

Use the **esp32dev** target for the AITRIP Type-C 30-pin ESP-WROOM-32 / ESP-32S
board. The CP2102 is the USB-to-serial interface; the pin count and USB connector
do not change the firmware target. This firmware requires at least **4 MB flash**.
No external wiring is needed: power and flash through a USB data cable.

## Configure and flash your board

The bridge uses compile-time configuration. Public CI binaries use placeholders;
they are build evidence, **not a configured bridge**. Build locally after setting
your private configuration. Never publish your configured binary: it contains
your Wi-Fi password and collector token.

1. Install Python 3 and PlatformIO Core: `python -m pip install platformio==6.2.0`.
2. Clone this repository and enter `esp32_bridge/firmware`.
3. Copy `include/secrets.h.example` to `include/secrets.h` (ignored by Git).
4. Set `WIFI_SSID`, `WIFI_PASSWORD`, `COLLECTOR_URL` and `COLLECTOR_TOKEN`.
   Start the collector using the bridge README; `/health` must respond.
   Wi-Fi must be 2.4 GHz. The collector token must match its `RING_TOKEN`.
5. Set the exact advertised `RING_NAME`, if known. Otherwise leave the placeholder
   for discovery. With Wi-Fi and the collector working, during the default
   9 AM–10 PM Eastern sync window, serial prints nearby BLE names. Set the exact
   name and rebuild/reflash. Outside that window, temporarily adjust the local
   `SYNC_START_HOUR`/`SYNC_END_HOUR` settings to permit discovery.
6. Connect USB and identify the port with `pio device list`.
7. Confirm flash capacity using `python -m esptool --chip esp32 --port PORT flash-id`
   (install `esptool` with pip if needed). Do not flash a module below 4 MB.
8. Run `pio run -e esp32dev -t upload --upload-port PORT`.
9. Read serial with `pio device monitor --port PORT -b 115200`.

Replace `PORT` with `COM3` (Windows), `/dev/ttyUSB0` (Linux), or the matching
`/dev/cu.*` device (macOS). If no serial port appears, install the Silicon Labs
CP210x VCP driver. If connection stalls, hold **BOOT**, start upload, release it
when writing starts; press **EN/RESET** after upload if needed. Try a different
data cable or 115200 upload baud if transfers fail.

## Binary artifacts and preserving stored history

The workflow publishes a separate bundle for each target. **Choose esp32dev,
not esp32c6**, for this board. Each bundle includes the app, bootloader, partition
table, factory image, and SHA256SUMS. Verify hashes with `sha256sum -c SHA256SUMS`
(on macOS, `shasum -a 256 -c SHA256SUMS`).

For a **new/blank board only**, a locally configured factory image can be flashed
with esptool 5.x:

```sh
python -m esptool --chip esp32 --port PORT --baud 460800 write-flash 0x0 firmware.factory.bin
```

The factory image includes padding across the NVS area. **Do not use it to update
a bridge holding data**: it resets NVS, including the filesystem-format guard.
With an unchanged partition layout, use the application-only update:

```sh
python -m esptool --chip esp32 --port PORT --baud 460800 write-flash 0x10000 firmware.bin
```

Do not erase flash, upload a filesystem image, or change partitions on a bridge
with unuploaded history. The app occupies `0x10000`–`0x20ffff`; LittleFS starts at
`0x210000`. There is no OTA slot. A USB upload/checksum verifies flash transfer,
not successful RingConn pairing or synchronization.

## First physical acceptance test

Keep the ring nearby and temporarily prevent the phone app from competing for
the BLE connection. Check serial for discovery, bonding, authentication, page
ACKs, and `Gen2 sleep + daytime channels synchronized`. Check authenticated
collector `/status` for both persisted channels and `last_complete_sync`.
Compare timestamped measurements with the official app, then test a reboot and
Wi-Fi interruption. Retain the official app and its history until these checks
pass. The software test suite does not certify physical board/ring behavior.
