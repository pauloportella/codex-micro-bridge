#include <cassert>

#include "voice_button_controller.h"

int main() {
  VoiceButtonController controller;
  using Action = VoiceButtonController::Action;

  assert(controller.nextAction() == Action::Start);
  assert(controller.nextAction() == Action::Stop);
  assert(controller.nextAction() == Action::Ignore);

  controller.observedIdle();
  assert(controller.nextAction() == Action::Start);
  assert(controller.observedRecording());
  assert(controller.nextAction() == Action::Stop);
  assert(!controller.observedRecording());
  assert(controller.nextAction() == Action::Ignore);

  controller.observedProcessing();
  assert(controller.nextAction() == Action::Ignore);
  controller.observedCompleted();
  assert(controller.nextAction() == Action::Ignore);

  controller.observedIdle();
  assert(controller.nextAction() == Action::Start);
  controller.reset();
  assert(controller.nextAction() == Action::Start);

  return 0;
}
