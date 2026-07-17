const { spawnSync } = require("node:child_process");
const fs = require("node:fs");

function listHardwarePorts({ devDirectory = "/dev", fsModule = fs } = {}) {
  try {
    return fsModule.readdirSync(devDirectory)
      .filter((name) => /^cu\.usbmodemCDXMICRO\d*$/.test(name))
      .sort()
      .map((name) => `${devDirectory}/${name}`);
  } catch (error) {
    if (error.code === "ENOENT") return [];
    throw error;
  }
}

function resolveHardwarePort(configuredPort, options) {
  if (configuredPort) {
    if (!fs.existsSync(configuredPort)) {
      throw new Error(`Codex Micro serial port does not exist: ${configuredPort}`);
    }
    return configuredPort;
  }

  const ports = listHardwarePorts(options);
  if (ports.length === 0) {
    throw new Error("No physical Codex Micro Bridge found. Connect the flashed Leonardo.");
  }
  if (ports.length > 1) {
    throw new Error(`More than one physical bridge found; set serialPort to one of: ${ports.join(", ")}`);
  }
  return ports[0];
}

function encodeHardwareCommand(command) {
  switch (command?.type) {
    case "hid":
      return encodeHid(command.key, command.act, command.agent);
    case "joystick":
      requireFinite(command.angle, "joystick angle");
      requireFinite(command.distance, "joystick distance");
      return `RAD ${command.angle} ${command.distance}\n`;
    default:
      throw new Error(`Hardware transport does not support command type: ${command?.type}`);
  }
}

function encodeHid(key, act, agent) {
  if (typeof key !== "string" || !/^[A-Z0-9_]+$/.test(key)) {
    throw new Error("Hardware HID key must contain only A-Z, 0-9, or underscore");
  }
  if (![0, 1, 2].includes(act)) {
    throw new Error("Hardware HID act must be 0, 1, or 2");
  }
  if (agent != null && (!Number.isInteger(agent) || agent < 0)) {
    throw new Error("Hardware HID agent must be a non-negative integer");
  }
  return `HID ${key} ${act}${agent == null ? "" : ` ${agent}`}\n`;
}

class HardwareTransport {
  constructor({ port, fsModule = fs, run = spawnSync, sleep = delay } = {}) {
    this.port = resolveHardwarePort(port);
    this.fs = fsModule;
    this.run = run;
    this.sleep = sleep;
    this.fd = null;
  }

  open() {
    if (this.fd != null) return this;
    const flag = process.platform === "darwin" ? "-f" : "-F";
    const configured = this.run("stty", [flag, this.port, "115200", "raw", "-echo"], {
      encoding: "utf8",
    });
    if (configured.error || configured.status !== 0) {
      throw new Error(
        `Could not configure ${this.port}: ${configured.error?.message || configured.stderr?.trim() || "stty failed"}`,
      );
    }
    const flags = this.fs.constants.O_WRONLY | (this.fs.constants.O_NOCTTY ?? 0);
    this.fd = this.fs.openSync(this.port, flags);
    return this;
  }

  async send(command) {
    if (this.fd == null) throw new Error("Hardware transport is not open");
    if (command?.type === "press") {
      const durationMs = Number.isFinite(command.durationMs) ? command.durationMs : 60;
      this.#write(encodeHid(command.key, 1, command.agent));
      await this.sleep(Math.max(1, durationMs));
      this.#write(encodeHid(command.key, 0, command.agent));
      return;
    }
    this.#write(encodeHardwareCommand(command));
  }

  close() {
    if (this.fd == null) return;
    this.fs.closeSync(this.fd);
    this.fd = null;
  }

  #write(line) {
    this.fs.writeSync(this.fd, line, null, "utf8");
  }
}

function requireFinite(value, name) {
  if (!Number.isFinite(value)) throw new Error(`${name} must be finite`);
}

function delay(milliseconds) {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}

module.exports = {
  HardwareTransport,
  encodeHardwareCommand,
  encodeHid,
  listHardwarePorts,
  resolveHardwarePort,
};
