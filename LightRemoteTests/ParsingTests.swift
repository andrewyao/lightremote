import XCTest
@testable import LightRemote

final class ParsingTests: XCTestCase {
    func testResponseErrorBecomesSonyError() {
        let data = Data(#"{"error":[40403,"Long shooting"],"id":3}"#.utf8)
        XCTAssertThrowsError(try SonyClient.parseResponse(data)) { e in
            XCTAssertEqual(e as? SonyError, SonyError(code: 40403, message: "Long shooting"))
        }
    }

    func testResponseResult() throws {
        let r = try SonyClient.parseResponse(Data(#"{"result":[["http://x/pict.JPG"]],"id":1}"#.utf8))
        XCTAssertEqual(r.first?.strings, ["http://x/pict.JPG"])
    }

    func testEventParsesByTypeNotPosition() throws {
        let json = #"""
        {"result":[
          {"type":"availableApiList","names":["actTakePicture","setFNumber"]},
          {"type":"cameraStatus","cameraStatus":"IDLE"},
          null,
          [{"type":"takePicture","takePictureUrl":["http://cam/postview/p1.JPG"]}],
          [{"type":"storageInformation","numberOfRecordableImages":214}],
          [{"type":"batteryInfo","levelNumer":3,"levelDenom":4}],
          {"type":"fNumber","currentFNumber":"5.6","fNumberCandidates":["4.0","5.6","8.0"]},
          {"type":"isoSpeedRate","currentIsoSpeedRate":"400","isoSpeedRateCandidates":["AUTO","400"]},
          {"type":"shutterSpeed","currentShutterSpeed":"1/250","shutterSpeedCandidates":["BULB","1/250"]},
          {"type":"exposureCompensation","currentExposureCompensation":-3,"maxExposureCompensation":15,
           "minExposureCompensation":-15,"stepIndexOfExposureCompensation":1},
          {"type":"selfTimer","currentSelfTimer":0,"selfTimerCandidates":[0,2,10]}
        ],"id":1}
        """#
        let e = CameraEvent(result: try SonyClient.parseResponse(Data(json.utf8)))
        XCTAssertEqual(e.availableApis, ["actTakePicture", "setFNumber"])
        XCTAssertEqual(e.cameraStatus, "IDLE")
        XCTAssertEqual(e.takePictureURLs, [URL(string: "http://cam/postview/p1.JPG")!])
        XCTAssertEqual(e.recordableImages, 214)
        XCTAssertEqual(e.batteryPercent, 75)
        XCTAssertEqual(e.fNumber, Setting(current: "5.6", candidates: ["4.0", "5.6", "8.0"]))
        XCTAssertEqual(e.iso?.current, "400")
        XCTAssertEqual(e.shutterSpeed?.candidates, ["BULB", "1/250"])
        XCTAssertEqual(e.selfTimer, Setting(current: 0, candidates: [0, 2, 10]))
        let ev = try XCTUnwrap(e.exposureCompensation)
        XCTAssertEqual(ev.ev(ev.currentIndex), -1.0, accuracy: 1e-9)
        XCTAssertEqual(ev.indices.count, 31)
        XCTAssertNil(e.focusMode, "not reported → hidden in the UI")
    }

    // MARK: Live view

    private func packet(type: UInt8, seq: UInt16, payload: [UInt8], padding: Int = 0) -> Data {
        var d = Data([0xFF, type, UInt8(seq >> 8), UInt8(seq & 0xFF), 0, 0, 0, 0])
        d += LiveViewParser.startCode
        d += [UInt8(payload.count >> 16 & 0xFF), UInt8(payload.count >> 8 & 0xFF), UInt8(payload.count & 0xFF)]
        d += [UInt8(padding)]
        d += [UInt8](repeating: 0, count: 120)
        d += payload
        d += [UInt8](repeating: 0, count: padding)
        return d
    }

    func testLiveViewParserHandlesSplitsPaddingAndFrameInfo() {
        // JPEG payloads contain 0xFF bytes, which must not confuse resync.
        let jpeg1: [UInt8] = [0xFF, 0xD8, 0x01, 0xFF, 0x02, 0xFF, 0xD9]
        let jpeg2: [UInt8] = [0xFF, 0xD8, 0xAA, 0xBB, 0xFF, 0xD9]
        var stream = Data([0x00, 0x13])                        // garbage before the first header
        stream += packet(type: 0x01, seq: 1, payload: jpeg1, padding: 3)
        stream += packet(type: 0x02, seq: 2, payload: [1, 2, 3, 4])  // frame info: skipped
        stream += packet(type: 0x01, seq: 3, payload: jpeg2)

        for chunk in [1, 7, 50, stream.count] {
            var parser = LiveViewParser()
            var frames: [Data] = []
            var i = 0
            while i < stream.count {
                frames += parser.feed(stream.subdata(in: i..<min(i + chunk, stream.count)))
                i += chunk
            }
            XCTAssertEqual(frames, [Data(jpeg1), Data(jpeg2)], "chunk size \(chunk)")
        }
    }
}
