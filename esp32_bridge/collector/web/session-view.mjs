// A request may expire while a newer sign-in finishes. Re-check after async cleanup.
export async function clearExpiredSession(expected, current, clear, hide) {
  if (expected !== current()) return;
  await clear();
  if (expected === current()) hide();
}
