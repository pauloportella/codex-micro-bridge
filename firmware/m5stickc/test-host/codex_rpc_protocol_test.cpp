#include <cassert>
#include <cstring>

#include "codex_rpc_protocol.h"

int main() {
  long requestId = -1;
  char method[24]{};

  const char* threadStatus =
      "{\"method\":\"v.oai.thstatus\",\"params\":[{\"id\":0},{\"id\":1}],"
      "\"id\":993}";
  assert(extractTopLevelRequestId(threadStatus, &requestId));
  assert(requestId == 993);
  assert(extractTopLevelMethod(threadStatus, method, sizeof(method)));
  assert(strcmp(method, "v.oai.thstatus") == 0);

  const char* topLevelFirst =
      "{\"id\":137,\"method\":\"v.oai.rgbcfg\",\"params\":{\"id\":0}}";
  assert(extractTopLevelRequestId(topLevelFirst, &requestId));
  assert(requestId == 137);

  const char* nestedMethod =
      "{\"params\":{\"method\":\"wrong\"},\"method\":\"device.status\",\"id\":4}";
  assert(extractTopLevelMethod(nestedMethod, method, sizeof(method)));
  assert(strcmp(method, "device.status") == 0);

  assert(!extractTopLevelRequestId(
      "{\"method\":\"v.oai.hid\",\"params\":{\"id\":4}}", &requestId));
  assert(!extractTopLevelRequestId(nullptr, &requestId));
  assert(!extractTopLevelRequestId("{}", nullptr));
  assert(!extractTopLevelRequestId("{\"id\":12oops}", &requestId));
  assert(!extractTopLevelRequestId("{\"id\":-1}", &requestId));
  assert(!extractTopLevelRequestId("{\"id\":999999999999999999999}",
                                  &requestId));
  assert(!extractTopLevelRequestId("{\"i\":1}", &requestId));
  assert(!extractTopLevelMethod("{\"params\":{\"method\":\"nested\"}}", method,
                               sizeof(method)));
  assert(!extractTopLevelMethod("{\"method\":\"too-long-for-buffer\"}", method,
                               4));

  return 0;
}
