import Foundation
import CoreGraphics
import PiDisplayBridge

enum VirtualDisplayError: Error {
    case creationFailed
    case applySettingsFailed
}

final class VirtualDisplay {
    let displayID: CGDirectDisplayID
    private let display: CGVirtualDisplay
    private let descriptor: CGVirtualDisplayDescriptor

    init(width: Int, height: Int, refreshRate: Double, name: String = "Pi Display") throws {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(width)
        descriptor.maxPixelsHigh = UInt32(height)
        // Roughly 24-inch 16:9 panel so macOS computes a plausible DPI.
        descriptor.sizeInMillimeters = CGSize(width: 531, height: 299)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001
        descriptor.queue = DispatchQueue.main
        descriptor.terminationHandler = {
            FileHandle.standardError.write(Data("virtual display terminated by system\n".utf8))
        }

        let display = CGVirtualDisplay(descriptor: descriptor)
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 0
        settings.modes = [
            CGVirtualDisplayMode(
                width: UInt32(width),
                height: UInt32(height),
                refreshRate: refreshRate
            )
        ]
        guard display.apply(settings) else {
            throw VirtualDisplayError.applySettingsFailed
        }

        self.descriptor = descriptor
        self.display = display
        self.displayID = CGDirectDisplayID(display.displayID)
    }
}
