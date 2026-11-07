//
//  FourCharCode.swift
//  Cue
//
//  Apple Event keywords and enum values are four-char codes. Spelling them as
//  hex literals invites silent typos, so they are built from their text form
//  instead and rendered back for logging.
//

import Foundation

extension AEKeyword {
    /// Builds a four-char code from its text form, e.g. `"pnam"`.
    init(fourChar text: StaticString) {
        var value: UInt32 = 0
        let bytes = UnsafeBufferPointer(start: text.utf8Start, count: text.utf8CodeUnitCount)
        precondition(bytes.count == 4, "a four-char code must be exactly 4 bytes")
        for byte in bytes {
            value = (value << 8) | UInt32(byte)
        }
        self = value
    }

    /// The text form, for logs and error messages.
    var fourCharText: String {
        let bytes = [
            UInt8((self >> 24) & 0xFF),
            UInt8((self >> 16) & 0xFF),
            UInt8((self >> 8) & 0xFF),
            UInt8(self & 0xFF),
        ]
        let text = String(decoding: bytes, as: UTF8.self)
        return text.allSatisfy { $0.isASCII && !$0.isNewline } ? text : String(format: "0x%08X", self)
    }
}
