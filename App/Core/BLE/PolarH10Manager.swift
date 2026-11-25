// Polar BLE SDK wrapper – the ONLY file in the app importing PolarBleSdk.
// Targets PolarBleSdk 8.6.0 (Swift Concurrency: async/await + AsyncThrowingStream; no RxSwift).

import Foundation
import CoreBluetooth
import PolarBleSdk
import H10Analysis

/// Callbacks delivered by `PolarH10Manager` to `AppEngine`.
/// Note: Data callbacks (`onECG`, `onACC`, `onHR`) may fire on background tasks;
/// state callbacks fire on `PolarH10Manager`'s BLE queue (caller hops to MainActor).
struct PolarH10Callbacks {
    var onConnectionStateChange: (ConnectionState) -> Void
    var onDeviceIdentified: (_ id: String, _ name: String) -> Void
    var onBatteryLevel: (Int) -> Void
    var onECG: ([ECGSample]) -> Void
    var onACC: ([ACCSample]) -> Void
    var onHR: (_ hr: Int, _ rrIntervals: [RRInterval], _ contact: Bool) -> Void
}

final class PolarH10Manager: NSObject {
    /// Seconds between Unix epoch (1970-01-01) and Polar epoch (2000-01-01).
    private static let polarEpochOffsetSeconds: Double = 946_684_800.0
    private static let restoreIdentifier = "de.jebel.h10sleep.polar-central"

    private let bleQueue = DispatchQueue(label: "de.jebel.h10sleep.ble", qos: .userInitiated)
    private var api: PolarBleApi
    private let callbacks: PolarH10Callbacks

    // Access synchronized on `bleQueue` or via `stateLock`
    private let stateLock = NSLock()
    private var currentDeviceId: String?
    private var currentDeviceName: String?
    private var isConnected: Bool = false
    private var userInitiatedDisconnect: Bool = false
    private var wantsConnection: Bool = false

    // Active streaming/scanning tasks
    private var scanTask: Task<Void, Never>?
    private var ecgTask: Task<Void, Never>?
    private var accTask: Task<Void, Never>?
    private var hrTask: Task<Void, Never>?

    // Per-stream clock offset fallback if H10 RTC is not synced to wall-clock time
    private var ecgClockOffset: Double?
    private var accClockOffset: Double?
    private var lastECGPolarSec: Double?
    private var lastACCPolarSec: Double?

    init(callbacks: PolarH10Callbacks) {
        self.callbacks = callbacks
        let features: Set<PolarBleSdkFeature> = [
            .feature_hr,
            .feature_battery_info,
            .feature_device_info,
            .feature_polar_online_streaming,
            .feature_polar_h10_exercise_recording,
            .feature_polar_device_time_setup,
            .feature_polar_file_transfer
        ]
        self.api = PolarBleApiDefaultImpl.polarImplementation(
            bleQueue,
            features: features,
            restoreIdentifier: Self.restoreIdentifier
        )
        super.init()

        api.observer = self
        api.powerStateObserver = self
        api.deviceInfoObserver = self
        api.deviceFeaturesObserver = self
        api.automaticReconnection = true
        api.polarFilter(true)
    }

    deinit {
        cancelAllTasks()
    }

    // MARK: - Public Control

    /// Checks initial Bluetooth authorization / power state and reports it.
    func reportInitialBluetoothState() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            if let blocked = self.bluetoothBlockedState() {
                self.callbacks.onConnectionStateChange(blocked)
            }
        }
    }

    /// Connect to a known Polar H10 device ID, or scan and connect to the first H10 found.
    func connect(rememberedDeviceId: String?) {
        bleQueue.async { [weak self] in
            guard let self = self else { return }

            if let blocked = self.bluetoothBlockedState() {
                self.callbacks.onConnectionStateChange(blocked)
                return
            }

            self.setFlags(wantsConnection: true, userInitiatedDisconnect: false)
            self.api.automaticReconnection = true

            if let deviceId = rememberedDeviceId, !deviceId.isEmpty {
                self.setCurrentDevice(id: deviceId, name: self.getCurrentDeviceName())
                self.callbacks.onConnectionStateChange(.connecting)
                do {
                    try self.api.connectToDevice(deviceId)
                } catch {
                    self.startScanningForH10()
                }
            } else {
                self.startScanningForH10()
            }
        }
    }

    func disconnect() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.setFlags(wantsConnection: false, userInitiatedDisconnect: true)
            self.api.automaticReconnection = false
            self.cancelAllTasks()

            if let deviceId = self.getCurrentDeviceId() {
                try? self.api.disconnectFromDevice(deviceId)
            }
            self.setConnected(false)
            self.resetClockOffsets()
            self.callbacks.onConnectionStateChange(.idle)
        }
    }

    func forgetDevice() {
        bleQueue.async { [weak self] in
            guard let self = self else { return }
            self.setFlags(wantsConnection: false, userInitiatedDisconnect: true)
            self.api.automaticReconnection = false
            self.cancelAllTasks()

            if let deviceId = self.getCurrentDeviceId() {
                try? self.api.disconnectFromDevice(deviceId)
            }
            self.setCurrentDevice(id: nil, name: nil)
            self.setConnected(false)
            self.resetClockOffsets()
            self.callbacks.onConnectionStateChange(.idle)
        }
    }

    // MARK: - H10 Offline RR Backup Recording

    /// Best-effort start of H10 internal RR recording.
    /// Clears any stale recording first because H10 stores only one exercise at a time.
    func startH10RRRecording(exerciseId: String) async -> Bool {
        guard let deviceId = getCurrentDeviceId(), getConnected() else { return false }
        guard api.isFeatureReady(deviceId, feature: .feature_polar_h10_exercise_recording) else {
            return false
        }

        do {
            let status = try await api.requestRecordingStatus(deviceId)
            if status.ongoing {
                try? await api.stopRecording(deviceId)
            }

            var existingEntries: [PolarExerciseEntry] = []
            do {
                for try await entry in api.listExercises(deviceId) {
                    existingEntries.append(entry)
                }
            } catch {
                // Ignore listing errors when no exercises exist
            }
            for entry in existingEntries {
                try? await api.removeExercise(deviceId, entry: entry)
            }

            let sanitizedId = String(exerciseId.prefix(64))
            try await api.startRecording(
                deviceId,
                exerciseId: sanitizedId,
                interval: .interval_1s,
                sampleType: .rr
            )
            return true
        } catch {
            return false
        }
    }

    /// Stops H10 internal RR recording, fetches stored RR intervals with absolute timestamps,
    /// and removes the exercise from H10 memory. Returns empty array if unavailable.
    func stopAndFetchH10RRRecording(
        expectedExerciseId: String?,
        sessionStartDate: Date
    ) async -> [RRInterval] {
        guard let deviceId = getCurrentDeviceId(), getConnected() else { return [] }
        guard api.isFeatureReady(deviceId, feature: .feature_polar_h10_exercise_recording) else {
            return []
        }

        // Stop recording if still ongoing
        if let status = try? await api.requestRecordingStatus(deviceId), status.ongoing {
            try? await api.stopRecording(deviceId)
        } else {
            try? await api.stopRecording(deviceId)
        }

        // List stored exercises
        var entries: [PolarExerciseEntry] = []
        do {
            for try await entry in api.listExercises(deviceId) {
                entries.append(entry)
            }
        } catch {
            return []
        }

        guard !entries.isEmpty else { return [] }

        let targetEntry: PolarExerciseEntry
        if let expected = expectedExerciseId,
           let matched = entries.first(where: { $0.entryId == expected }) {
            targetEntry = matched
        } else {
            targetEntry = entries[0]
        }

        do {
            let exerciseData = try await api.fetchExercise(deviceId, entry: targetEntry)
            try? await api.removeExercise(deviceId, entry: targetEntry)

            return convertExerciseToRR(
                exerciseData: exerciseData,
                entryDate: targetEntry.date,
                sessionStartDate: sessionStartDate
            )
        } catch {
            return []
        }
    }

    // MARK: - Private Scanning & Streaming

    private func startScanningForH10() {
        scanTask?.cancel()
        callbacks.onConnectionStateChange(.scanning)

        scanTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await device in self.api.searchForDevice(withNameContaining: "Polar") {
                    if Task.isCancelled { break }
                    let upperName = device.name.uppercased()
                    let isH10 = upperName.contains("H10")
                    if isH10 && device.connectable {
                        self.setCurrentDevice(id: device.deviceId, name: device.name)
                        self.callbacks.onDeviceIdentified(device.deviceId, device.name)
                        self.callbacks.onConnectionStateChange(.connecting)
                        try? self.api.connectToDevice(device.deviceId)
                        break
                    }
                }
            } catch {
                if !Task.isCancelled {
                    if let blocked = self.bluetoothBlockedState() {
                        self.callbacks.onConnectionStateChange(blocked)
                    } else {
                        self.callbacks.onConnectionStateChange(.idle)
                    }
                }
            }
        }
    }

    private func startHRStream(deviceId: String) {
        hrTask?.cancel()
        hrTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                for try await hrData in self.api.startHrStreaming(deviceId) {
                    if Task.isCancelled { break }
                    let now = Date().timeIntervalSince1970
                    for sample in hrData {
                        let hr = Int(sample.hr)
                        var intervals: [RRInterval] = []
                        if sample.rrAvailable && !sample.rrsMs.isEmpty {
                            // Distribute RR timestamps backwards from `now` so the last beat ends at `now`
                            let totalSec = sample.rrsMs.reduce(0.0) { $0 + Double($1) / 1000.0 }
                            var cursor = now - totalSec
                            intervals.reserveCapacity(sample.rrsMs.count)
                            for rrMs in sample.rrsMs where rrMs > 0 {
                                let ms = Double(rrMs)
                                cursor += ms / 1000.0
                                intervals.append(RRInterval(t: cursor, ms: ms))
                            }
                        }
                        let contact = sample.contactStatusSupported ? sample.contactStatus : true
                        self.callbacks.onHR(hr, intervals, contact)
                    }
                }
            } catch {
                // Stream terminates on disconnect; reconnect will restart it via bleSdkFeatureReady
            }
        }
    }

    private func startECGAndACCStreams(deviceId: String) {
        startECGStream(deviceId: deviceId)
        startACCStream(deviceId: deviceId)
    }

    private func startECGStream(deviceId: String) {
        ecgTask?.cancel()
        ecgTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let available = try await self.api.requestStreamSettings(deviceId, feature: .ecg)
                let chosen = Self.selectSettings(from: available, preferredRate: 130, preferredRange: nil)
                for try await ecgData in self.api.startEcgStreaming(deviceId, settings: chosen) {
                    if Task.isCancelled { break }
                    guard !ecgData.isEmpty else { continue }
                    let converted = self.convertECGSamples(ecgData)
                    if !converted.isEmpty {
                        self.callbacks.onECG(converted)
                    }
                }
            } catch {
                // Stream ends on disconnect or unsupported device
            }
        }
    }

    private func startACCStream(deviceId: String) {
        accTask?.cancel()
        accTask = Task { [weak self] in
            guard let self = self else { return }
            do {
                let available = try await self.api.requestStreamSettings(deviceId, feature: .acc)
                let chosen = Self.selectSettings(from: available, preferredRate: 25, preferredRange: 2)
                for try await accData in self.api.startAccStreaming(deviceId, settings: chosen) {
                    if Task.isCancelled { break }
                    guard !accData.isEmpty else { continue }
                    let converted = self.convertACCSamples(accData)
                    if !converted.isEmpty {
                        self.callbacks.onACC(converted)
                    }
                }
            } catch {
                // Stream ends on disconnect or unsupported device
            }
        }
    }

    private func syncDeviceTime(deviceId: String) {
        Task { [weak self] in
            guard let self = self else { return }
            try? await self.api.setLocalTime(deviceId, time: Date(), zone: .current)
        }
    }

    // MARK: - Settings & Timestamp Conversion

    private static func selectSettings(
        from available: PolarSensorSetting,
        preferredRate: UInt32?,
        preferredRange: UInt32?
    ) -> PolarSensorSetting {
        var selected: [PolarSensorSetting.SettingType: UInt32] = [:]

        for (type, values) in available.settings {
            let valid = values.filter { $0 > 0 }
            guard !valid.isEmpty else { continue }

            switch type {
            case .sampleRate:
                if let target = preferredRate {
                    selected[type] = closestValue(in: valid, to: target)
                } else if let maxVal = valid.max() {
                    selected[type] = maxVal
                }
            case .range:
                if let target = preferredRange {
                    selected[type] = closestValue(in: valid, to: target)
                } else if let maxVal = valid.max() {
                    selected[type] = maxVal
                }
            default:
                if let maxVal = valid.max() {
                    selected[type] = maxVal
                }
            }
        }

        if let custom = try? PolarSensorSetting(selected), !selected.isEmpty {
            return custom
        }
        return available.maxSettings()
    }

    private static func closestValue(in values: Set<UInt32>, to target: UInt32) -> UInt32 {
        values.min { a, b in
            let distA = a >= target ? a - target : target - a
            let distB = b >= target ? b - target : target - b
            if distA == distB {
                return a < b
            }
            return distA < distB
        } ?? target
    }

    private func convertECGSamples(_ raw: PolarEcgData) -> [ECGSample] {
        let nowUnix = Date().timeIntervalSince1970
        let lastPolarSec = Double(raw[raw.count - 1].timeStamp) / 1_000_000_000.0 + Self.polarEpochOffsetSeconds
        let offset = resolveClockOffset(isECG: true, polarSec: lastPolarSec, nowUnix: nowUnix)

        var out: [ECGSample] = []
        out.reserveCapacity(raw.count)
        for item in raw {
            let t = Double(item.timeStamp) / 1_000_000_000.0 + Self.polarEpochOffsetSeconds + offset
            out.append(ECGSample(t: t, uV: item.voltage))
        }
        return out
    }

    private func convertACCSamples(_ raw: PolarAccData) -> [ACCSample] {
        let nowUnix = Date().timeIntervalSince1970
        let lastPolarSec = Double(raw[raw.count - 1].timeStamp) / 1_000_000_000.0 + Self.polarEpochOffsetSeconds
        let offset = resolveClockOffset(isECG: false, polarSec: lastPolarSec, nowUnix: nowUnix)

        var out: [ACCSample] = []
        out.reserveCapacity(raw.count)
        for item in raw {
            let t = Double(item.timeStamp) / 1_000_000_000.0 + Self.polarEpochOffsetSeconds + offset
            out.append(ACCSample(t: t, x: item.x, y: item.y, z: item.z))
        }
        return out
    }

    /// Polar PMD timestamps are ns since 2000-01-01. If the H10 clock matches wall-clock time
    /// (within 24 h), offset is 0. Otherwise we anchor the monotonic Polar clock to Unix wall time
    /// on stream start (or after a > 5 s jump) so sample spacing stays hardware-exact while dates are valid.
    private func resolveClockOffset(isECG: Bool, polarSec: Double, nowUnix: Double) -> Double {
        stateLock.lock()
        defer { stateLock.unlock() }

        let diff = abs(nowUnix - polarSec)
        if diff < 86_400.0 {
            if isECG {
                ecgClockOffset = 0.0
                lastECGPolarSec = polarSec
            } else {
                accClockOffset = 0.0
                lastACCPolarSec = polarSec
            }
            return 0.0
        }

        let existing = isECG ? ecgClockOffset : accClockOffset
        let prev = isECG ? lastECGPolarSec : lastACCPolarSec
        if let existingOffset = existing, let prevPolar = prev {
            let delta = polarSec - prevPolar
            if delta >= 0 && delta < 5.0 {
                if isECG {
                    lastECGPolarSec = polarSec
                } else {
                    lastACCPolarSec = polarSec
                }
                return existingOffset
            }
        }

        let newOffset = nowUnix - polarSec
        if isECG {
            ecgClockOffset = newOffset
            lastECGPolarSec = polarSec
        } else {
            accClockOffset = newOffset
            lastACCPolarSec = polarSec
        }
        return newOffset
    }

    private func convertExerciseToRR(
        exerciseData: PolarExerciseData,
        entryDate: Date,
        sessionStartDate: Date
    ) -> [RRInterval] {
        let baseTimestamp: Timestamp
        if abs(entryDate.timeIntervalSince(sessionStartDate)) < 600.0 {
            baseTimestamp = entryDate.timeIntervalSince1970
        } else {
            baseTimestamp = sessionStartDate.timeIntervalSince1970
        }

        var cursor = baseTimestamp
        var intervals: [RRInterval] = []
        intervals.reserveCapacity(exerciseData.samples.count)

        for rawMs in exerciseData.samples {
            let ms = Double(rawMs)
            guard ms >= 200.0 && ms <= 4000.0 else { continue }
            cursor += ms / 1000.0
            intervals.append(RRInterval(t: cursor, ms: ms))
        }
        return intervals
    }

    // MARK: - Helpers

    private func bluetoothBlockedState() -> ConnectionState? {
        let auth = CBManager.authorization
        if auth == .denied || auth == .restricted {
            return .unauthorized
        }
        if !api.isBlePowered {
            return .bluetoothOff
        }
        return nil
    }

    private func cancelAllTasks() {
        scanTask?.cancel()
        scanTask = nil
        ecgTask?.cancel()
        ecgTask = nil
        accTask?.cancel()
        accTask = nil
        hrTask?.cancel()
        hrTask = nil
    }

    private func resetClockOffsets() {
        stateLock.lock()
        ecgClockOffset = nil
        accClockOffset = nil
        lastECGPolarSec = nil
        lastACCPolarSec = nil
        stateLock.unlock()
    }

    private func setCurrentDevice(id: String?, name: String?) {
        stateLock.lock()
        currentDeviceId = id
        currentDeviceName = name
        stateLock.unlock()
    }

    private func getCurrentDeviceId() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentDeviceId
    }

    private func getCurrentDeviceName() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return currentDeviceName
    }

    private func setConnected(_ value: Bool) {
        stateLock.lock()
        isConnected = value
        stateLock.unlock()
    }

    private func getConnected() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return isConnected
    }

    private func setFlags(wantsConnection: Bool, userInitiatedDisconnect: Bool) {
        stateLock.lock()
        self.wantsConnection = wantsConnection
        self.userInitiatedDisconnect = userInitiatedDisconnect
        stateLock.unlock()
    }

    private func shouldReconnect() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wantsConnection && !userInitiatedDisconnect
    }
}

// MARK: - PolarBleApiObserver

extension PolarH10Manager: PolarBleApiObserver {
    func deviceConnecting(_ identifier: PolarDeviceInfo) {
        setCurrentDevice(id: identifier.deviceId, name: identifier.name)
        callbacks.onDeviceIdentified(identifier.deviceId, identifier.name)
        let state: ConnectionState = shouldReconnect() && getConnected() ? .reconnecting : .connecting
        callbacks.onConnectionStateChange(state)
    }

    func deviceConnected(_ identifier: PolarDeviceInfo) {
        scanTask?.cancel()
        scanTask = nil
        setCurrentDevice(id: identifier.deviceId, name: identifier.name)
        setConnected(true)
        resetClockOffsets()
        callbacks.onDeviceIdentified(identifier.deviceId, identifier.name)
        callbacks.onConnectionStateChange(.connected)
    }

    func deviceDisconnected(_ identifier: PolarDeviceInfo, info: PolarBleDisconnectInfo) {
        ecgTask?.cancel()
        ecgTask = nil
        accTask?.cancel()
        accTask = nil
        hrTask?.cancel()
        hrTask = nil
        setConnected(false)
        resetClockOffsets()

        if let blocked = bluetoothBlockedState() {
            callbacks.onConnectionStateChange(blocked)
            return
        }

        if info.recoveryAction == .removePairingAndPairAgain {
            callbacks.onConnectionStateChange(.idle)
            return
        }

        if shouldReconnect() {
            callbacks.onConnectionStateChange(.reconnecting)
        } else {
            callbacks.onConnectionStateChange(.idle)
        }
    }
}

// MARK: - PolarBleApiPowerStateObserver

extension PolarH10Manager: PolarBleApiPowerStateObserver {
    func blePowerOn() {
        let auth = CBManager.authorization
        if auth == .denied || auth == .restricted {
            callbacks.onConnectionStateChange(.unauthorized)
            return
        }
        if shouldReconnect(), let deviceId = getCurrentDeviceId() {
            callbacks.onConnectionStateChange(.reconnecting)
            try? api.connectToDevice(deviceId)
        } else if !getConnected() {
            callbacks.onConnectionStateChange(.idle)
        }
    }

    func blePowerOff() {
        cancelAllTasks()
        setConnected(false)
        resetClockOffsets()
        let auth = CBManager.authorization
        if auth == .denied || auth == .restricted {
            callbacks.onConnectionStateChange(.unauthorized)
        } else {
            callbacks.onConnectionStateChange(.bluetoothOff)
        }
    }
}

// MARK: - PolarBleApiDeviceInfoObserver

extension PolarH10Manager: PolarBleApiDeviceInfoObserver {
    func batteryLevelReceived(_ identifier: String, batteryLevel: UInt) {
        callbacks.onBatteryLevel(Int(batteryLevel))
    }

    func batteryChargingStatusReceived(_ identifier: String, chargingStatus: BleBasClient.ChargeState) {
        // Not used for H10 (coin cell CR2025)
    }

    func disInformationReceived(_ identifier: String, uuid: CBUUID, value: String) {
        // Optional DIS metadata
    }

    func disInformationReceivedWithKeysAsStrings(_ identifier: String, key: String, value: String) {
        // Optional DIS metadata
    }
}

// MARK: - PolarBleApiDeviceFeaturesObserver

extension PolarH10Manager: PolarBleApiDeviceFeaturesObserver {
    func bleSdkFeatureReady(_ identifier: String, feature: PolarBleSdkFeature) {
        switch feature {
        case .feature_hr:
            startHRStream(deviceId: identifier)
        case .feature_polar_online_streaming:
            startECGAndACCStreams(deviceId: identifier)
        case .feature_polar_device_time_setup:
            syncDeviceTime(deviceId: identifier)
        case .feature_battery_info:
            if let level = try? api.getBatteryLevel(identifier: identifier), level >= 0 {
                callbacks.onBatteryLevel(level)
            }
        default:
            break
        }
    }
}
