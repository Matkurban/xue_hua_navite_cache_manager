import Cocoa
import FlutterMacOS
import XCTest

@testable import xue_hua_navite_cache_manager

class RunnerTests: XCTestCase {

  func testGetCapabilities() {
    let plugin = XueHuaNaviteCacheManagerPlugin()
    let call = FlutterMethodCall(methodName: "getCapabilities", arguments: [:])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      let map = result as? [String: Any?]
      XCTAssertEqual(map?["platformName"] as? String, "macos")
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

}
