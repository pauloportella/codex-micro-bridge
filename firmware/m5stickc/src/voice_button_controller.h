#pragma once

#include <stdint.h>

class VoiceButtonController {
 public:
  enum class Action : uint8_t {
    Start,
    Stop,
    Ignore,
  };

  Action nextAction();
  bool observedRecording();
  void observedProcessing();
  void observedCompleted();
  void observedIdle();
  void reset();

 private:
  enum class Phase : uint8_t {
    Ready,
    WaitingForStop,
    Blocked,
  };

  Phase phase_ = Phase::Ready;
};
