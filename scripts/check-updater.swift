import Foundation
import Sparkle

guard CommandLine.arguments.count == 2,
      let bundle = Bundle(path: CommandLine.arguments[1]) else {
    throw CocoaError(.fileReadInvalidFileName)
}

let driver = SPUStandardUserDriver(hostBundle: bundle, delegate: nil)
let updater = SPUUpdater(hostBundle: bundle, applicationBundle: bundle, userDriver: driver, delegate: nil)
do {
    try updater.start()
    print("Sparkle updater startup verified.")
} catch {
    FileHandle.standardError.write(Data("\(error.localizedDescription)\n".utf8))
    exit(1)
}
