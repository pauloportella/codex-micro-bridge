const ALLOWED_MESSAGES = new Set(["note", "cc"]);
const ALLOWED_ACTIONS = new Set(["key", "press", "turn", "dial"]);

class MidiMapper {
  constructor(config) {
    this.config = validateMidiConfig(config);
    this.active = new Map();
  }

  process(event) {
    const normalized = normalizeMidiEvent(event);
    if (!normalized) return [];

    const commands = [];
    this.config.mappings.forEach((mapping, index) => {
      if (!matches(mapping, normalized)) return;
      commands.push(...this.#apply(mapping, index, normalized));
    });
    return commands;
  }

  #apply(mapping, index, event) {
    const action = mapping.action;
    const stateKey = `${index}:${event.channel}:${event.number}`;
    const previous = this.active.get(stateKey) ?? false;
    const active = event.message === "note"
      ? event.active
      : event.value >= (mapping.threshold ?? 64);

    switch (action.type) {
      case "key": {
        if (active === previous) return [];
        this.active.set(stateKey, active);
        return [{
          type: "hid",
          key: requiredKey(action),
          act: active ? 1 : 0,
          ...(action.agent == null ? {} : { agent: action.agent }),
        }];
      }
      case "press": {
        this.active.set(stateKey, active);
        if (!active || previous) return [];
        return [{
          type: "press",
          key: requiredKey(action),
          durationMs: action.durationMs ?? 60,
          ...(action.agent == null ? {} : { agent: action.agent }),
        }];
      }
      case "turn": {
        this.active.set(stateKey, active);
        if (!active || previous) return [];
        const direction = action.direction?.toLowerCase();
        if (!new Set(["cw", "ccw"]).has(direction)) {
          throw new Error("turn action direction must be cw or ccw");
        }
        return [{
          type: "hid",
          key: direction === "cw" ? "ENC_CW" : "ENC_CC",
          act: 2,
        }];
      }
      case "dial":
        if (event.message !== "cc") return [];
        return relativeDialCommands(event.value, action);
      default:
        return [];
    }
  }
}

function validateMidiConfig(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    throw new Error("MIDI config must be a JSON object");
  }
  if (!Array.isArray(value.mappings) || value.mappings.length === 0) {
    throw new Error("MIDI config needs at least one mapping");
  }

  const mappings = value.mappings.map((mapping, index) => {
    if (!mapping || typeof mapping !== "object") {
      throw new Error(`Mapping ${index + 1} must be an object`);
    }
    if (!ALLOWED_MESSAGES.has(mapping.message)) {
      throw new Error(`Mapping ${index + 1} message must be note or cc`);
    }
    if (!Number.isInteger(mapping.number) || mapping.number < 0 || mapping.number > 127) {
      throw new Error(`Mapping ${index + 1} number must be from 0 through 127`);
    }
    if (mapping.channel != null &&
        (!Number.isInteger(mapping.channel) || mapping.channel < 1 || mapping.channel > 16)) {
      throw new Error(`Mapping ${index + 1} channel must be from 1 through 16`);
    }
    if (!mapping.action || !ALLOWED_ACTIONS.has(mapping.action.type)) {
      throw new Error(`Mapping ${index + 1} has an invalid action type`);
    }
    if (["key", "press"].includes(mapping.action.type)) requiredKey(mapping.action);
    return structuredClone(mapping);
  });

  if (value.serialPort != null &&
      (typeof value.serialPort !== "string" || value.serialPort.length === 0)) {
    throw new Error("MIDI serialPort must be a non-empty string");
  }

  return {
    deviceContains: typeof value.deviceContains === "string" ? value.deviceContains : "",
    ...(value.serialPort == null ? {} : { serialPort: value.serialPort }),
    mappings,
  };
}

function normalizeMidiEvent(event) {
  if (!event || !Number.isInteger(event.channel) || !Number.isInteger(event.number)) {
    return null;
  }
  if (event.message === "cc") {
    return { ...event, message: "cc", active: event.value >= 64 };
  }
  if (event.message === "noteOn" || event.message === "noteOff") {
    const active = event.message === "noteOn" && event.value > 0;
    return { ...event, message: "note", active };
  }
  return null;
}

function matches(mapping, event) {
  return mapping.message === event.message &&
    mapping.number === event.number &&
    (mapping.channel == null || mapping.channel === event.channel);
}

function relativeDialCommands(value, action) {
  if (!Number.isInteger(value) || value < 0 || value > 127) return [];
  const mode = action.mode ?? "twos-complement";
  let direction;
  let steps;

  if (mode === "twos-complement") {
    if (value === 0 || value === 64) return [];
    direction = value < 64 ? "cw" : "ccw";
    steps = value < 64 ? value : 128 - value;
  } else if (mode === "binary-offset") {
    if (value === 64) return [];
    direction = value > 64 ? "cw" : "ccw";
    steps = Math.abs(value - 64);
  } else {
    throw new Error(`Unsupported relative dial mode: ${mode}`);
  }

  const count = Math.min(steps, action.maxSteps ?? 16);
  const key = direction === "cw" ? "ENC_CW" : "ENC_CC";
  return Array.from({ length: count }, () => ({ type: "hid", key, act: 2 }));
}

function requiredKey(action) {
  if (typeof action.key !== "string" || action.key.length === 0) {
    throw new Error(`${action.type} action requires a key`);
  }
  return action.key;
}

module.exports = {
  MidiMapper,
  normalizeMidiEvent,
  relativeDialCommands,
  validateMidiConfig,
};
