import Darwin
import Testing
@testable import VVTerm

// Test Context:
// These tests protect AtomicSocket, the thread-safe file-descriptor wrapper used
// by SSHSession cancellation. They use pipe file descriptors instead of network
// sockets or libssh2; update only when socket abort ownership intentionally
// changes.

struct AtomicSocketTests {
    @Test
    func socketPropertyStoresLatestDescriptor() {
        let socket = AtomicSocket()

        // Given an initialized wrapper.
        #expect(socket.socket == -1)

        // When a descriptor value is stored.
        socket.socket = 42

        // Then callers can read back the latest descriptor.
        #expect(socket.socket == 42)
    }

    @Test
    func closeImmediatelyResetsDescriptorAndClosesFileDescriptor() throws {
        var fileDescriptors: [Int32] = [-1, -1]
        let pipeResult = fileDescriptors.withUnsafeMutableBufferPointer { buffer in
            pipe(buffer.baseAddress)
        }
        try #require(pipeResult == 0)
        let readDescriptor = fileDescriptors[0]
        defer {
            if fileDescriptors[0] >= 0 {
                Darwin.close(fileDescriptors[0])
            }
            if fileDescriptors[1] >= 0 {
                Darwin.close(fileDescriptors[1])
            }
        }

        let socket = AtomicSocket()
        socket.socket = readDescriptor

        // When cancellation closes the descriptor through AtomicSocket.
        socket.closeImmediately()

        // Then the wrapper is reset and the old descriptor is no longer usable.
        #expect(socket.socket == -1)
        var byte: UInt8 = 0
        let bytesRead = Darwin.read(readDescriptor, &byte, 1)
        #expect(bytesRead == -1, "closeImmediately should close the previous descriptor.")

        // Keep the defer from attempting to close the same descriptor twice.
        fileDescriptors[0] = -1
    }
}
