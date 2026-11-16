// Hand-written equivalent of the code Xcode's intentbuilderc generates from
// LiveContainerSwiftUI/ViewApp.intentdefinition. intentbuilderc only exists on
// macOS, so the Makefile (Linux/xtool) build compiles this file instead.
// Keep in sync with ViewApp.intentdefinition. Not used by the Xcode build.

import Foundation
import Intents

@available(iOS 12.0, macOS 11.0, watchOS 5.0, *) @available(tvOS, unavailable)
@objc(App)
public class App: INObject {
}

@available(iOS 13.0, macOS 11.0, watchOS 6.0, *) @available(tvOS, unavailable)
@objc(AppResolutionResult)
public class AppResolutionResult: INObjectResolutionResult {
}

@available(iOS 12.0, macOS 11.0, watchOS 5.0, *) @available(tvOS, unavailable)
@objc(ViewAppIntent)
public class ViewAppIntent: INIntent {
    @NSManaged public var app: App?
}

@available(iOS 12.0, macOS 11.0, watchOS 5.0, *) @available(tvOS, unavailable)
@objc(ViewAppIntentHandling)
public protocol ViewAppIntentHandling: NSObjectProtocol {
    @available(iOS 13.0, macOS 11.0, watchOS 6.0, *)
    @objc(resolveAppForViewApp:withCompletion:)
    optional func resolveApp(for intent: ViewAppIntent, with completion: @escaping (AppResolutionResult) -> Swift.Void)

    @available(iOS 14.0, macOS 11.0, watchOS 7.0, *)
    @objc(provideAppOptionsCollectionForViewApp:withCompletion:)
    optional func provideAppOptionsCollection(for intent: ViewAppIntent, with completion: @escaping (INObjectCollection<App>?, Swift.Error?) -> Swift.Void)

    @objc(confirmViewApp:completion:)
    optional func confirm(intent: ViewAppIntent, completion: @escaping (ViewAppIntentResponse) -> Swift.Void)

    @objc(handleViewApp:completion:)
    optional func handle(intent: ViewAppIntent, completion: @escaping (ViewAppIntentResponse) -> Swift.Void)
}

@available(iOS 12.0, macOS 11.0, watchOS 5.0, *) @available(tvOS, unavailable)
@objc public enum ViewAppIntentResponseCode: Int {
    case unspecified = 0
    case ready
    case continueInApp
    case inProgress
    case success
    case failure
    case failureRequiringAppLaunch
}

@available(iOS 12.0, macOS 11.0, watchOS 5.0, *) @available(tvOS, unavailable)
@objc(ViewAppIntentResponse)
public class ViewAppIntentResponse: INIntentResponse {
    @objc public fileprivate(set) var code: ViewAppIntentResponseCode = .unspecified

    @objc(initWithCode:userActivity:)
    public convenience init(code: ViewAppIntentResponseCode, userActivity: NSUserActivity?) {
        self.init()
        self.code = code
        self.userActivity = userActivity
    }
}
