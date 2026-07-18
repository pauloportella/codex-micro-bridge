#!/usr/bin/env swift

import Foundation
import IOKit.hid

private let vendorID = 0x303A
private let productID = 0x8360
private let usagePage = 0xFF00
private let reportID: CFIndex = 6
private let reportBytes = 64
private let payloadBytes = 61

private func usage() -> Never {
  fputs(
    "Usage: swift tools/m5-ride-control.swift scan [seconds]|status|stop|mute|unmute\n",
    stderr
  )
  exit(64)
}

private let arguments = Array(CommandLine.arguments.dropFirst())
private let rpc: String
switch arguments.first {
case "scan":
  let seconds = arguments.count > 1 ? Int(arguments[1]) : 60
  guard let seconds, (1...300).contains(seconds), arguments.count <= 2 else { usage() }
  rpc = #"{"method":"v.m5.ride","params":{"command":"scan","seconds":\#(seconds)}}"#
case "status":
  guard arguments.count == 1 else { usage() }
  rpc = #"{"method":"v.m5.ride","params":{"command":"status"}}"#
case "stop":
  guard arguments.count == 1 else { usage() }
  rpc = #"{"method":"v.m5.ride","params":{"command":"stop"}}"#
case "mute", "unmute":
  guard arguments.count == 1, let command = arguments.first else { usage() }
  rpc = #"{"method":"v.m5.ride","params":{"command":"\#(command)"}}"#
default:
  usage()
}

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matching: [String: Any] = [
  kIOHIDVendorIDKey as String: vendorID,
  kIOHIDProductIDKey as String: productID,
  kIOHIDPrimaryUsagePageKey as String: usagePage,
]
IOHIDManagerSetDeviceMatching(manager, matching as CFDictionary)

let managerResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
guard managerResult == kIOReturnSuccess else {
  fputs("Could not open the macOS HID manager: \(managerResult)\n", stderr)
  exit(1)
}

guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>,
  let device = devices.first
else {
  fputs("Codex M5 is not connected as HID device 303A:8360\n", stderr)
  exit(1)
}

let openResult = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
guard openResult == kIOReturnSuccess else {
  fputs("Could not open Codex M5: \(openResult)\n", stderr)
  exit(1)
}

let bytes = Array(rpc.utf8)
for offset in stride(from: 0, to: bytes.count, by: payloadBytes) {
  let chunkSize = min(payloadBytes, bytes.count - offset)
  var report = [UInt8](repeating: 0, count: reportBytes)
  report[0] = UInt8(reportID)
  report[1] = 2
  report[2] = UInt8(chunkSize)
  report.replaceSubrange(3..<(3 + chunkSize), with: bytes[offset..<(offset + chunkSize)])

  let result = report.withUnsafeBytes { rawBuffer in
    IOHIDDeviceSetReport(
      device,
      kIOHIDReportTypeOutput,
      reportID,
      rawBuffer.bindMemory(to: UInt8.self).baseAddress!,
      report.count
    )
  }
  guard result == kIOReturnSuccess else {
    fputs("Could not send command to Codex M5: \(result)\n", stderr)
    exit(1)
  }
}

IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
print("Sent to Codex M5: \(rpc)")
