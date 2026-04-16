import Foundation
import Network
import os

/// Performs TCP connectivity checks against a configured host and port.
struct TCPMonitorProvider: MonitorProvider {
    private let config: TCPMonitorConfig
    private let logger = Logger(subsystem: "com.sattlerjoshua.Pulse", category: "TCPMonitor")
    private let queue = DispatchQueue(label: "com.sattlerjoshua.Pulse.tcp-check")

    init(config: TCPMonitorConfig) {
        self.config = config
    }

    func check() async throws -> CheckResult {
        let endpoint = NWEndpoint.hostPort(
            host: NWEndpoint.Host(config.host),
            port: NWEndpoint.Port(integerLiteral: UInt16(config.port))
        )
        
        let parameters = NWParameters.tcp
        // Request immediate failure if path is constrained or expensive if needed, 
        // but for now let's just use defaults with a strict timeout.
        
        let connection = NWConnection(to: endpoint, using: parameters)
        let lock = OSAllocatedUnfairLock(initialState: false)
        let start = ContinuousClock.now
        
        return await withCheckedContinuation { continuation in
            connection.stateUpdateHandler = { state in
                self.logger.debug("TCP state update for \(self.config.host):\(self.config.port): \(String(describing: state))")
                
                switch state {
                case .ready:
                    complete(with: .operational, message: nil)
                case .failed(let error):
                    complete(with: .downtime, message: error.localizedDescription)
                case .waiting(let error):
                    // For a health check, staying in .waiting is equivalent to downtime.
                    // This often happens with 'Connection Refused' error codes.
                    complete(with: .downtime, message: "Waiting/Refused: \(error.localizedDescription)")
                default:
                    break
                }
            }
            
            func complete(with status: MonitorStatus, message: String?) {
                let alreadyResponded = lock.withLock { isResponded in
                    let original = isResponded
                    isResponded = true
                    return original
                }
                
                if !alreadyResponded {
                    // It is important to cancel the connection once we have a result.
                    connection.stateUpdateHandler = nil
                    connection.cancel()
                    
                    let elapsed = ContinuousClock.now - start
                    self.logger.info("TCP check for \(self.config.host):\(self.config.port) completed: \(status.rawValue) in \(elapsed)")
                    
                    continuation.resume(returning: CheckResult(
                        status: status,
                        responseTime: elapsed,
                        timestamp: .now,
                        message: message
                    ))
                }
            }
            
            // Hard timeout at 5 seconds.
            Task {
                try? await Task.sleep(for: .seconds(5))
                complete(with: .downtime, message: "Timeout")
            }
            
            connection.start(queue: queue)
        }
    }
}
