/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import UIKit

public class DeviceInfo {
    public class func deviceModel() -> String {
        return UIDevice.currentDevice().model
    }

    public class func isSimulator() -> Bool {
        return UIDevice.currentDevice().model.contains("Simulator")
    }
}
