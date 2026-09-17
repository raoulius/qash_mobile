// PrinterEAChannel.swift
//
// Native iOS half of the thermal-printer bridge. Talks to an MFi Bluetooth
// Classic printer (e.g. RPP02N) over Apple's ExternalAccessory framework,
// which is the ONLY sanctioned path for Classic/SPP on iOS. The Dart side
// (bluetooth_service.dart, _ios* methods) calls this over MethodChannel
// "qash/printer_ea".
//
// The accessory must already be paired in iOS Settings > Bluetooth — EA has
// no programmatic pairing or live scan.
//
// Methods:
//   listAccessories        -> [{name, protocols:[..], address}]  (discovery; also how
//                             you find the MFi protocol string during the spike)
//   scan(protocolString?)  -> [{name, address}] matching our protocol
//   connect(address)       -> opens an EASession output stream
//   print(bytes)           -> writes ESC/POS bytes, respecting stream backpressure
//   disconnect

import Foundation
import ExternalAccessory
import Flutter

final class PrinterEAChannel: NSObject, StreamDelegate {
  static let channelName = "qash/printer_ea"

  private let channel: FlutterMethodChannel
  private var session: EASession?

  // Write-drain state: bytes still waiting for stream space, and the pending
  // Flutter result to resolve once the whole payload is written (or errors).
  private var writeBuffer = Data()
  private var writeResult: FlutterResult?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: PrinterEAChannel.channelName, binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call, result)
    }
  }

  private func handle(_ call: FlutterMethodCall, _ result: @escaping FlutterResult) {
    switch call.method {
    case "listAccessories":
      result(listAccessories())
    case "scan":
      let proto = (call.arguments as? [String: Any])?["protocolString"] as? String
      result(scan(protocolString: proto))
    case "connect":
      guard let args = call.arguments as? [String: Any],
            let address = args["address"] as? String,
            let proto = args["protocolString"] as? String else {
        result(FlutterError(code: "bad_args", message: "connect requires address + protocolString", details: nil))
        return
      }
      connect(address: address, protocolString: proto, result: result)
    case "print":
      guard let args = call.arguments as? [String: Any],
            let data = args["bytes"] as? FlutterStandardTypedData else {
        result(FlutterError(code: "bad_args", message: "print requires bytes", details: nil))
        return
      }
      write(bytes: data.data, result: result)
    case "disconnect":
      disconnect()
      result(nil)
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  // MARK: - Discovery

  private func listAccessories() -> [[String: Any]] {
    EAAccessoryManager.shared().connectedAccessories.map { acc in
      ["name": acc.name,
       "protocols": acc.protocolStrings,
       "address": String(acc.connectionID)]
    }
  }

  private func scan(protocolString: String?) -> [[String: Any]] {
    let accessories = EAAccessoryManager.shared().connectedAccessories
    let matches = protocolString.map { proto in
      accessories.filter { $0.protocolStrings.contains(proto) }
    } ?? accessories
    return matches.map { ["name": $0.name, "address": String($0.connectionID)] }
  }

  private func accessory(for address: String) -> EAAccessory? {
    EAAccessoryManager.shared().connectedAccessories.first {
      String($0.connectionID) == address
    }
  }

  // MARK: - Session

  private func connect(address: String, protocolString: String, result: @escaping FlutterResult) {
    disconnect()
    guard let acc = accessory(for: address),
          let newSession = EASession(accessory: acc, forProtocol: protocolString),
          let out = newSession.outputStream else {
      result(FlutterError(code: "connect_failed",
                          message: "No EASession for address \(address) / protocol \(protocolString)",
                          details: nil))
      return
    }
    session = newSession
    out.delegate = self
    out.schedule(in: .main, forMode: .default)
    out.open()
    result(nil)
  }

  private func disconnect() {
    if let out = session?.outputStream {
      out.close()
      out.remove(from: .main, forMode: .default)
      out.delegate = nil
    }
    session = nil
    // Fail any print left in flight so the Dart Future doesn't hang forever.
    if let pending = writeResult {
      pending(FlutterError(code: "disconnected", message: "Disconnected mid-print", details: nil))
    }
    writeBuffer.removeAll()
    writeResult = nil
  }

  // MARK: - Write with backpressure

  private func write(bytes: Data, result: @escaping FlutterResult) {
    guard session?.outputStream != nil else {
      result(FlutterError(code: "not_connected", message: "No printer connected", details: nil))
      return
    }
    if writeResult != nil {
      result(FlutterError(code: "busy", message: "A print is already in progress", details: nil))
      return
    }
    writeBuffer = bytes
    writeResult = result
    drain()
  }

  // Push as much of writeBuffer as the stream will take right now. The rest
  // goes out on the next .hasSpaceAvailable event. Resolves writeResult when
  // the buffer empties.
  private func drain() {
    guard let out = session?.outputStream else { return }
    while !writeBuffer.isEmpty && out.hasSpaceAvailable {
      let written = writeBuffer.withUnsafeBytes { raw -> Int in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
        return out.write(base, maxLength: writeBuffer.count)
      }
      if written <= 0 {
        finishWrite(FlutterError(code: "write_failed", message: "outputStream.write returned \(written)", details: nil))
        return
      }
      writeBuffer.removeFirst(written)
    }
    if writeBuffer.isEmpty {
      finishWrite(nil)
    }
  }

  private func finishWrite(_ resultValue: Any?) {
    writeResult?(resultValue)
    writeResult = nil
    writeBuffer.removeAll()
  }

  // MARK: - StreamDelegate

  func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
    switch eventCode {
    case .hasSpaceAvailable:
      drain()
    case .errorOccurred:
      finishWrite(FlutterError(code: "stream_error", message: "Output stream error", details: nil))
    default:
      break
    }
  }
}
