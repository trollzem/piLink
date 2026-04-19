import Foundation
import CoreMedia
import CLibUSB

/// Sends VideoToolbox-produced H.264 sample buffers to the Pi over a USB
/// bulk-OUT endpoint (FunctionFS on the Pi side). Skips the TCP/IP/UDP stack
/// entirely and transfers raw framed NAL units over the USB wire.
///
/// Framing: 4-byte big-endian length, then the NAL bytes. SPS/PPS are
/// emitted as separate NALs on keyframes.
final class USBBulkStreamer {
    private let vid: UInt16 = 0x1d6b    /* Linux Foundation */
    private let pid: UInt16 = 0x0104    /* Multifunction Composite Gadget */
    private let iface: Int32 = 2        /* vendor-specific FFS interface */
    private let epOut: UInt8 = 0x02     /* bulk OUT endpoint (0x01 taken by CDC-ECM data) */

    private var ctx: OpaquePointer?
    private var dev: OpaquePointer?
    private let queue = DispatchQueue(label: "pidisplay.usb", qos: .userInitiated)
    private var isReady = false
    private var stopped = false

    /// Reusable framing buffer; NALs are appended with their length prefix
    /// and flushed per sample buffer.
    private var scratch = Data(capacity: 2 * 1024 * 1024)

    func start() {
        queue.async { [weak self] in self?.connect() }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self = self else { return }
            self.stopped = true
            if let dev = self.dev {
                libusb_release_interface(dev, self.iface)
                libusb_close(dev)
                self.dev = nil
            }
            if let ctx = self.ctx {
                libusb_exit(ctx)
                self.ctx = nil
            }
        }
    }

    private func connect() {
        guard !stopped else { return }
        if ctx == nil {
            var c: OpaquePointer?
            guard libusb_init(&c) == 0 else {
                FileHandle.standardError.write(Data("libusb_init failed\n".utf8))
                return
            }
            ctx = c
        }

        dev = libusb_open_device_with_vid_pid(ctx, vid, pid)
        guard let dev = dev else {
            FileHandle.standardError.write(
                Data("device \(String(format: "%04x:%04x", vid, pid)) not found, retry in 1s\n".utf8))
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
            return
        }

        if libusb_kernel_driver_active(dev, iface) > 0 {
            libusb_detach_kernel_driver(dev, iface)
        }
        let cr = libusb_claim_interface(dev, iface)
        guard cr == 0 else {
            FileHandle.standardError.write(
                Data("claim interface \(iface) failed: \(cr)\n".utf8))
            libusb_close(dev)
            self.dev = nil
            queue.asyncAfter(deadline: .now() + 1) { [weak self] in self?.connect() }
            return
        }
        FileHandle.standardError.write(Data("usb sender ready -> 1d6b:0104 iface \(iface)\n".utf8))
        isReady = true
    }

    func send(_ sampleBuffer: CMSampleBuffer) {
        guard let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        // Build the packed buffer of all NALs with length prefixes.
        var pkt = Data()
        pkt.reserveCapacity(64 * 1024)

        if isKeyframe(sampleBuffer),
           let fmt = CMSampleBufferGetFormatDescription(sampleBuffer) {
            for ps in h264ParameterSets(from: fmt) {
                appendLengthPrefixed(&pkt, ps)
            }
        }

        var totalLength = 0
        var dataPtr: UnsafeMutablePointer<CChar>?
        let s = CMBlockBufferGetDataPointer(
            dataBuffer, atOffset: 0, lengthAtOffsetOut: nil,
            totalLengthOut: &totalLength, dataPointerOut: &dataPtr
        )
        guard s == noErr, let dataPtr = dataPtr else { return }
        let base = UnsafeRawPointer(dataPtr)

        var off = 0
        while off + 4 <= totalLength {
            let lenBE = base.loadUnaligned(fromByteOffset: off, as: UInt32.self)
            let naluLength = Int(UInt32(bigEndian: lenBE))
            off += 4
            guard naluLength > 0, off + naluLength <= totalLength else { break }
            var be = UInt32(naluLength).bigEndian
            pkt.append(Data(bytes: &be, count: 4))
            pkt.append(base.advanced(by: off).assumingMemoryBound(to: UInt8.self),
                       count: naluLength)
            off += naluLength
        }

        guard !pkt.isEmpty else { return }

        queue.async { [weak self] in
            guard let self = self, self.isReady, let dev = self.dev else { return }
            var actual: Int32 = 0
            let r = pkt.withUnsafeMutableBytes { buf -> Int32 in
                guard let base = buf.baseAddress else { return -1 }
                return libusb_bulk_transfer(
                    dev, self.epOut,
                    base.assumingMemoryBound(to: UInt8.self),
                    Int32(buf.count), &actual, 100)
            }
            if r < 0 {
                FileHandle.standardError.write(
                    Data("bulk_transfer failed: \(r) (sent \(actual)/\(pkt.count))\n".utf8))
                // Attempt reconnect on persistent failure
                if r == LIBUSB_ERROR_NO_DEVICE.rawValue || r == LIBUSB_ERROR_PIPE.rawValue {
                    self.isReady = false
                    libusb_release_interface(dev, self.iface)
                    libusb_close(dev)
                    self.dev = nil
                    self.queue.asyncAfter(deadline: .now() + 1) { self.connect() }
                }
            }
        }
    }

    private func appendLengthPrefixed(_ out: inout Data, _ nal: Data) {
        var be = UInt32(nal.count).bigEndian
        out.append(Data(bytes: &be, count: 4))
        out.append(nal)
    }

    private func isKeyframe(_ sb: CMSampleBuffer) -> Bool {
        guard let att = CMSampleBufferGetSampleAttachmentsArray(
            sb, createIfNecessary: false
        ) as? [[CFString: Any]],
              let first = att.first else { return true }
        if let notSync = first[kCMSampleAttachmentKey_NotSync] as? Bool {
            return !notSync
        }
        return true
    }

    private func h264ParameterSets(from fmt: CMFormatDescription) -> [Data] {
        var count: Int = 0
        CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
            fmt, parameterSetIndex: 0,
            parameterSetPointerOut: nil, parameterSetSizeOut: nil,
            parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        var out: [Data] = []
        for i in 0..<count {
            var ptr: UnsafePointer<UInt8>?
            var size: Int = 0
            let s = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: i,
                parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            if s == noErr, let ptr = ptr, size > 0 {
                out.append(Data(bytes: ptr, count: size))
            }
        }
        return out
    }
}
