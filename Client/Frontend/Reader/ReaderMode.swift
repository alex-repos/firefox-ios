/* This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at http://mozilla.org/MPL/2.0/. */

import Foundation
import Shared
import WebKit

let ReaderModeProfileKeyStyle = "readermode.style"

enum ReaderModeMessageType: String {
    case StateChange = "ReaderModeStateChange"
    case PageEvent = "ReaderPageEvent"
}

enum ReaderPageEvent: String {
    case PageShow = "PageShow"
}

enum ReaderModeState: String {
    case Available = "Available"
    case Unavailable = "Unavailable"
    case Active = "Active"
}

enum ReaderModeTheme: String {
    case Light = "light"
    case Dark = "dark"
    case Sepia = "sepia"
}

enum ReaderModeFontType: String {
    case Serif = "serif"
    case SansSerif = "sans-serif"
}

enum ReaderModeFontSize: Int {
    case Smallest = 1
    case Small = 2
    case Normal = 3
    case Large = 4
    case Largest = 5

    func isSmallest() -> Bool {
        return self == Smallest
    }

    func smaller() -> ReaderModeFontSize {
        switch self {
        case Smallest:
            return Smallest
        case Small:
            return Smallest
        case Normal:
            return Small
        case Large:
            return Normal
        case Largest:
            return Large
        }
    }

    func isLargest() -> Bool {
        return self == Largest
    }

    func bigger() -> ReaderModeFontSize {
        switch self {
        case Smallest:
            return Small
        case Small:
            return Normal
        case Normal:
            return Large
        case Large:
            return Largest
        case Largest:
            return Largest
        }
    }
}

struct ReaderModeStyle {
    var theme: ReaderModeTheme
    var fontType: ReaderModeFontType
    var fontSize: ReaderModeFontSize

    /// Encode the style to a JSON dictionary that can be passed to ReaderMode.js
    func encode() -> String {
        return JSON(["theme": theme.rawValue, "fontType": fontType.rawValue, "fontSize": fontSize.rawValue]).toString(pretty: false)
    }

    /// Encode the style to a dictionary that can be stored in the profile
    func encode() -> [String:AnyObject] {
        return ["theme": theme.rawValue, "fontType": fontType.rawValue, "fontSize": fontSize.rawValue]
    }

    init(theme: ReaderModeTheme, fontType: ReaderModeFontType, fontSize: ReaderModeFontSize) {
        self.theme = theme
        self.fontType = fontType
        self.fontSize = fontSize
    }

    /// Initialize the style from a dictionary, taken from the profile. Returns nil if the object cannot be decoded.
    init?(dict: [String:AnyObject]) {
        let themeRawValue = dict["theme"] as? String
        let fontTypeRawValue = dict["fontType"] as? String
        let fontSizeRawValue = dict["fontSize"] as? Int
        if themeRawValue == nil || fontTypeRawValue == nil || fontSizeRawValue == nil {
            return nil
        }

        let theme = ReaderModeTheme(rawValue: themeRawValue!)
        let fontType = ReaderModeFontType(rawValue: fontTypeRawValue!)
        let fontSize = ReaderModeFontSize(rawValue: fontSizeRawValue!)
        if theme == nil || fontType == nil || fontSize == nil {
            return nil
        }

        self.theme = theme!
        self.fontType = fontType!
        self.fontSize = fontSize!
    }
}

let DefaultReaderModeStyle = ReaderModeStyle(theme: .Light, fontType: .SansSerif, fontSize: .Normal)

/// This struct captures the response from the Readability.js code.
struct ReadabilityResult {
    var domain = ""
    var url = ""
    var content = ""
    var title = ""
    var credits = ""

    init?(object: AnyObject?) {
        if let dict = object as? NSDictionary {
            if let uri = dict["uri"] as? NSDictionary {
                if let url = uri["spec"] as? String {
                    self.url = url
                }
                if let host = uri["host"] as? String {
                    self.domain = host
                }
            }
            if let content = dict["content"] as? String {
                self.content = content
            }
            if let title = dict["title"] as? String {
                self.title = title
            }
            if let credits = dict["byline"] as? String {
                self.credits = credits
            }
        } else {
            return nil
        }
    }

    /// Initialize from a JSON encoded string
    init?(string: String) {
        let object = JSON(string: string)
        let domain = object["domain"].asString
        let url = object["url"].asString
        let content = object["content"].asString
        let title = object["title"].asString
        let credits = object["credits"].asString

        if domain == nil || url == nil || content == nil || title == nil || credits == nil {
            return nil
        }

        self.domain = domain!
        self.url = url!
        self.content = content!
        self.title = title!
        self.credits = credits!
    }

    /// Encode to a dictionary, which can then for example be json encoded
    func encode() -> [String:AnyObject] {
        return ["domain": domain, "url": url, "content": content, "title": title, "credits": credits]
    }

    /// Encode to a JSON encoded string
    func encode() -> String {
        return JSON(encode() as [String:AnyObject]).toString(pretty: false)
    }
}

/// Delegate that contains callbacks that we have added on top of the built-in WKWebViewDelegate
protocol ReaderModeDelegate {
    func readerMode(readerMode: ReaderMode, didChangeReaderModeState state: ReaderModeState, forBrowser browser: Browser)
    func readerMode(readerMode: ReaderMode, didDisplayReaderizedContentForBrowser browser: Browser)
}

let ReaderModeNamespace = "_firefox_ReaderMode"

class ReaderMode: BrowserHelper {
    var delegate: ReaderModeDelegate?

    private weak var browser: Browser?
    var state: ReaderModeState = ReaderModeState.Unavailable
    private var originalURL: NSURL?

    class func name() -> String {
        return "ReaderMode"
    }

    required init?(browser: Browser) {
        self.browser = browser

        // This is a WKUserScript at the moment because webView.evaluateJavaScript() fails with an unspecified error. Possibly script size related.
        if let path = NSBundle.mainBundle().pathForResource("Readability", ofType: "js") {
            if let source = NSString(contentsOfFile: path, encoding: NSUTF8StringEncoding, error: nil) as? String {
                var userScript = WKUserScript(source: source, injectionTime: WKUserScriptInjectionTime.AtDocumentEnd, forMainFrameOnly: true)
                browser.webView.configuration.userContentController.addUserScript(userScript)
            }
        }

        // This is executed after a page has been loaded. It executes Readability and then fires a script message to let us know if the page is compatible with reader mode.
        if let path = NSBundle.mainBundle().pathForResource("ReaderMode", ofType: "js") {
            if let source = NSString(contentsOfFile: path, encoding: NSUTF8StringEncoding, error: nil) as? String {
                var userScript = WKUserScript(source: source, injectionTime: WKUserScriptInjectionTime.AtDocumentEnd, forMainFrameOnly: true)
                browser.webView.configuration.userContentController.addUserScript(userScript)
            }
        }
    }

    func scriptMessageHandlerName() -> String? {
        return "readerModeMessageHandler"
    }

    private func handleReaderPageEvent(readerPageEvent: ReaderPageEvent) {
        switch readerPageEvent {
            case .PageShow:
                delegate?.readerMode(self, didDisplayReaderizedContentForBrowser: browser!)
        }
    }

    private func handleReaderModeStateChange(state: ReaderModeState) {
        self.state = state
        delegate?.readerMode(self, didChangeReaderModeState: state, forBrowser: browser!)
    }

    func userContentController(userContentController: WKUserContentController, didReceiveScriptMessage message: WKScriptMessage) {
        println("DEBUG: readerModeMessageHandler message: \(message.body)")
        if let msg = message.body as? Dictionary<String,String> {
            if let messageType = ReaderModeMessageType(rawValue: msg["Type"] ?? "") {
                switch messageType {
                    case .PageEvent:
                        if let readerPageEvent = ReaderPageEvent(rawValue: msg["Value"] ?? "Invalid") {
                            handleReaderPageEvent(readerPageEvent)
                        }
                        break
                    case .StateChange:
                        if let readerModeState = ReaderModeState(rawValue: msg["Value"] ?? "Invalid") {
                            handleReaderModeStateChange(readerModeState)
                        }
                        break
                }
            }
        }
    }

    var style: ReaderModeStyle = DefaultReaderModeStyle {
        didSet {
            if state == ReaderModeState.Active {
                browser!.webView.evaluateJavaScript("\(ReaderModeNamespace).setStyle(\(style.encode()))", completionHandler: {
                    (object, error) -> Void in
                    return
                })
            }
        }
    }
}