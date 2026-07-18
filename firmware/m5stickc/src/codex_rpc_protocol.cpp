#include "codex_rpc_protocol.h"

#include <errno.h>
#include <stdlib.h>
#include <string.h>

namespace {

bool isWhitespace(char byte) {
  return byte == ' ' || byte == '\t' || byte == '\r' || byte == '\n';
}

const char* findTopLevelValue(const char* json, const char* key) {
  if (json == nullptr || key == nullptr || *key == '\0') return nullptr;

  const size_t keyLength = strlen(key);
  int depth = 0;
  bool inString = false;
  bool escaped = false;
  for (const char* cursor = json; *cursor != '\0'; ++cursor) {
    const char byte = *cursor;
    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (byte == '\\') {
        escaped = true;
      } else if (byte == '"') {
        inString = false;
      }
      continue;
    }

    if (byte == '"') {
      const size_t remaining = strlen(cursor + 1);
      if (depth == 1 && remaining >= keyLength + 1 &&
          strncmp(cursor + 1, key, keyLength) == 0 &&
          cursor[keyLength + 1] == '"') {
        const char* value = cursor + keyLength + 2;
        while (isWhitespace(*value)) ++value;
        if (*value == ':') {
          do {
            ++value;
          } while (isWhitespace(*value));
          return value;
        }
      }
      inString = true;
    } else if (byte == '{' || byte == '[') {
      ++depth;
    } else if (byte == '}' || byte == ']') {
      --depth;
    }
  }
  return nullptr;
}

}  // namespace

bool extractTopLevelMethod(const char* json, char* method, size_t capacity) {
  if (method == nullptr || capacity == 0) return false;
  method[0] = '\0';
  const char* value = findTopLevelValue(json, "method");
  if (value == nullptr || *value != '"') return false;

  size_t length = 0;
  bool escaped = false;
  for (const char* cursor = value + 1; *cursor != '\0'; ++cursor) {
    if (escaped) return false;
    if (*cursor == '\\') {
      escaped = true;
      continue;
    }
    if (*cursor == '"') {
      if (length >= capacity) return false;
      method[length] = '\0';
      return true;
    }
    if (length + 1 >= capacity) return false;
    method[length++] = *cursor;
  }
  return false;
}

bool extractTopLevelRequestId(const char* json, long* requestId) {
  if (requestId == nullptr) return false;
  const char* value = findTopLevelValue(json, "id");
  if (value == nullptr) return false;

  errno = 0;
  char* end = nullptr;
  const long parsed = strtol(value, &end, 10);
  if (end == value || errno == ERANGE || parsed < 0) return false;
  while (isWhitespace(*end)) ++end;
  if (*end != ',' && *end != '}') return false;
  *requestId = parsed;
  return true;
}
