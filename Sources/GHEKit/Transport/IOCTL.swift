import Darwin

/// ioctl request codes Swift can't import (they're C macros), built with the BSD
/// `_IO` / `_IOR` / `_IOW` formula.
public enum IOCTL {
    static let iocVoid: UInt = 0x2000_0000
    static let iocOut: UInt = 0x4000_0000
    static let iocIn: UInt = 0x8000_0000
    static let iocParmMask: UInt = 0x1FFF

    static func io(_ group: Character, _ num: UInt) -> UInt {
        iocVoid | (UInt(group.asciiValue!) << 8) | num
    }
    static func ior(_ group: Character, _ num: UInt, size: Int) -> UInt {
        iocOut | ((UInt(size) & iocParmMask) << 16) | (UInt(group.asciiValue!) << 8) | num
    }
    static func iow(_ group: Character, _ num: UInt, size: Int) -> UInt {
        iocIn | ((UInt(size) & iocParmMask) << 16) | (UInt(group.asciiValue!) << 8) | num
    }

    /// Exclusive use of the tty.
    public static let TIOCEXCL = io("t", 13)
    /// Set modem bits (RTS/DTR).
    public static let TIOCMBIS = iow("t", 108, size: MemoryLayout<Int32>.size)
    /// Clear modem bits.
    public static let TIOCMBIC = iow("t", 107, size: MemoryLayout<Int32>.size)
    /// Read modem bits (CTS/DSR/DCD/RI).
    public static let TIOCMGET = ior("t", 106, size: MemoryLayout<Int32>.size)
}
