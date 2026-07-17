const RIDE_BUTTONS = new Set([
  "navigationLeft",
  "navigationUp",
  "navigationRight",
  "navigationDown",
  "a",
  "b",
  "y",
  "z",
  "shiftUpLeft",
  "shiftDownLeft",
  "shiftUpRight",
  "shiftDownRight",
  "powerUpLeft",
  "powerUpRight",
  "onOffLeft",
  "onOffRight",
  "paddleLeft",
  "paddleRight",
]);

const ACTION_TYPES = new Set(["key", "press", "turn"]);

class RideMapper {
  constructor(config) {
    this.config = validateRideConfig(config);
    this.byButton = new Map(this.config.mappings.map((mapping) => [mapping.button, mapping]));
  }

  process(event) {
    if (event?.message !== "button" || !["down", "up"].includes(event.state)) return [];
    const mapping = this.byButton.get(event.button);
    if (!mapping) return [];
    const action = mapping.action;

    if (action.type === "key") {
      return [{
        type: "hid",
        key: action.key,
        act: event.state === "down" ? 1 : 0,
        ...(action.agent == null ? {} : { agent: action.agent }),
      }];
    }
    if (event.state === "up") return [];
    if (action.type === "press") {
      return [{
        type: "press",
        key: action.key,
        durationMs: action.durationMs ?? 60,
        ...(action.agent == null ? {} : { agent: action.agent }),
      }];
    }
    if (action.type === "turn") {
      return [{
        type: "hid",
        key: action.direction === "cw" ? "ENC_CW" : "ENC_CC",
        act: 2,
      }];
    }
    return [];
  }
}

function validateRideConfig(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("Zwift Ride config must be a JSON object");
  }
  if (!Array.isArray(value.mappings) || value.mappings.length === 0) {
    throw new Error("Zwift Ride config needs at least one mapping");
  }

  const seen = new Set();
  const mappings = value.mappings.map((mapping, index) => {
    if (!mapping || typeof mapping !== "object") {
      throw new Error(`Mapping ${index + 1} must be an object`);
    }
    if (!RIDE_BUTTONS.has(mapping.button)) {
      throw new Error(`Mapping ${index + 1} has an unknown Zwift Ride button: ${mapping.button}`);
    }
    if (seen.has(mapping.button)) {
      throw new Error(`Zwift Ride button is mapped more than once: ${mapping.button}`);
    }
    seen.add(mapping.button);
    if (!mapping.action || !ACTION_TYPES.has(mapping.action.type)) {
      throw new Error(`Mapping ${index + 1} action must be key, press, or turn`);
    }
    if (["key", "press"].includes(mapping.action.type) &&
        (typeof mapping.action.key !== "string" || !mapping.action.key)) {
      throw new Error(`Mapping ${index + 1} requires a Codex key`);
    }
    if (mapping.action.type === "turn" && !["cw", "ccw"].includes(mapping.action.direction)) {
      throw new Error(`Mapping ${index + 1} turn direction must be cw or ccw`);
    }
    return structuredClone(mapping);
  });

  return {
    ...(value.serialPort == null ? {} : { serialPort: value.serialPort }),
    mappings,
  };
}

module.exports = {
  RIDE_BUTTONS,
  RideMapper,
  validateRideConfig,
};
