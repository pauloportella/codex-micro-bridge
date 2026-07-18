#include "voice_button_controller.h"

VoiceButtonController::Action VoiceButtonController::nextAction() {
  switch (phase_) {
    case Phase::Ready:
      phase_ = Phase::WaitingForStop;
      return Action::Start;
    case Phase::WaitingForStop:
      phase_ = Phase::Blocked;
      return Action::Stop;
    case Phase::Blocked:
      return Action::Ignore;
  }
  return Action::Ignore;
}

bool VoiceButtonController::observedRecording() {
  if (phase_ == Phase::Blocked) return false;
  phase_ = Phase::WaitingForStop;
  return true;
}

void VoiceButtonController::observedProcessing() { phase_ = Phase::Blocked; }

void VoiceButtonController::observedCompleted() { phase_ = Phase::Blocked; }

void VoiceButtonController::observedIdle() { phase_ = Phase::Ready; }

void VoiceButtonController::reset() { phase_ = Phase::Ready; }
