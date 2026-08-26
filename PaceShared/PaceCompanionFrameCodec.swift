import Foundation

nonisolated struct PaceCompanionWireFrame: Equatable, Sendable {
    let message: PaceCompanionMessage
    let binaryPayload: Data

    init(message: PaceCompanionMessage, binaryPayload: Data = Data()) {
        self.message = message
        self.binaryPayload = binaryPayload
    }
}

nonisolated enum PaceCompanionFrameCodecError: Error, Equatable {
    case headerTooLarge(Int)
    case payloadTooLarge(Int)
    case declaredPayloadLengthMismatch(declared: Int, actual: Int)
    case invalidHeader
}

nonisolated enum PaceCompanionFrameCodec {
    private struct Header: Codable {
        let message: PaceCompanionMessage
        let binaryPayloadByteCount: Int
    }

    static func encode(_ frame: PaceCompanionWireFrame) throws -> Data {
        try frame.message.validate()
        guard frame.message.declaredBinaryByteCount == frame.binaryPayload.count else {
            throw PaceCompanionFrameCodecError.declaredPayloadLengthMismatch(
                declared: frame.message.declaredBinaryByteCount,
                actual: frame.binaryPayload.count
            )
        }
        guard frame.binaryPayload.count <= PaceCompanionProtocol.maximumBinaryPayloadByteCount else {
            throw PaceCompanionFrameCodecError.payloadTooLarge(frame.binaryPayload.count)
        }

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, dateEncoder in
            var container = dateEncoder.singleValueContainer()
            try container.encode(date.timeIntervalSince1970.bitPattern)
        }
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(
            Header(
                message: frame.message,
                binaryPayloadByteCount: frame.binaryPayload.count
            ))
        guard headerData.count <= PaceCompanionProtocol.maximumHeaderByteCount else {
            throw PaceCompanionFrameCodecError.headerTooLarge(headerData.count)
        }

        var encodedFrame = Data()
        var bigEndianHeaderLength = UInt32(headerData.count).bigEndian
        Swift.withUnsafeBytes(of: &bigEndianHeaderLength) { headerLengthBytes in
            encodedFrame.append(contentsOf: headerLengthBytes)
        }
        encodedFrame.append(headerData)
        encodedFrame.append(frame.binaryPayload)
        return encodedFrame
    }

    static func decodeHeader(_ data: Data) throws -> (message: PaceCompanionMessage, payloadLength: Int) {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { dateDecoder in
            let container = try dateDecoder.singleValueContainer()
            let encodedBitPattern = try container.decode(UInt64.self)
            return Date(timeIntervalSince1970: Double(bitPattern: encodedBitPattern))
        }
        guard let header = try? decoder.decode(Header.self, from: data) else {
            throw PaceCompanionFrameCodecError.invalidHeader
        }
        try header.message.validate()
        guard header.binaryPayloadByteCount == header.message.declaredBinaryByteCount else {
            throw PaceCompanionFrameCodecError.declaredPayloadLengthMismatch(
                declared: header.message.declaredBinaryByteCount,
                actual: header.binaryPayloadByteCount
            )
        }
        guard header.binaryPayloadByteCount <= PaceCompanionProtocol.maximumBinaryPayloadByteCount else {
            throw PaceCompanionFrameCodecError.payloadTooLarge(header.binaryPayloadByteCount)
        }
        return (header.message, header.binaryPayloadByteCount)
    }
}

nonisolated struct PaceCompanionFrameStreamDecoder: Sendable {
    private var bufferedBytes = Data()

    mutating func append(_ data: Data) throws -> [PaceCompanionWireFrame] {
        bufferedBytes.append(data)
        var decodedFrames: [PaceCompanionWireFrame] = []

        while bufferedBytes.count >= MemoryLayout<UInt32>.size {
            let headerLength = Int(
                bufferedBytes.prefix(4).reduce(UInt32(0)) { partial, byte in
                    (partial << 8) | UInt32(byte)
                })
            guard headerLength <= PaceCompanionProtocol.maximumHeaderByteCount else {
                throw PaceCompanionFrameCodecError.headerTooLarge(headerLength)
            }

            let headerStartIndex = 4
            let headerEndIndex = headerStartIndex + headerLength
            guard bufferedBytes.count >= headerEndIndex else { break }
            let headerData = bufferedBytes.subdata(in: headerStartIndex..<headerEndIndex)
            let decodedHeader = try PaceCompanionFrameCodec.decodeHeader(headerData)
            let completeFrameLength = headerEndIndex + decodedHeader.payloadLength
            guard bufferedBytes.count >= completeFrameLength else { break }

            let binaryPayload = bufferedBytes.subdata(in: headerEndIndex..<completeFrameLength)
            decodedFrames.append(
                PaceCompanionWireFrame(
                    message: decodedHeader.message,
                    binaryPayload: binaryPayload
                ))
            bufferedBytes.removeFirst(completeFrameLength)
        }

        return decodedFrames
    }

    mutating func reset() {
        bufferedBytes.removeAll(keepingCapacity: false)
    }
}

nonisolated struct PaceCompanionMessageDeduplicator: Sendable {
    private let maximumRememberedMessageCount: Int
    private var messageIdentifiersInArrivalOrder: [String] = []
    private var rememberedMessageIdentifiers: Set<String> = []

    init(maximumRememberedMessageCount: Int = 256) {
        self.maximumRememberedMessageCount = max(1, maximumRememberedMessageCount)
    }

    mutating func shouldAccept(messageIdentifier: String) -> Bool {
        guard !rememberedMessageIdentifiers.contains(messageIdentifier) else { return false }
        rememberedMessageIdentifiers.insert(messageIdentifier)
        messageIdentifiersInArrivalOrder.append(messageIdentifier)

        let overflowCount = messageIdentifiersInArrivalOrder.count - maximumRememberedMessageCount
        if overflowCount > 0 {
            let expiredMessageIdentifiers = messageIdentifiersInArrivalOrder.prefix(overflowCount)
            for expiredMessageIdentifier in expiredMessageIdentifiers {
                rememberedMessageIdentifiers.remove(expiredMessageIdentifier)
            }
            messageIdentifiersInArrivalOrder.removeFirst(overflowCount)
        }
        return true
    }
}
