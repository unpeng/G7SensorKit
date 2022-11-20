//
//  G7SettingsViewModel.swift
//  CGMBLEKitUI
//
//  Created by Pete Schwamb on 10/4/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import G7SensorKit
import LoopKit
import LoopKitUI
import HealthKit

enum G7ProgressBarState {
    case warmupProgress
    case expirationProgress
    case sensorFailed
    case sensorExpired
    case searchingForSensor

    init(lifecycle: G7SensorLifecycleState) {
        switch lifecycle {
        case .searching:
            self = .searchingForSensor
        case .error, .ok:
            self = .expirationProgress
        case .warmup:
            self = .warmupProgress
        case .failed:
            self = .sensorFailed
        case .expired:
            self = .sensorExpired

        }
    }

    var label: String {
        switch self {
        case .searchingForSensor:
            return LocalizedString("Searching for sensor", comment: "G7 Progress bar label when searching for sensor")
        case .sensorExpired:
            return LocalizedString("Sensor expired", comment: "G7 Progress bar label when sensor expired")
        case .warmupProgress:
            return LocalizedString("Warmup completes in", comment: "G7 Progress bar label when sensor in warmup")
        case .sensorFailed:
            return LocalizedString("Sensor failed", comment: "G7 Progress bar label when sensor failed")
        case .expirationProgress:
            return LocalizedString("Sensor expires in", comment: "G7 Progress bar label when sensor failed")
        }
    }

    var labelColor: ColorStyle {
        switch self {
        case .sensorExpired:
            return .critical
        default:
            return .normal
        }
    }
}

class G7SettingsViewModel: ObservableObject {
    @Published private(set) var scanning: Bool = false
    @Published private(set) var connected: Bool = false
    @Published private(set) var sensorName: String?
    @Published private(set) var activatedAt: Date?
    @Published private(set) var lastConnect: Date?
    @Published private(set) var lastGlucoseDate: Date?
    @Published private(set) var lastGlucoseTrendFormatted: String?

    var displayGlucoseUnitObservable: DisplayGlucoseUnitObservable

    private var lastReading: G7GlucoseMessage?

    lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    private lazy var glucoseFormatter: QuantityFormatter = {
        let formatter = QuantityFormatter()
        formatter.setPreferredNumberFormatter(for: displayGlucoseUnitObservable.displayGlucoseUnit)
        formatter.numberFormatter.notANumberSymbol = "–"
        return formatter
    }()

    private let quantityFormatter = QuantityFormatter()

    private var cgmManager: G7CGMManager

    var progressBarState: G7ProgressBarState {
        return G7ProgressBarState(lifecycle: cgmManager.lifecycleState)
    }

    init(cgmManager: G7CGMManager, displayGlucoseUnitObservable: DisplayGlucoseUnitObservable) {
        self.cgmManager = cgmManager
        self.displayGlucoseUnitObservable = displayGlucoseUnitObservable
        updateValues()

        self.cgmManager.addStateObserver(self, queue: DispatchQueue.main)
    }

    func updateValues() {
        scanning = cgmManager.isScanning
        sensorName = cgmManager.sensorName
        activatedAt = cgmManager.sensorActivatedAt
        connected = cgmManager.isConnected
        lastConnect = cgmManager.lastConnect
        lastReading = cgmManager.latestReading
        lastGlucoseDate = cgmManager.latestReadingReceivedAt

        if let trendRate = lastReading?.trendRate {
            let glucoseUnitPerMinute = displayGlucoseUnitObservable.displayGlucoseUnit.unitDivided(by: .minute())
            // This seemingly strange replacement of glucose units is only to display the unit string correctly
            let trendPerMinute = HKQuantity(unit: displayGlucoseUnitObservable.displayGlucoseUnit, doubleValue: trendRate.doubleValue(for: glucoseUnitPerMinute))
            if let formatted = glucoseFormatter.string(from: trendPerMinute, for: displayGlucoseUnitObservable.displayGlucoseUnit) {
                lastGlucoseTrendFormatted = String(format: LocalizedString("%@/min", comment: "Format string for glucose trend per minute. (1: glucose value and unit)"), formatted)
            }
        }

    }

    var progressBarColorStyle: ColorStyle {
        switch progressBarState {
        case .warmupProgress:
            return .glucose
        case .searchingForSensor:
            return .dimmed
        case .sensorExpired:
            return .critical
        case .sensorFailed:
            return .dimmed
        case .expirationProgress:
            guard let remaining = progressValue else {
                return .dimmed
            }
            if remaining > .hours(24) {
                return .glucose
            } else {
                return .warning
            }
        }
    }

    var progressBarProgress: Double {
        switch progressBarState {
        case .searchingForSensor:
            return 0
        case .warmupProgress:
            guard let value = progressValue, value > 0 else {
                return 0
            }
            return 1 - value / G7Sensor.warmupDuration
        case .expirationProgress:
            guard let value = progressValue, value > 0 else {
                return 0
            }
            return 1 - value / G7Sensor.lifetime
        case .sensorExpired:
            return 1
        default:
            return 0.5
        }
    }

    var progressValue: TimeInterval? {
        switch progressBarState {
        case .sensorExpired, .sensorFailed, .searchingForSensor:
            return nil
        case .warmupProgress:
            guard let warmupFinishedAt = cgmManager.sensorFinishesWarmupAt else {
                return nil
            }
            return warmupFinishedAt.timeIntervalSinceNow
        case .expirationProgress:
            guard let expiration = cgmManager.sensorExpiresAt else {
                return nil
            }
            return expiration.timeIntervalSinceNow
        }
    }

    func scanForNewSensor() {
        cgmManager.scanForNewSensor()
    }

    var lastGlucoseString: String {
        guard let lastReading = lastReading, let quantity = lastReading.glucoseQuantity else {
            return LocalizedString("– – –", comment: "No glucose value representation (3 dashes for mg/dL)")
        }
        switch lastReading.glucoseRangeCategory {
        case .some(.belowRange):
            return LocalizedString("LOW", comment: "String displayed instead of a glucose value below the CGM range")
        case .some(.aboveRange):
            return LocalizedString("HIGH", comment: "String displayed instead of a glucose value above the CGM range")
        default:
            quantityFormatter.setPreferredNumberFormatter(for: displayGlucoseUnitObservable.displayGlucoseUnit)
            return quantityFormatter.string(from: quantity, for: displayGlucoseUnitObservable.displayGlucoseUnit, includeUnit: false) ?? ""
        }
    }

}

extension G7SettingsViewModel: G7StateObserver {
    func g7StateDidUpdate(_ state: G7CGMManagerState?) {
        updateValues()
    }

    func g7ConnectionStatusDidChange() {
        updateValues()
    }
}
