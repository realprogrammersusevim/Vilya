//
//  BLEManager.swift
//  Vilya
//
//  Created by Jonathan Milligan on 1/29/25.
//

import Combine // Needed for ObservableObject
import CoreBluetooth
import Foundation

// MARK: - Constants and UUIDs

let UART_SERVICE_UUID_STRING = "6E40FFF0-B5A3-F393-E0A9-E50E24DCCA9E"
let UART_RX_CHAR_UUID_STRING = "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"
let UART_TX_CHAR_UUID_STRING = "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"
let DEVICE_INFO_SERVICE_UUID_STRING = "0000180A-0000-1000-8000-00805F9B34FB"
let DEVICE_HW_VERSION_CHAR_UUID_STRING = "00002A27-0000-1000-8000-00805F9B34FB"
let DEVICE_FW_VERSION_CHAR_UUID_STRING = "00002A26-0000-1000-8000-00805F9B34FB"

let UART_SERVICE_UUID = CBUUID(string: UART_SERVICE_UUID_STRING)
let UART_RX_CHAR_UUID = CBUUID(string: UART_RX_CHAR_UUID_STRING)
let UART_TX_CHAR_UUID = CBUUID(string: UART_TX_CHAR_UUID_STRING)
let DEVICE_INFO_SERVICE_UUID = CBUUID(string: DEVICE_INFO_SERVICE_UUID_STRING)
let DEVICE_HW_VERSION_CHAR_UUID = CBUUID(string: DEVICE_HW_VERSION_CHAR_UUID_STRING)
let DEVICE_FW_VERSION_CHAR_UUID = CBUUID(string: DEVICE_FW_VERSION_CHAR_UUID_STRING)

let DEVICE_NAME_PREFIXES = [
    "R01", "R02", "R03", "R04", "R05", "R06", "R07", "R10",
    "COLMI", "VK-5098", "MERLIN", "Hello Ring", "RING1", "boAtring",
    "TR-R02", "SE", "EVOLVEO", "GL-SR2", "Blaupunkt", "KSIX RING",
]

// MARK: - UserDefaults Keys

let lastConnectedPeripheralNameKey = "lastConnectedPeripheralNameKey"
let lastConnectedPeripheralIdentifierKey = "lastConnectedPeripheralIdentifierKey"

// MARK: - Enums and Structs (Based on Python dataclasses and enums)

enum RealTimeReading: UInt8, CaseIterable {
    case heartRate = 1
    case bloodPressure = 2
    case spo2 = 3
    case fatigue = 4
    case healthCheck = 5
    case ecg = 7
    case pressure = 8
    case bloodSugar = 9
    case hrv = 10

    static let realTimeMapping: [String: RealTimeReading] = [
        "heart-rate": .heartRate,
        "blood-pressure": .bloodPressure,
        "spo2": .spo2,
        "fatigue": .fatigue,
        "health-check": .healthCheck,
        "ecg": .ecg,
        "pressure": .pressure,
        "blood-sugar": .bloodSugar,
        "hrv": .hrv,
    ]
}

enum Action: UInt8 {
    case start = 1
    case pause = 2
    case `continue` = 3
    case stop = 4
}

struct Reading {
    let kind: RealTimeReading
    let value: Int
}

struct ReadingError {
    let kind: RealTimeReading
    let code: Int
}

struct BatteryInfo {
    let batteryLevel: Int
    let charging: Bool
}

struct HeartRateLogSettings {
    let enabled: Bool
    let interval: Int // Interval in minutes
}

struct SportDetail {
    let year: Int
    let month: Int
    let day: Int
    let timeIndex: Int // time_index represents 15 minutes intervals within a day
    let calories: Int
    let steps: Int
    let distance: Int // Distance in meters

    var timestamp: Date {
        var dateComponents = DateComponents()
        dateComponents.year = year
        dateComponents.month = month
        dateComponents.day = day
        dateComponents.hour = timeIndex / 4
        dateComponents.minute = (timeIndex % 4) * 15
        dateComponents.timeZone = TimeZone(identifier: "UTC")

        let calendar = Calendar(identifier: .gregorian)
        return calendar.date(from: dateComponents)!
    }
}

struct HeartRateLog {
    let heartRates: [Int]
    let timestamp: Date
    let size: Int
    let index: Int
    let range: Int

    func heartRatesWithTimes() -> [(Int, Date)] {
        addTimes(heartRates: heartRates, ts: timestamp)
    }
}

// MARK: - Custom Error Type

enum BLEManagerError: Error, LocalizedError {
    case bluetoothNotPoweredOn
    case connectionTimeout(String)
    case invalidDeviceAddress(String)
    case peripheralNotFound(String)
    case notConnected
    case serviceNotFound(CBUUID)
    case characteristicNotFound(CBUUID, CBUUID) // characteristicUUID, serviceUUID
    case failedToParseData(String)
    case operationInProgress(String)
    case deviceReportedError(String)
    case connectionCancelled
    case failedToConnect(Error?)
    case unexpectedDisconnect(Error?)
    case serviceDiscoveryFailed(Error)
    case characteristicDiscoveryFailed(Error)
    case notificationUpdateFailed(Error)
    case sendPacketFailed(Error?)
    case noDataAvailable
    case unknown(Error?)

    var errorDescription: String? {
        switch self {
        case .bluetoothNotPoweredOn: "Bluetooth is not powered on."
        case let .connectionTimeout(message): "Connection timed out: \(message)"
        case let .invalidDeviceAddress(address): "Invalid device address: \(address)."
        case let .peripheralNotFound(identifier): "Peripheral not found with identifier: \(identifier)."
        case .notConnected: "Not connected to a peripheral."
        case let .serviceNotFound(uuid): "Service \(uuid.uuidString) not found."
        case let .characteristicNotFound(charUUID, serviceUUID): "Characteristic \(charUUID.uuidString) not found in service \(serviceUUID.uuidString)."
        case let .failedToParseData(dataType): "Failed to parse \(dataType) data."
        case let .operationInProgress(operation): "\(operation) is already in progress."
        case let .deviceReportedError(message): "Device reported an error: \(message)."
        case .connectionCancelled: "Connection cancelled or peripheral disconnected."
        case let .failedToConnect(underlyingError): "Failed to connect to peripheral. \(underlyingError?.localizedDescription ?? "")"
        case let .unexpectedDisconnect(underlyingError): "Unexpected peripheral disconnection. \(underlyingError?.localizedDescription ?? "")"
        case let .serviceDiscoveryFailed(error): "Error discovering services: \(error.localizedDescription)."
        case let .characteristicDiscoveryFailed(error): "Error discovering characteristics: \(error.localizedDescription)."
        case let .notificationUpdateFailed(error): "Error updating notification state: \(error.localizedDescription)."
        case let .sendPacketFailed(error): "Failed to send packet. \(error?.localizedDescription ?? "")"
        case .noDataAvailable: "No data available from the device for this request."
        case let .unknown(error): "An unknown error occurred. \(error?.localizedDescription ?? "")"
        }
    }
}

// MARK: - Packet Handling Functions (Based on packet.py)

// MARK: - Utility Functions (Based on date_utils.py, set_time.py, steps.py)

func byteToBCD(_ byte: Int) -> UInt8 {
    assert(byte < 100 && byte >= 0)
    let tens = byte / 10
    let ones = byte % 10
    return UInt8((tens << 4) | ones)
}

func bcdToDecimal(_ bcd: UInt8) -> Int {
    (((Int(bcd) >> 4) & 15) * 10) + (Int(bcd) & 15)
}

func now() -> Date {
    Date() // Swift Date is already timezone-agnostic in many contexts, adjust if needed for UTC specifically
}

func makePacket(command: UInt8, subData: [UInt8]? = nil) -> Data {
    var packet = Data(count: 16)
    packet[0] = command

    if let subData {
        assert(subData.count <= 14, "Sub data must be less than or equal to 14 bytes")
        for i in 0 ..< subData.count {
            packet[i + 1] = subData[i]
        }
    }
    packet[15] = checksum(packet: packet)
    return packet
}

func checksum(packet: Data) -> UInt8 {
    var sum: UInt32 = 0
    for byte in packet {
        sum += UInt32(byte)
    }
    return UInt8(sum & 255)
}

func datesBetween(start: Date, end: Date) -> [Date] {
    var dates: [Date] = []
    var currentDate = start
    let calendar = Calendar.current

    while currentDate <= end {
        dates.append(currentDate)
        currentDate = calendar.date(byAdding: .day, value: 1, to: currentDate)!
    }
    return dates
}

func setTimePacket(target: Date) -> Data {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")! // Ensure UTC timezone
    let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)

    var data = Data(count: 7)
    data[0] = byteToBCD(components.year! % 2000)
    data[1] = byteToBCD(components.month!)
    data[2] = byteToBCD(components.day!)
    data[3] = byteToBCD(components.hour!)
    data[4] = byteToBCD(components.minute!)
    data[5] = byteToBCD(components.second!)
    data[6] = 1 // Set language to English, 0 is Chinese

    return makePacket(command: 0x01, subData: [UInt8](data)) // CMD_SET_TIME = 1
}

func readHeartRatePacket(target: Date) -> Data {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let startOfDay = calendar.startOfDay(for: target)
    let timestamp = startOfDay.timeIntervalSince1970
    var data = Data()
    var timestampValue = Int32(timestamp)
    data.append(Data(bytes: &timestampValue, count: 4))

    return makePacket(command: 0x15, subData: [UInt8](data)) // CMD_READ_HEART_RATE = 21 (0x15)
}

func readStepsPacket(dayOffset: Int = 0) -> Data {
    var subData: [UInt8] = [0x00, 0x0F, 0x00, 0x5F, 0x01]
    subData[0] = UInt8(dayOffset)
    return makePacket(command: 0x43, subData: subData) // CMD_GET_STEP_SOMEDAY = 67 (0x43)
}

func blinkTwicePacket() -> Data {
    makePacket(command: 0x10) // CMD_BLINK_TWICE = 16 (0x10)
}

func rebootPacket() -> Data {
    makePacket(command: 0x08, subData: [0x01]) // CMD_REBOOT = 8 (0x08)
}

func hrLogSettingsPacket(settings: HeartRateLogSettings) -> Data {
    assert(settings.interval > 0 && settings.interval < 256, "Interval must be between 1 and 255")
    let enabled: UInt8 = settings.enabled ? 1 : 2
    let subData: [UInt8] = [2, enabled, UInt8(settings.interval)]
    return makePacket(command: 0x16, subData: subData) // CMD_HEART_RATE_LOG_SETTINGS = 22 (0x16)
}

func readHeartRateLogSettingsPacket() -> Data {
    makePacket(command: 0x16, subData: [0x01]) // CMD_HEART_RATE_LOG_SETTINGS = 22 (0x16)
}

func getStartPacket(readingType: RealTimeReading) -> Data {
    makePacket(command: 105, subData: [readingType.rawValue, Action.start.rawValue]) // CMD_START_REAL_TIME = 105
}

func getStopPacket(readingType: RealTimeReading) -> Data {
    makePacket(command: 106, subData: [readingType.rawValue, Action.stop.rawValue, 0]) // CMD_STOP_REAL_TIME = 106
}

func addTimes(heartRates: [Int], ts: Date) -> [(Int, Date)] {
    // If there are no heart rates (e.g., an empty log for the day), return an empty array.
    if heartRates.isEmpty {
        return []
    }
    var result: [(Int, Date)] = []
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    var m = calendar.startOfDay(for: ts) // Start of the day in UTC
    let fiveMin = TimeInterval.minutes(5)

    for hr in heartRates {
        result.append((hr, m))
        m = m.addingTimeInterval(fiveMin)
    }
    return result
}

extension TimeInterval {
    static func minutes(_ value: Int) -> TimeInterval {
        TimeInterval(value * 60)
    }
}

// MARK: - ColmiR02Client Class (Based on client.py)

class ColmiR02Client: NSObject, ObservableObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    private var centralManager: CBCentralManager!
    @Published var connectedPeripheral: CBPeripheral?
    private var rxCharacteristic: CBCharacteristic?
    private var txCharacteristic: CBCharacteristic?

    // Store CheckedContinuation for async/await
    private var responseContinuations: [UInt8: CheckedContinuation<Data, Error>] = [:]
    private var heartRateLogParser = HeartRateLogParser()
    private var heartRateLogContinuation: CheckedContinuation<HeartRateLog, Error>?

    private var connectionContinuation: CheckedContinuation<Void, Error>?
    private var sportDetailParser = SportDetailParser()
    private var sportDetailContinuation: CheckedContinuation<[SportDetail], Error>?
    private var characteristicReadContinuations: [CBUUID: CheckedContinuation<Data, Error>] = [:]

    @Published var isScanning: Bool = false
    @Published var discoveredPeripherals: [CBPeripheral] = []
    @Published var receivedData: String = ""

    var isConnected: Bool {
        connectedPeripheral?.state == .connected
    }

    var address: String

    init(address: String) {
        self.address = address
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    deinit {
        disconnect()
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else {
            print("Bluetooth is not powered on")
            return
        }

        centralManager.scanForPeripherals(withServices: nil, options: nil)
        print("Scanning for peripherals...")
        isScanning = true
        discoveredPeripherals.removeAll()
    }

    func connect(peripheral: CBPeripheral) {
        if centralManager.isScanning {
            centralManager.stopScan()
            isScanning = false
        }
        centralManager.connect(peripheral, options: nil)
    }

    func disconnect() {
        if let peripheral = connectedPeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
            print("Disconnected from peripheral")
        }
        // connectedPeripheral will be set to nil in didDisconnectPeripheral delegate method
        rxCharacteristic = nil
        txCharacteristic = nil
        failAllPendingContinuations(with: BLEManagerError.connectionCancelled)
    }

    func reconnectToLastDevice() {
        guard centralManager.state == .poweredOn else {
            print("Bluetooth is not powered on. Cannot reconnect.")
            return
        }

        guard connectedPeripheral == nil else {
            print("Already connected or a connection attempt is in progress.")
            return
        }

        guard !address.isEmpty, let peripheralUUID = UUID(uuidString: address) else {
            print("No valid last device address available for reconnection: \(address). Scan for devices.")
            return
        }

        print("Attempting to retrieve peripheral with UUID: \(peripheralUUID.uuidString)")
        let knownPeripherals = centralManager.retrievePeripherals(withIdentifiers: [peripheralUUID])

        if let peripheralToReconnect = knownPeripherals.first {
            print("Found peripheral \(peripheralToReconnect.name ?? peripheralUUID.uuidString). Attempting to connect...")
            // Hold a strong reference to the peripheral by assigning it to an instance property
            // before initiating the connection. This prevents it from being deallocated.
            connectedPeripheral = peripheralToReconnect
            // The connect method already handles stopping scan if active.
            connect(peripheral: peripheralToReconnect)
        } else {
            print("Could not retrieve peripheral with UUID \(address). The device might be out of range, not advertising, or not known to the system. Please scan for devices.")
        }
    }

    private func sendRawPacket(_ packetData: Data) throws {
        guard let peripheral = connectedPeripheral, let rxChar = rxCharacteristic else {
            throw BLEManagerError.notConnected
        }
        peripheral.writeValue(packetData, for: rxChar, type: .withoutResponse)
        print("Sent packet: \(packetData.hexEncodedString())")
    }

    private func sendCommandAndWaitForResponse(command: UInt8, subData: [UInt8]? = nil) async throws -> Data {
        let packet = makePacket(command: command, subData: subData)
        return try await withCheckedThrowingContinuation { continuation in
            guard connectedPeripheral != nil, rxCharacteristic != nil else {
                continuation.resume(throwing: BLEManagerError.notConnected)
                return
            }
            responseContinuations[command] = continuation
            do {
                try sendRawPacket(packet)
            } catch {
                responseContinuations.removeValue(forKey: command)
                continuation.resume(throwing: BLEManagerError.sendPacketFailed(error))
            }
        }
    }

    func connectAndPrepare() async throws {
        // Wait for Bluetooth to be powered on if it's not already
        if centralManager.state != .poweredOn {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let waitForPowerOn = Task {
                    // Wait for up to 5 seconds for Bluetooth to power on
                    for _ in 0 ..< 50 {
                        if centralManager.state == .poweredOn {
                            continuation.resume()
                            return
                        }
                        try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
                    }
                    continuation.resume(throwing: BLEManagerError.connectionTimeout("Bluetooth did not power on"))
                }

                // If the task is cancelled, clean up
                Task {
                    try await waitForPowerOn.value
                }
            }
        }

        if isConnected, rxCharacteristic != nil, txCharacteristic != nil {
            return // Already ready
        }

        guard !address.isEmpty, let peripheralUUID = UUID(uuidString: address) else {
            throw BLEManagerError.invalidDeviceAddress(address)
        }

        return try await withCheckedThrowingContinuation { continuation in
            self.connectionContinuation = continuation

            let knownPeripherals = centralManager.retrievePeripherals(withIdentifiers: [peripheralUUID])
            if let peripheralToConnect = knownPeripherals.first {
                // Hold a strong reference if not already connected to this peripheral
                if self.connectedPeripheral?.identifier != peripheralToConnect.identifier {
                    self.connectedPeripheral = peripheralToConnect
                }
                centralManager.connect(peripheralToConnect, options: nil)
            } else {
                self.connectionContinuation = nil
                continuation.resume(throwing: BLEManagerError.peripheralNotFound(peripheralUUID.uuidString))
            }
        }
    }

    // MARK: - Command Functions (Based on cli.py and client.py)

    private func readCharacteristicValue(characteristicUUID: CBUUID, serviceUUID: CBUUID) async throws -> Data {
        guard let peripheral = connectedPeripheral else {
            throw BLEManagerError.notConnected
        }
        guard let service = peripheral.services?.first(where: { $0.uuid == serviceUUID }) else {
            throw BLEManagerError.serviceNotFound(serviceUUID)
        }
        guard let characteristic = service.characteristics?.first(where: { $0.uuid == characteristicUUID }) else {
            throw BLEManagerError.characteristicNotFound(characteristicUUID, serviceUUID)
        }

        return try await withCheckedThrowingContinuation { continuation in
            characteristicReadContinuations[characteristic.uuid] = continuation
            peripheral.readValue(for: characteristic)
        }
    }

    func getDeviceInfo() async throws -> [String: String] {
        guard connectedPeripheral != nil else {
            throw BLEManagerError.notConnected
        }
        // Ensure services and characteristics are discovered. This might require prior discovery.
        // Assuming discovery has happened post-connection.

        var deviceInfo: [String: String] = [:]

        let hwVersionData = try await readCharacteristicValue(characteristicUUID: DEVICE_HW_VERSION_CHAR_UUID, serviceUUID: DEVICE_INFO_SERVICE_UUID)
        deviceInfo["hw_version"] = String(data: hwVersionData, encoding: .utf8) ?? "Unknown"

        let fwVersionData = try await readCharacteristicValue(characteristicUUID: DEVICE_FW_VERSION_CHAR_UUID, serviceUUID: DEVICE_INFO_SERVICE_UUID)
        deviceInfo["fw_version"] = String(data: fwVersionData, encoding: .utf8) ?? "Unknown"

        return deviceInfo
    }

    func getBattery() async throws -> BatteryInfo {
        let responseData = try await sendCommandAndWaitForResponse(command: 0x03) // CMD_BATTERY = 3
        guard let batteryInfo = PacketParser.parseBatteryData(packet: responseData) else {
            throw BLEManagerError.failedToParseData("battery")
        }
        return batteryInfo
    }

    func setTime(target: Date) async throws {
        let subData = setTimePacketSubData(target: target) // Helper to get just subData
        _ = try await sendCommandAndWaitForResponse(command: 0x01, subData: subData) // CMD_SET_TIME = 1
        // Assuming success if no error is thrown, as the device might not send a meaningful payload for SET_TIME ack.
    }

    private func setTimePacketSubData(target: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: target)
        var data = [UInt8](repeating: 0, count: 7)
        data[0] = byteToBCD(components.year! % 2000)
        data[1] = byteToBCD(components.month!)
        data[2] = byteToBCD(components.day!)
        data[3] = byteToBCD(components.hour!)
        data[4] = byteToBCD(components.minute!)
        data[5] = byteToBCD(components.second!)
        data[6] = 1 // Set language to English
        return data
    }

    func getHeartRateLog(targetDate: Date) async throws -> HeartRateLog {
        heartRateLogParser.reset() // Reset parser before starting a new log request
        heartRateLogParser.isTodayLog = Calendar.current.isDateInToday(targetDate)
        heartRateLogParser.setTargetDateForCurrentLog(targetDate)
        heartRateLogParser.setTargetDateForCurrentLog(targetDate)

        let subData = readHeartRatePacketSubData(target: targetDate)
        let packet = makePacket(command: 0x15, subData: subData) // CMD_READ_HEART_RATE = 21

        return try await withCheckedThrowingContinuation { continuation in
            guard self.heartRateLogContinuation == nil else {
                continuation.resume(throwing: BLEManagerError.operationInProgress("Heart rate log request"))
                return
            }
            self.heartRateLogContinuation = continuation
            do {
                try sendRawPacket(packet)
            } catch {
                self.heartRateLogContinuation = nil
                continuation.resume(throwing: BLEManagerError.sendPacketFailed(error))
            }
        }
    }

    private func readHeartRatePacketSubData(target: Date) -> [UInt8] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let startOfDay = calendar.startOfDay(for: target)
        let timestamp = startOfDay.timeIntervalSince1970
        var data = Data()
        var timestampValue = Int32(timestamp)
        data.append(Data(bytes: &timestampValue, count: MemoryLayout<Int32>.size))
        return [UInt8](data)
    }

    func getHeartRateLogSettings() async throws -> HeartRateLogSettings {
        let responseData = try await sendCommandAndWaitForResponse(command: 0x16, subData: [0x01]) // CMD_HEART_RATE_LOG_SETTINGS = 22, subcmd 1 for read
        guard let settings = PacketParser.parseHeartRateLogSettingsData(packet: responseData) else {
            throw BLEManagerError.failedToParseData("heart rate log settings")
        }
        return settings
    }

    func setHeartRateLogSettings(settings: HeartRateLogSettings) async throws -> HeartRateLogSettings {
        assert(settings.interval > 0 && settings.interval < 256, "Interval must be between 1 and 255")
        let enabledByte: UInt8 = settings.enabled ? 1 : 2
        let subData: [UInt8] = [2, enabledByte, UInt8(settings.interval)] // subcmd 2 for write
        _ = try await sendCommandAndWaitForResponse(command: 0x16, subData: subData)
        // Assuming success, return the settings that were intended to be set.
        // Device might not send back the settings in response to a set command.
        return settings
    }

    func getRealtimeReading(readingType: RealTimeReading) async throws -> Reading {
        let stopPacketData = getStopPacket(readingType: readingType)

        // Send start, await data response
        let responseData = try await sendCommandAndWaitForResponse(command: 105, subData: [readingType.rawValue, Action.start.rawValue]) // CMD_START_REAL_TIME

        // Send stop (fire and forget for now)
        // The stop command (106) might not have a response we need to wait for to confirm the reading.
        // If it did, we'd await its response too.
        do {
            try sendRawPacket(stopPacketData)
        } catch {
            print("Error sending stop packet for \(readingType): \(error)")
            // Decide if this error should propagate or just be logged.
        }

        guard let reading = PacketParser.parseRealTimeReadingData(packet: responseData) else {
            throw BLEManagerError.failedToParseData("real-time reading")
        }
        return reading
    }

    func getSteps(dayOffset: Int = 0) async throws -> [SportDetail] {
        sportDetailParser.reset() // Reset parser for new steps request
        let subData: [UInt8] = [UInt8(dayOffset), 0x0F, 0x00, 0x5F, 0x01]
        let packet = makePacket(command: 0x43, subData: subData) // CMD_GET_STEP_SOMEDAY = 67

        return try await withCheckedThrowingContinuation { continuation in
            guard self.sportDetailContinuation == nil else {
                continuation.resume(throwing: BLEManagerError.operationInProgress("Get steps request"))
                return
            }
            self.sportDetailContinuation = continuation
            do {
                try sendRawPacket(packet)
            } catch {
                self.sportDetailContinuation = nil
                continuation.resume(throwing: BLEManagerError.sendPacketFailed(error))
            }
        }
    }

    func reboot() async throws {
        _ = try await sendCommandAndWaitForResponse(command: 0x08, subData: [0x01]) // CMD_REBOOT = 8
    }

    func blinkTwice() async throws {
        _ = try await sendCommandAndWaitForResponse(command: 0x10) // CMD_BLINK_TWICE = 16
    }

    func rawCommand(commandCode: UInt8, subData: [UInt8]?) async throws -> Data {
        try await sendCommandAndWaitForResponse(command: commandCode, subData: subData)
    }

    private func failAllPendingContinuations(with error: Error) {
        // Connection continuation
        if let cont = connectionContinuation {
            connectionContinuation = nil
            cont.resume(throwing: error)
        }

        // Command response continuations
        let commandContinuationsToFail = responseContinuations
        responseContinuations.removeAll() // Clear before resuming to prevent re-entry issues
        for (_, cont) in commandContinuationsToFail {
            cont.resume(throwing: error)
        }

        // Heart rate log continuation
        if let cont = heartRateLogContinuation {
            heartRateLogContinuation = nil
            cont.resume(throwing: error)
        }

        // Sport detail continuation
        if let cont = sportDetailContinuation {
            sportDetailContinuation = nil
            cont.resume(throwing: error)
        }

        // Characteristic read continuations
        let charReadContinuationsToFail = characteristicReadContinuations
        characteristicReadContinuations.removeAll() // Clear before resuming
        for (_, cont) in charReadContinuationsToFail {
            cont.resume(throwing: error)
        }
    }

    // MARK: - CBCentralManagerDelegate

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn {
            print("Bluetooth powered on")
        } else {
            print("Bluetooth not powered on")
            // Handle Bluetooth being off or unauthorized
        }
    }

    func centralManager(_: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData _: [String: Any], rssi _: NSNumber) {
        // Add to discovered peripherals list if not already present
        if !discoveredPeripherals.contains(where: { $0.identifier == peripheral.identifier }) {
            discoveredPeripherals.append(peripheral)
            print("Discovered peripheral: \(peripheral.name ?? "N/A") \(peripheral.identifier.uuidString)")
        }
    }

    func centralManager(_: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to peripheral: \(peripheral.name ?? "N/A")")
        connectedPeripheral = peripheral
        connectedPeripheral?.delegate = self // Ensure delegate is set after connection
        isScanning = false // Stop scanning indication
        // Store the connected peripheral's information
        UserDefaults.standard.set(peripheral.name, forKey: lastConnectedPeripheralNameKey)
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: lastConnectedPeripheralIdentifierKey)
        address = peripheral.identifier.uuidString // Update client's address
        peripheral.discoverServices([UART_SERVICE_UUID, DEVICE_INFO_SERVICE_UUID])
    }

    func centralManager(_: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("Failed to connect to peripheral: \(peripheral.name ?? "N/A"), error: \(error?.localizedDescription ?? "N/A")")
        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
        }
        failAllPendingContinuations(with: BLEManagerError.failedToConnect(error))
    }

    func centralManager(_: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        let peripheralName = peripheral.name ?? "Unknown Device"
        let peripheralID = peripheral.identifier.uuidString
        print("Disconnected from peripheral: \(peripheralName) (\(peripheralID)), error: \(error?.localizedDescription ?? "N/A")")

        failAllPendingContinuations(with: BLEManagerError.unexpectedDisconnect(error))

        if connectedPeripheral?.identifier == peripheral.identifier {
            connectedPeripheral = nil
        }
        rxCharacteristic = nil
        txCharacteristic = nil

        // Attempt to reconnect if it was an unexpected disconnection from the target peripheral
        if error != nil, peripheral.identifier.uuidString == address {
            print("Unexpected disconnection from \(peripheralName). Attempting to reconnect...")
            // Re-assign to self.connectedPeripheral to maintain a strong reference to the peripheral
            // during the connection attempt, as required by Core Bluetooth.
            connectedPeripheral = peripheral
            centralManager.connect(peripheral, options: nil)
        }
    }

    // MARK: - CBPeripheralDelegate

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        if let error {
            print("Error discovering services: \(error.localizedDescription)")
            // If service discovery fails, the connection process might be stalled.
            failAllPendingContinuations(with: BLEManagerError.serviceDiscoveryFailed(error))
            return
        }

        guard let services = peripheral.services else { return }
        for service in services {
            if service.uuid == UART_SERVICE_UUID {
                peripheral.discoverCharacteristics([UART_RX_CHAR_UUID, UART_TX_CHAR_UUID], for: service)
            } else if service.uuid == DEVICE_INFO_SERVICE_UUID { // Ensure we discover characteristics for Device Info service
                peripheral.discoverCharacteristics([DEVICE_HW_VERSION_CHAR_UUID, DEVICE_FW_VERSION_CHAR_UUID], for: service)
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        if let error {
            print("Error discovering characteristics: \(error.localizedDescription)")
            // If characteristic discovery fails, the connection process might be stalled.
            failAllPendingContinuations(with: BLEManagerError.characteristicDiscoveryFailed(error))
            return
        }

        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == UART_RX_CHAR_UUID {
                rxCharacteristic = characteristic
                print("RX Characteristic found")
            } else if characteristic.uuid == UART_TX_CHAR_UUID {
                txCharacteristic = characteristic
                peripheral.setNotifyValue(true, for: characteristic)
                print("TX Characteristic found and set to notify")
            }
            // Inside the loop, after finding both RX and TX for UART_SERVICE_UUID
            if service.uuid == UART_SERVICE_UUID, rxCharacteristic != nil, txCharacteristic != nil {
                connectionContinuation?.resume(returning: ())
                connectionContinuation = nil
            }
        }
    }

    func peripheral(_: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("Error updating value for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            // If this error is on the TX characteristic (main response channel), fail all pending command continuations.
            if characteristic.uuid == txCharacteristic?.uuid {
                failAllPendingContinuations(with: BLEManagerError.unknown(error)) // Or a more specific error if identifiable
            } else {
                // If it's for a specific characteristic read, fail that one.
                if let charReadContinuation = characteristicReadContinuations.removeValue(forKey: characteristic.uuid) {
                    charReadContinuation.resume(throwing: error)
                }
            }
            return
        }

        guard let value = characteristic.value else {
            print("Characteristic \(characteristic.uuid) value is nil")
            return
        }

        print("Received data from TX characteristic: \(value.hexEncodedString())")
        receivedData = value.hexEncodedString() // Update published property

        // 1. Handle characteristic read continuations
        if let charReadContinuation = characteristicReadContinuations.removeValue(forKey: characteristic.uuid) {
            charReadContinuation.resume(returning: value)
            return
        }

        let packetType = value[0]

        // 2. Handle command-specific multi-packet logic or special single-packet logic

        if packetType == 105 { // CMD_START_REAL_TIME (105) - specific ACK then data handling
            if let continuation = responseContinuations[packetType] { // Check if continuation exists
                if let reading = PacketParser.parseRealTimeReadingData(packet: value) {
                    if reading.value != 0 { // We got a non-zero value, this is likely the actual data
                        responseContinuations.removeValue(forKey: packetType) // Remove before resuming
                        continuation.resume(returning: value)
                    } else {
                        // Value is 0, and errorCode was 0 (checked by parseRealTimeReadingData).
                        // This is likely an ACK. Wait for the next packet with actual data.
                        print("Received ACK for real-time reading \(reading.kind), value: 0. Waiting for data packet.")
                        // Do NOT resume, do NOT remove continuation.
                    }
                } else { // parseRealTimeReadingData returned nil (e.g., error code in packet or malformed)
                    responseContinuations.removeValue(forKey: packetType) // Remove before resuming
                    continuation.resume(throwing: BLEManagerError.failedToParseData("real-time reading or device error"))
                }
            } else {
                // No continuation, but we received a type 105 packet.
                // This could be an unsolicited update after the first data packet was processed.
                print("Received unsolicited real-time data (type 105) or continuation already handled: \(value.hexEncodedString())")
            }
        } else if packetType == 21, let hrContinuation = heartRateLogContinuation { // CMD_READ_HEART_RATE (multi-packet)
            let parsedLog = heartRateLogParser.parse(packet: value)
            if let log = parsedLog { // If parse returns a log (empty or full), it's complete.
                heartRateLogContinuation = nil // Clear before resuming
                hrContinuation.resume(returning: log)
                // The parser resets itself internally when it returns a complete log.
            } else {
                // parsedLog is nil. This means the parser is waiting for more packets.
                // It hasn't encountered an error that would make it return nil AND complete.
                // It hasn't completed a log (full or empty yet).
                print("HeartRateLogParser processed packet, waiting for more.")
            }
        } else if packetType == 67, let stepsContinuation = sportDetailContinuation { // CMD_GET_STEP_SOMEDAY (multi-packet)
            // ... (existing sport detail logic remains the same)
            let originalIndexIsZero = sportDetailParser.index == 0 // Check before parse resets index on NoData
            let parsedDetails = sportDetailParser.parse(packet: value)

            if let details = parsedDetails {
                sportDetailContinuation = nil // Clear before resuming
                stepsContinuation.resume(returning: details)
            } else {
                // parsedDetails is nil. Check if it was a "NoData" scenario.
                // packet[1] == 255 is the NoData indicator from device for command 67.
                if originalIndexIsZero, value.count > 1, value[1] == 255 {
                    sportDetailContinuation = nil // Clear before resuming
                    stepsContinuation.resume(throwing: BLEManagerError.noDataAvailable)
                } else {
                    // Not NoData, and not complete. Parser is accumulating.
                    print("SportDetailParser processed packet, waiting for more.")
                }
            }
            // 3. Handle general single-packet command/response continuations
        } else if let continuation = responseContinuations.removeValue(forKey: packetType) {
            continuation.resume(returning: value)
            // 4. Unhandled data
        } else {
            print("No continuation found for packet type \(packetType). Data: \(value.hexEncodedString())")
            // This could also be an unsolicited notification from the device.
        }
    }

    func peripheral(_: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let error {
            print("Error updating notification state for characteristic \(characteristic.uuid): \(error.localizedDescription)")
            failAllPendingContinuations(with: BLEManagerError.notificationUpdateFailed(error))
            // Consider if failAllPendingContinuations is needed here if characteristic.uuid == txCharacteristic?.uuid
            return
        }

        if characteristic.isNotifying {
            print("Started notification for characteristic \(characteristic.uuid)")
        } else {
            print("Stopped notification for characteristic \(characteristic.uuid)")
            // Optionally handle notification stopping
        }
    }
}

// MARK: - Extensions and Helper functions

extension Data {
    struct HexEncodingOptions: OptionSet {
        let rawValue: Int
        static let upperCase = HexEncodingOptions(rawValue: 1 << 0)
    }

    func hexEncodedString(options: HexEncodingOptions = []) -> String {
        let format = options.contains(.upperCase) ? "%02X" : "%02x"
        return map { String(format: format, $0) }.joined()
    }
}
