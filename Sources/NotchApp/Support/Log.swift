import Foundation
import os

enum Log {
    private static let subsystem = "com.atvereklavs.notch"

    static let server = Logger(subsystem: subsystem, category: "server")
    static let store = Logger(subsystem: subsystem, category: "store")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let telegram = Logger(subsystem: subsystem, category: "telegram")
    static let app = Logger(subsystem: subsystem, category: "app")
}
