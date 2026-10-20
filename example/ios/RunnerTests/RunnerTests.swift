import Flutter
import UIKit
import XCTest

@testable import xue_hua_navite_clipboard

class RunnerTests: XCTestCase {

  func testGetChangeCount() {
    let plugin = XueHuaNaviteClipboardPlugin()

    let call = FlutterMethodCall(methodName: "getChangeCount", arguments: ["buffer": "general"])

    let resultExpectation = expectation(description: "result block must be called.")
    plugin.handle(call) { result in
      XCTAssertNotNil(result as? Int)
      resultExpectation.fulfill()
    }
    waitForExpectations(timeout: 1)
  }

}
