// Local-only config generation. No network or persistence calls in this module.
export function buildConfig(input) {
  const bytes = (value) => new TextEncoder().encode(value).length;
  if (
    !input.ssid ||
    bytes(input.ssid) > 32 ||
    /[\x00-\x1f\x7f]/.test(input.ssid)
  )
    throw new Error("Wi-Fi name must be 1–32 UTF-8 bytes.");
  if (/[\x00-\x1f\x7f]/.test(input.password))
    throw new Error("Wi-Fi password contains unsupported control bytes.");
  if (
    input.password &&
    !(bytes(input.password) >= 8 && bytes(input.password) <= 63) &&
    !/^[a-f0-9]{64}$/i.test(input.password)
  )
    throw new Error(
      "Wi-Fi password must be 8–63 bytes, 64 hexadecimal characters, or empty for an open network.",
    );
  let url;
  try {
    url = new URL(input.collector);
  } catch {
    throw new Error("Enter the trusted LAN HTTP collector URL.");
  }
  if (url.pathname !== "/")
    throw new Error("Use the collector root URL without a path prefix.");
  if (
    url.protocol !== "http:" ||
    url.username ||
    url.password ||
    url.search ||
    url.hash
  )
    throw new Error(
      "Use the trusted LAN HTTP collector URL, without credentials or query parameters.",
    );
  if (
    !/^[A-Za-z0-9_-]{20,128}$/.test(input.token) ||
    input.token.startsWith("CHANGE_")
  )
    throw new Error(
      "Collector token must be your configured 20–128 character token.",
    );
  if (
    !input.ringName?.trim() ||
    /XXXX|CHANGE_/i.test(input.ringName) ||
    /^(RingConn|CHANGE.*)$/i.test(input.ringName) ||
    bytes(input.ringName) > 64 ||
    /[\r\n]/.test(input.ringName)
  )
    throw new Error(
      "Use the exact advertisement name from the USB serial scan.",
    );
  if (input.mac && !/^(?:[a-f0-9]{2}:){5}[a-f0-9]{2}$/i.test(input.mac))
    throw new Error("Optional System ID MAC must have six hexadecimal pairs.");
  if (
    ![
      "EST5EDT,M3.2.0,M11.1.0",
      "CST6CDT,M3.2.0,M11.1.0",
      "MST7MDT,M3.2.0,M11.1.0",
      "PST8PDT,M3.2.0,M11.1.0",
      "MST7",
      "UTC0",
    ].includes(input.timezone)
  )
    throw new Error("Choose a supported firmware timezone preset.");
  const start = Number(input.start),
    end = Number(input.end),
    interval = Number(input.interval);
  if (
    !Number.isInteger(start) ||
    !Number.isInteger(end) ||
    start < 0 ||
    end > 24 ||
    start >= end ||
    !Number.isInteger(interval) ||
    interval < 1 ||
    interval > 24
  )
    throw new Error(
      "Choose a valid schedule: start before end, hours 0–24, interval 1–24 hours.",
    );
  if (!["esp32dev", "esp32c6"].includes(input.board))
    throw new Error("Select a supported ESP32 board.");
  const values = {
    WIFI_SSID: input.ssid,
    WIFI_PASSWORD: input.password,
    COLLECTOR_URL: url.href.replace(/\/$/, ""),
    COLLECTOR_TOKEN: input.token,
    RING_NAME: input.ringName,
    RING_MAC: input.mac.toUpperCase(),
    LOCAL_TIMEZONE: input.timezone,
  };
  return (
    "#pragma once\n// Generated locally. Contains secrets: keep out of source control.\n" +
    Object.entries(values)
      .map(([key, value]) => `#define ${key} ${JSON.stringify(value)}`)
      .join("\n") +
    `\n#define SYNC_START_HOUR ${start}\n#define SYNC_END_HOUR ${end}\n#define SYNC_INTERVAL_SECONDS (${interval}UL * 3600UL)\n`
  );
}
