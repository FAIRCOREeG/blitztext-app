import XCTest

final class WAVRecoveryTests: XCTestCase {
    /// RIFF/WAVE header with a format chunk, optional padding chunk and a data chunk whose
    /// sizes are given explicitly.
    private func header(riffSize: UInt32, dataSize: UInt32, padding: Int = 0) -> Data {
        var data = Data("RIFF".utf8) + le(riffSize) + Data("WAVE".utf8)
        data += Data("fmt ".utf8) + le(16) + Data(repeating: 1, count: 16)
        if padding > 0 {
            data += Data("FLLR".utf8) + le(UInt32(padding)) + Data(repeating: 0, count: padding)
        }
        data += Data("data".utf8) + le(dataSize)
        return data
    }

    private func le(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    func testPatchesSizesLeftAtZero() {
        let head = header(riffSize: 0, dataSize: 0)
        let patches = WAVRecovery.sizePatches(header: head, fileLength: head.count + 3_200)
        XCTAssertEqual(patches?.map(\.offset), [4, 40])
        XCTAssertEqual(patches?.map(\.value), [UInt32(head.count + 3_200 - 8), 3_200])
    }

    func testSkipsPaddingChunkBeforeTheData() {
        let head = header(riffSize: 0, dataSize: 0, padding: 4_044)
        let patches = WAVRecovery.sizePatches(header: head, fileLength: head.count + 64_000)
        XCTAssertEqual(patches?.last?.offset, head.count - 4)
        XCTAssertEqual(patches?.last?.value, 64_000)
    }

    func testLeavesCorrectHeaderAlone() {
        let head = header(riffSize: 0, dataSize: 0)
        let length = head.count + 1_000
        let correct = header(riffSize: UInt32(length - 8), dataSize: 1_000)
        XCTAssertNil(WAVRecovery.sizePatches(header: correct, fileLength: length))
    }

    func testIgnoresOtherFiles() {
        XCTAssertNil(WAVRecovery.sizePatches(header: Data("ID3 not a wave file".utf8), fileLength: 400))
    }

    func testRepairsFileOnDisk() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("wav-recovery-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try (header(riffSize: 0, dataSize: 0) + Data(repeating: 7, count: 800)).write(to: url)
        XCTAssertTrue(WAVRecovery.repairIfNeeded(url))
        let repaired = try Data(contentsOf: url)
        XCTAssertNil(WAVRecovery.sizePatches(header: repaired, fileLength: repaired.count))
        XCTAssertFalse(WAVRecovery.repairIfNeeded(url))
    }
}
