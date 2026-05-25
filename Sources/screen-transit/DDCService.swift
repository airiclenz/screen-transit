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
    /// Skips the write if the display already reports the requested input.
    func setInput(display: Int, inputCode: Int) -> Bool {
        Log.debug(
            "DDC setInput: display=\(display) inputCode=\(inputCode)"
        )

        guard let service = getDisplayService(at: display) else {
            Log.error("Display \(display) not found")
            return false
        }
        defer { IOObjectRelease(service) }

        if let current = readVCP(service: service, code: 0x60) {
            if Int(current) == inputCode {
                Log.info(
                    "Display \(display) already on input \(inputCode), skipping"
                )
                return true
            }
            Log.debug(
                "Display \(display) currently on input \(current), switching"
            )
        } else {
            Log.debug(
                "Could not read current input for display \(display), "
                    + "proceeding with write"
            )
        }

        return writeVCP(
            service: service,
            code: 0x60,
            value: UInt16(inputCode)
        )
    }

    // -------------------------------------------------------------------------
    /// Returns the current input source reported by the display, or nil on failure.
    func getInput(display: Int) -> Int? {
        guard let service = getDisplayService(at: display) else {
            Log.error("Display \(display) not found")
            return nil
        }
        defer { IOObjectRelease(service) }

        return readVCP(service: service, code: 0x60).map { Int($0) }
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
    /// Reads a DDC/CI VCP feature value from a display. Returns nil on failure
    /// or if the reply is malformed (NACK, bad checksum, opcode mismatch).
    private func readVCP(
        service: io_service_t,
        code: UInt8
    ) -> UInt16? {
        guard let avService = openAVService(service: service) else {
            Log.error("Failed to open IOAVService")
            return nil
        }

        let sourceAddress: UInt8 = 0x51
        // 0x80 | 2 payload bytes
        let requestLength: UInt8 = 0x82
        let requestOpcode: UInt8 = 0x01
        let requestChecksum: UInt8 = 0x6E ^ sourceAddress
            ^ requestLength ^ requestOpcode ^ code

        var request: [UInt8] = [
            requestLength, requestOpcode, code, requestChecksum
        ]

        let didWrite = writeI2C(
            avService: avService,
            chipAddress: 0x37,
            dataAddress: UInt32(sourceAddress),
            data: &request,
            count: request.count
        )

        guard didWrite else {
            Log.debug("DDC/CI read request write failed")
            return nil
        }

        // DDC/CI spec requires >=40ms between request and reply.
        usleep(50_000)

        var reply = [UInt8](repeating: 0, count: 11)
        let didRead = readI2C(
            avService: avService,
            chipAddress: 0x37,
            dataAddress: 0x50,
            data: &reply,
            count: reply.count
        )

        guard didRead else {
            Log.debug("DDC/CI read reply I2C failed")
            return nil
        }

        if Log.isDebugEnabled {
            let packet = reply.map { String(format: "0x%02X", $0) }
                .joined(separator: " ")
            Log.debug("DDC/CI read reply: [\(packet)]")
        }

        // Expected reply: [src=0x6E, len=0x88, op=0x02, result, code,
        //                  type, maxHi, maxLo, curHi, curLo, checksum]
        guard reply[0] == 0x6E, reply[2] == 0x02, reply[3] == 0x00,
              reply[4] == code
        else {
            Log.debug("DDC/CI read reply malformed or NACK")
            return nil
        }

        let checksum = reply.dropLast().reduce(0x50, ^)
        guard checksum == reply[10] else {
            Log.debug("DDC/CI read reply checksum mismatch")
            return nil
        }

        return (UInt16(reply[8]) << 8) | UInt16(reply[9])
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

    // -------------------------------------------------------------------------
    /// Reads raw I2C data from a display via the private IOAVServiceReadI2C API.
    private func readI2C(
        avService: AnyObject,
        chipAddress: UInt32,
        dataAddress: UInt32,
        data: UnsafeMutablePointer<UInt8>,
        count: Int
    ) -> Bool {
        typealias ReadFunction = @convention(c) (
            AnyObject,
            UInt32,
            UInt32,
            UnsafeMutablePointer<UInt8>,
            UInt32
        ) -> IOReturn

        guard let symbol = dlsym(
            rtldDefault,
            "IOAVServiceReadI2C"
        ) else {
            Log.error("IOAVServiceReadI2C symbol not found via dlsym")
            return false
        }

        let read = unsafeBitCast(symbol, to: ReadFunction.self)
        let ioResult = read(
            avService, chipAddress, dataAddress, data, UInt32(count)
        )
        let isSuccessful = ioResult == kIOReturnSuccess

        if Log.isDebugEnabled {
            Log.debug(
                "I2C read result: 0x\(String(ioResult, radix: 16)) "
                    + "(\(isSuccessful ? "success" : "failed"))"
            )
        }

        return isSuccessful
    }
}
