import Foundation
import IOKit

/// CPU (this app, as a share of the whole Mac) and GPU (whole GPU) usage for the status bar.
final class UsageSampler {
    private var lastCPU: Double
    private var lastWall: CFAbsoluteTime

    init() {
        lastCPU = Self.processCPUSeconds()
        lastWall = CFAbsoluteTimeGetCurrent()
    }

    func sample() -> (cpu: Double, gpu: Double?) {
        let cpu = Self.processCPUSeconds()
        let wall = CFAbsoluteTimeGetCurrent()
        let cores = Double(max(1, ProcessInfo.processInfo.activeProcessorCount))
        let percent = max(0, (cpu - lastCPU) / max(0.001, wall - lastWall) / cores * 100)
        lastCPU = cpu
        lastWall = wall
        return (percent, Self.gpuUtilization())
    }

    private static func processCPUSeconds() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1_000_000 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The GPU driver's own "Device Utilization %" (Apple Silicon and most Macs).
    private static func gpuUtilization() -> Double? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iterator) }
        var result: Double?
        var entry = IOIteratorNext(iterator)
        while entry != 0 {
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = properties?.takeRetainedValue() as? [String: Any],
               let stats = dict["PerformanceStatistics"] as? [String: Any],
               let value = stats["Device Utilization %"] as? NSNumber {
                result = max(result ?? 0, value.doubleValue)
            }
            IOObjectRelease(entry)
            entry = IOIteratorNext(iterator)
        }
        return result
    }
}
