import Foundation

#if targetEnvironment(macCatalyst)
import Darwin
#endif

/// Return allocator pages left idle after a large import, backtest, or video export.
/// The delay lets temporary payloads and view state unwind before asking malloc to trim.
nonisolated enum MacMemoryRelief {
    static func scheduleAfterHeavyOperation() {
        #if targetEnvironment(macCatalyst)
        Task.detached(priority: .background) {
            try? await Task.sleep(for: .seconds(3))
            malloc_zone_pressure_relief(nil, 0)
        }
        #endif
    }
}
