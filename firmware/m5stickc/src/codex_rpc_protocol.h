#pragma once

#include <stddef.h>

bool extractTopLevelMethod(const char* json, char* method, size_t capacity);
bool extractTopLevelRequestId(const char* json, long* requestId);
