#pragma once
namespace ring {
// Preserve complete flushed NDJSON records; archive an unACKed torn tail.
// Source stays intact until the recovered prefix has been synced and renamed.
bool recoverSpool(const char* path);
}
