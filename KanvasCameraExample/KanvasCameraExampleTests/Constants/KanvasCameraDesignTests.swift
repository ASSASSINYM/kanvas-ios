//
// This Source Code Form is subject to the terms of the Mozilla Public
// License, v. 2.0. If a copy of the MPL was not distributed with this
// file, You can obtain one at https://mozilla.org/MPL/2.0/.
//

@testable import KanvasCamera
import Foundation
import XCTest

final class KanvasCameraDesignTests: XCTestCase {

    func testOriginal() {
        XCTAssertFalse(KanvasCameraDesign.original.isBottomPicker, "The result should be false.")
    }
    
    func testBottomPicker() {
        XCTAssertTrue(KanvasCameraDesign.bottomPicker.isBottomPicker, "The result should be true.")
    }

}
