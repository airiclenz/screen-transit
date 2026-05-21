import Foundation
import IOKit

// Swift cannot import the RTLD_DEFAULT C macro ((void *) -2)
private let rtldDefault = UnsafeMutableRawPointer(bitPattern: -2)

struct DDCService {

    // -------------------------------------------------------------------------
    /// Returns the number of external displays found via IOKit.
    func getDisplayCount() -> Int {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("DCPAVServiceProxy")

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            return 0
        }
        defer { IOObjectRelease(iterator) }

        var count = 0
        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }
            count += 1
            IOObjectRelease(service)
        }

        return count
    }

    // -------------------------------------------------------------------------
    /// Sends a DDC/CI input-switch command to the specified display.
    func setInput(display: Int, inputCode: Int) -> Bool {
        Log.debug(
            "DDC setInput: display=\(display) inputCode=\(inputCode)"
        )

        guard let service = getDisplayService(at: display) else {
            Log.error("Display \(display) not found")
            return false
        }
        defer { IOObjectRelease(service) }

        return writeVCP(
            service: service,
            code: 0x60,
            value: UInt16(inputCode)
        )
    }

    // -------------------------------------------------------------------------
    /// Locates the IOAVService for a display at the given 1-based index.
    private func getDisplayService(at index: Int) -> io_service_t? {
        var iterator = io_iterator_t()
        let matching = IOServiceMatching("DCPAVServiceProxy")

        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            matching,
            &iterator
        ) == KERN_SUCCESS else {
            Log.debug("IOServiceGetMatchingServices failed for DCPAVServiceProxy")
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var count = 0

        while true {
            let service = IOIteratorNext(iterator)
            guard service != IO_OBJECT_NULL else { break }

            count += 1
            if count == index {
                Log.debug(
                    "Found display service at index \(index)"
                )
                return service
            }

            IOObjectRelease(service)
        }

        Log.debug(
            "Display index \(index) not found "
                + "(only \(count) display(s) available)"
        )

        return nil
    }

    // -------------------------------------------------------------------------
    /// Writes a DDC/CI Set VCP Feature command to a display via I2C.
    private func writeVCP(
        service: io_service_t,
        code: UInt8,
        value: UInt16
    ) -> Bool {
        guard let avService = openAVService(service: service) else {
            Log.error("Failed to open IOAVService")
            return false
        }

        Log.debug("IOAVService opened successfully")

        // DDC/CI checksum uses the 8-bit I2C write address (0x37 << 1)
        let checksumAddress: UInt8 = 0x6E
        let sourceAddress: UInt8 = 0x51
        // 0x80 | 4 payload bytes
        let length: UInt8 = 0x84
        let opcode: UInt8 = 0x03
        let valueHigh = UInt8(value >> 8)
        let valueLow = UInt8(value & 0xFF)

        let checksum = checksumAddress ^ sourceAddress ^ length
            ^ opcode ^ code ^ valueHigh ^ valueLow

        var data: [UInt8] = [
            length, opcode,
            code, valueHigh, valueLow,
            checksum
        ]

        if Log.isDebugEnabled {
            let packet = data.map { String(format: "0x%02X", $0) }
                .joined(separator: " ")
            Log.debug(
                "DDC/CI write: addr=0x37 sub=0x51 data=[\(packet)]"
            )
        }

        return writeI2C(
            avService: avService,
            chipAddress: 0x37,
            dataAddress: UInt32(sourceAddress),
            data: &data,
            count: data.count
        )
    }

    // -------------------------------------------------------------------------
    /// Creates an IOAVService handle for the given display via dlsym.
    private func openAVService(
        service: io_service_t
    ) -> AnyObject? {
        typealias CreateFunction = @convention(c) (
            CFAllocator?,
            io_service_t
        ) -> Unmanaged<CFTypeRef>?

        guard let symbol = dlsym(
            rtldDefault,
            "IOAVServiceCreate"
        ) else {
            Log.error("IOAVServiceCreate symbol not found via dlsym")
            return nil
        }

        let create = unsafeBitCast(symbol, to: CreateFunction.self)
        return create(kCFAllocatorDefault, service)?.takeRetainedValue()
    }

    // -------------------------------------------------------------------------
    /// Sends raw I2C data to a display via the private IOAVServiceWriteI2C API.
    private func writeI2C(
        avService: AnyObject,
        chipAddress: UInt32,
        dataAddress: UInt32,
        data: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Bool {
        typealias WriteFunction = @convention(c) (
            AnyObject,
            UInt32,
            UInt32,
            UnsafeMutablePointer<UInt8>,
            UInt32
        ) -> IOReturn

        guard let symbol = dlsym(
            rtldDefault,
            "IOAVServiceWriteI2C"
        ) else {
            Log.error("IOAVServiceWriteI2C symbol not found via dlsym")
            return false
        }

        let write = unsafeBitCast(symbol, to: WriteFunction.self)
        let ioResult = write(
            avService, chipAddress, dataAddress, data, UInt32(count)
        )
        let isSuccessful = ioResult == kIOReturnSuccess

        if Log.isDebugEnabled {
            Log.debug(
                "I2C write result: 0x\(String(ioResult, radix: 16)) "
                    + "(\(isSuccessful ? "success" : "failed"))"
            )
        }

        return isSuccessful
    }
}
