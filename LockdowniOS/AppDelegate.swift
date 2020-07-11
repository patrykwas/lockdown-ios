//
//  AppDelegate.swift
//  ConfirmediOS
//
//  Copyright © 2018 Confirmed, Inc. All rights reserved.
//

import UIKit
import NetworkExtension
import SwiftyStoreKit
import KeychainAccess
import SafariServices
import SwiftMessages
import StoreKit
import CloudKit
import CocoaLumberjackSwift
import PopupDialog
import PromiseKit

let fileLogger: DDFileLogger = DDFileLogger()

let kHasShownTitlePage: String = "kHasShownTitlePage"

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    var window: UIWindow?
    let noInternetMessageView = MessageView.viewFromNib(layout: .statusLine)
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Clear local data for testing
//         try? keychain.removeAll()
//        for d in defaults.dictionaryRepresentation() {
//            defaults.removeObject(forKey: d.key)
//        }
        
        // Set up basic logging
        setupLocalLogger()
        
        // Set up PopupDialog
        let dialogAppearance = PopupDialogDefaultView.appearance()
        if #available(iOS 13.0, *) {
            dialogAppearance.backgroundColor = .systemBackground
            dialogAppearance.titleColor = .label
            dialogAppearance.messageColor = .label
        } else {
            dialogAppearance.backgroundColor = .white
            dialogAppearance.titleColor = .black
            dialogAppearance.messageColor = .darkGray
        }
        dialogAppearance.titleFont            = fontBold15
        dialogAppearance.titleTextAlignment   = .center
        dialogAppearance.messageFont          = fontMedium15
        dialogAppearance.messageTextAlignment = .center
        let buttonAppearance = DefaultButton.appearance()
        if #available(iOS 13.0, *) {
            buttonAppearance.buttonColor = .systemBackground
            buttonAppearance.separatorColor = UIColor(white: 0.2, alpha: 1)
        }
        else {
            buttonAppearance.buttonColor    = .clear
            buttonAppearance.separatorColor = UIColor(white: 0.9, alpha: 1)
        }
        buttonAppearance.titleFont      = fontSemiBold17
        buttonAppearance.titleColor     = UIColor.tunnelsBlue
        let cancelButtonAppearance = CancelButton.appearance()
        if #available(iOS 13.0, *) {
            cancelButtonAppearance.buttonColor = .systemBackground
            cancelButtonAppearance.separatorColor = UIColor(white: 0.2, alpha: 1)
        }
        else {
            cancelButtonAppearance.buttonColor    = .clear
            cancelButtonAppearance.separatorColor = UIColor(white: 0.9, alpha: 1)
        }
        cancelButtonAppearance.titleFont      = fontSemiBold17
        cancelButtonAppearance.titleColor     = UIColor.lightGray

        // Lockdown default lists
        setupFirewallDefaultBlockLists()
        
        // Whitelist default domains
        setupLockdownWhitelistedDomains()
        
        // Show indicator at top when internet not reachable
        reachability?.whenReachable = { reachability in
            SwiftMessages.hide()
        }
        reachability?.whenUnreachable = { _ in
            DDLogInfo("Internet not reachable")
            self.noInternetMessageView.backgroundView.backgroundColor = UIColor.orange
            self.noInternetMessageView.bodyLabel?.textColor = UIColor.white
            self.noInternetMessageView.configureContent(body: NSLocalizedString("No Internet Connection", comment: ""))
            var noInternetMessageViewConfig = SwiftMessages.defaultConfig
            noInternetMessageViewConfig.presentationContext = .window(windowLevel: UIWindow.Level(rawValue: 0))
            noInternetMessageViewConfig.preferredStatusBarStyle = .lightContent
            noInternetMessageViewConfig.duration = .forever
            SwiftMessages.show(config: noInternetMessageViewConfig, view: self.noInternetMessageView)
        }
        do {
            try reachability?.startNotifier()
        } catch {
            DDLogError("Unable to start reachability notifier")
        }
        
        // Content Blocker
        SFContentBlockerManager.reloadContentBlocker( withIdentifier: "com.confirmed.lockdown.Confirmed-Blocker") { (_ error: Error?) -> Void in
            if error != nil {
                DDLogError("Error loading Content Blocker: \(String(describing: error))")
            }
        }
        
        // Prepare IAP
        VPNSubscription.cacheLocalizedPrices()
        SwiftyStoreKit.completeTransactions(atomically: true) { purchases in
            for purchase in purchases {
                DDLogInfo("LAUNCH: Processing Purchase\n\(purchase)");
                if purchase.transaction.transactionState == .purchased || purchase.transaction.transactionState == .restored {
                    if purchase.needsFinishTransaction {
                        DDLogInfo("Finishing transaction for purchase: \(purchase)")
                        SwiftyStoreKit.finishTransaction(purchase.transaction)
                    }
                }
            }
        }
        
        // Periodically check if the firewall is functioning correctly
        UIApplication.shared.setMinimumBackgroundFetchInterval(UIApplication.backgroundFetchIntervalMinimum)

        // WORKAROUND: allows the widget to toggle VPN
        application.registerForRemoteNotifications()
        setupWidgetToggleWorkaround()
        
        // If not yet agreed to privacy policy, set initial view controller to TitleViewController
        if (defaults.bool(forKey: kHasShownTitlePage) == false) {
            // TODO: removed this check because this was causing crashes possibly due to Locale
            // don't show onboarding page for anyone who installed before Aug 16th
        //            let formatter = DateFormatter()
        //            formatter.dateFormat = "yyyy/MM/dd HH:mm"
        //            let tutorialCutoffDate = formatter.date(from: "2019/08/16 00:00")!.timeIntervalSince1970;
        //            if let appInstall = appInstallDate, appInstall.timeIntervalSince1970 < tutorialCutoffDate {
        //                print("Not showing onboarding page, installation epoch \(appInstall.timeIntervalSince1970)")
        //            }
        //            else {
                print("Showing onboarding page")
                self.window = UIWindow(frame: UIScreen.main.bounds)
                let storyboard = UIStoryboard(name: "Main", bundle: nil)
                let viewController = storyboard.instantiateViewController(withIdentifier: "titleViewController") as! TitleViewController
                self.window?.rootViewController = viewController
                self.window?.makeKeyAndVisible()
        //            }
        }
        
        return true
    }
    
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        DDLogError("Successfully registered for remote notification: \(deviceToken)")
    }
    
    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        DDLogError("Error registering for remote notification: \(error)")
    }
    
    func application(_ application: UIApplication, performFetchWithCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        FirewallController.shared.refreshManager(completion: { error in
            if let e = error {
                DDLogError("Error refreshing Manager in background check: \(e)")
                return
            }
            if getUserWantsFirewallEnabled() && (FirewallController.shared.status() == .connected || FirewallController.shared.status() == .invalid) {
                DDLogInfo("user wants firewall enabled and connected/invalid, testing blocking with background fetch")
                _ = Client.getBlockedDomainTest(connectionSuccessHandler: {
                    DDLogError("Background Fetch Test: Connected to \(testFirewallDomain) even though it's supposed to be blocked, restart the Firewall")
                    FirewallController.shared.restart(completion: {
                        error in
                        if error != nil {
                            DDLogError("Error restarting firewall on background fetch: \(error!)")
                        }
                        completionHandler(.newData)
                    })
                }, connectionFailedHandler: {
                    error in
                    if error != nil {
                        let nsError = error! as NSError
                        if nsError.domain == NSURLErrorDomain {
                            DDLogInfo("Background Fetch Test: Successful blocking of \(testFirewallDomain) with NSURLErrorDomain error: \(nsError)")
                        }
                        else {
                            DDLogInfo("Background Fetch Test: Successful blocking of \(testFirewallDomain), but seeing non-NSURLErrorDomain error: \(error!)")
                        }
                    }
                    completionHandler(.newData)
                })
            }
            else {
                completionHandler(.newData)
            }
        })
    }
    
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }

    // MARK: - WIDGET TOGGLE WORKAROUND
    func setupWidgetToggleWorkaround() {
        DDLogInfo("Setting up CloudKit Workaround")
        clearDatabaseForRecord(recordName: kOpenFirewallTunnelRecord)
        clearDatabaseForRecord(recordName: kCloseFirewallTunnelRecord)
        clearDatabaseForRecord(recordName: kRestartFirewallTunnelRecord)
        let privateDatabase = CKContainer(identifier: kICloudContainer).privateCloudDatabase
        privateDatabase.fetchAllSubscriptions(completionHandler: { subscriptions, error in
            // always set up cloudkit subscriptions - no downside to doing it
//            if error == nil, let subs = subscriptions {
////                for sub in subs {
////                    print("deleting sub: \(sub.subscriptionID)")
////                    privateDatabase.delete(withSubscriptionID: sub.subscriptionID, completionHandler: {
////                        result, error in
////                        print("result: \(result)")
////                    })
////                }
////                return
//                var isSubscribedToOpen = false
//                var isSubscribedToClose = false
//                var isSubscribedToRestart = false
//                for subscriptionObject in subs {
//                    if subscriptionObject.notificationInfo?.category == kCloseFirewallTunnelRecord {
//                        isSubscribedToClose = true
//                    }
//                    if subscriptionObject.notificationInfo?.category == kOpenFirewallTunnelRecord {
//                        isSubscribedToOpen = true
//                    }
//                    if subscriptionObject.notificationInfo?.category == kRestartFirewallTunnelRecord {
//                        isSubscribedToRestart = true
//                    }
//                }
//                if !isSubscribedToOpen {
//                    self.setupCloudKitSubscription(categoryName: kOpenFirewallTunnelRecord)
//                }
//                if !isSubscribedToClose {
//                    self.setupCloudKitSubscription(categoryName: kCloseFirewallTunnelRecord)
//                }
//                if !isSubscribedToRestart {
//                    self.setupCloudKitSubscription(categoryName: kRestartFirewallTunnelRecord)
//                }
//            }
//            else {
                self.setupCloudKitSubscription(categoryName: kCloseFirewallTunnelRecord)
                self.setupCloudKitSubscription(categoryName: kOpenFirewallTunnelRecord)
                self.setupCloudKitSubscription(categoryName: kRestartFirewallTunnelRecord)
//            }
        })
    }
    
    func setupCloudKitSubscription(categoryName: String) {
        let privateDatabase = CKContainer(identifier: kICloudContainer).privateCloudDatabase
        let subscription = CKQuerySubscription(recordType: categoryName,
                                               predicate: NSPredicate(value: true),
                                               options: .firesOnRecordCreation)
        let notificationInfo = CKSubscription.NotificationInfo()
        //notificationInfo.alertBody = "" // iOS 13 doesn't like this - fails to trigger notification
        notificationInfo.shouldSendContentAvailable = true
        notificationInfo.shouldBadge = false
        notificationInfo.category = categoryName
        subscription.notificationInfo = notificationInfo
        privateDatabase.save(subscription,
                             completionHandler: ({returnRecord, error in
                                if let err = error {
                                    DDLogInfo("Could not save CloudKit subscription (not signed in?) \(err)")
                                } else {
                                    DispatchQueue.main.async() {
                                        DDLogInfo("Successfully saved CloudKit subscription")
                                    }
                                }
                             }))
    }
    
    func clearDatabaseForRecord(recordName: String) {
        let privateDatabase = CKContainer(identifier: kICloudContainer).privateCloudDatabase
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: recordName, predicate: predicate)
        
        privateDatabase.perform(query, inZoneWith: nil) { (record, error) in
            if let err = error {
                DDLogError("Error querying for CKRecordType: \(recordName) - \(error)")
            }
            for aRecord in record! {
                privateDatabase.delete(withRecordID: aRecord.recordID, completionHandler: { (recordID, error) in
                    DDLogInfo("Deleting record \(aRecord.recordID)")
                })
            }
        }
    }
    
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable : Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        DDLogInfo("Receiving remote notification")
        if let aps = userInfo["aps"] as? NSDictionary {
            if let message = aps["category"] as? NSString {
                if message.contains(kCloseFirewallTunnelRecord) {
                    FirewallController.shared.setEnabled(false, isUserExplicitToggle: true, completion: { _ in })
                }
                else if message.contains(kOpenFirewallTunnelRecord) {
                    FirewallController.shared.setEnabled(true, isUserExplicitToggle: true, completion: { _ in })
                }
                else if message.contains(kRestartFirewallTunnelRecord) {
                    FirewallController.shared.restart(completion: {
                        error in
                        if error != nil {
                            DDLogError("Error restarting firewall on RemoteNotification: \(error!)")
                        }
                    })
                }
                clearDatabaseForRecord(recordName: kOpenFirewallTunnelRecord)
                clearDatabaseForRecord(recordName: kCloseFirewallTunnelRecord)
                clearDatabaseForRecord(recordName: kRestartFirewallTunnelRecord)
            }
        }
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 10.0, execute: {
            completionHandler(.newData)
        })
    }
    
    func application(_ app: UIApplication, open url: URL, options: [UIApplication.OpenURLOptionsKey : Any] = [:]) -> Bool {

        guard let components = NSURLComponents(url: url, resolvingAgainstBaseURL: true),
            let host = components.host else {
                print("Invalid URL")
                return false
        }
        
        if (host == "resetsuccessful") {
            let popup = PopupDialog(title: "Password Reset Successfully",
                                    message: "Please Sign In With Your New Password",
                                    image: nil,
                                    buttonAlignment: .horizontal,
                                    transitionStyle: .bounceDown,
                                    preferredWidth: 270,
                                    tapGestureDismissal: true,
                                    panGestureDismissal: false,
                                    hideStatusBar: false,
                                    completion: nil)
            popup.addButtons([
                DefaultButton(title: NSLocalizedString("Okay", comment: ""), dismissOnTap: true) {
                    if let hvc = self.getCurrentViewController() as? HomeViewController {
                        hvc.performSegue(withIdentifier: "showSignInFromHome", sender: nil)
                    }
                }
            ])
            self.getCurrentViewController()?.present(popup, animated: true, completion: nil)
            return true
        }
        
        else if (host == "emailconfirmed") {
            // test the stored login
            guard let apiCredentials = getAPICredentials() else {
                let popup = PopupDialog(title: "Error",
                                        message: NSLocalizedString("No stored API credentials found. Please contact team@lockdownhq.com about this error.", comment: ""),
                                        image: nil,
                                        buttonAlignment: .horizontal,
                                        transitionStyle: .bounceDown,
                                        preferredWidth: 270,
                                        tapGestureDismissal: true,
                                        panGestureDismissal: false,
                                        hideStatusBar: false,
                                        completion: nil)
                popup.addButtons([
                   DefaultButton(title: NSLocalizedString("Okay", comment: ""), dismissOnTap: true) {}
                ])
                getCurrentViewController()?.present(popup, animated: true, completion: nil)
                return true
            }
            firstly {
                try Client.signInWithEmail(email: apiCredentials.email, password: apiCredentials.password)
            }
            .done { (signin: SignIn) in
                // successfully signed in with no errors, show confirmation success
                setAPICredentialsConfirmed(confirmed: true)
                // logged in and confirmed - update this email with the receipt and refresh VPN credentials
                firstly { () -> Promise<SubscriptionEvent> in
                    try Client.subscriptionEvent()
                }
                .then { (result: SubscriptionEvent) -> Promise<GetKey> in
                    try Client.getKey()
                }
                .done { (getKey: GetKey) in
                    try setVPNCredentials(id: getKey.id, keyBase64: getKey.b64)
                    if (getUserWantsVPNEnabled() == true) {
                        VPNController.shared.restart()
                    }
                }
                .catch { error in
                    // it's okay for this to error out with "no subscription in receipt"
                    DDLogError("HomeViewController ConfirmEmail subscriptionevent error (ok for it to be \"no subscription in receipt\"): \(error)")
                }
                let popup = PopupDialog(title: "Success! 🎉",
                                        message: NSLocalizedString("Your account has been confirmed and you're now signed in. You'll get the latest block lists, access to Lockdown Mac, and get critical announcements.", comment: ""),
                                        image: nil,
                                        buttonAlignment: .horizontal,
                                        transitionStyle: .bounceDown,
                                        preferredWidth: 270,
                                        tapGestureDismissal: true,
                                        panGestureDismissal: false,
                                        hideStatusBar: false,
                                        completion: nil)
                popup.addButtons([
                   DefaultButton(title: NSLocalizedString("Okay", comment: ""), dismissOnTap: true) {}
                ])
                self.getCurrentViewController()?.present(popup, animated: true, completion: nil)
            }
            .catch { error in
                
                var errorMessage = error.localizedDescription
                if let apiError = error as? ApiError {
                    errorMessage = apiError.message
                }
                
                let popup = PopupDialog(title: "Error Confirming Account",
                                        message: NSLocalizedString("Error while trying to confirm your account: \(errorMessage). If this persists, please contact team@lockdownhq.com.", comment: ""),
                                        image: nil,
                                        buttonAlignment: .horizontal,
                                        transitionStyle: .bounceDown,
                                        preferredWidth: 270,
                                        tapGestureDismissal: true,
                                        panGestureDismissal: false,
                                        hideStatusBar: false,
                                        completion: nil)
                popup.addButtons([
                   DefaultButton(title: NSLocalizedString("Okay", comment: ""), dismissOnTap: true) {}
                ])
                self.getCurrentViewController()?.present(popup, animated: true, completion: nil)
            }
        }
        
        return true
    }
    
    // MARK: - Utilities
    // Returns the most recently presented UIViewController (visible)
    func getCurrentViewController() -> UIViewController? {
        // If the root view is a navigation controller, we can just return the visible ViewController
        if let navigationController = getNavigationController() {
            return navigationController.visibleViewController
        }
        // Otherwise, we must get the root UIViewController and iterate through presented views
        if let rootController = UIApplication.shared.keyWindow?.rootViewController {
            var currentController: UIViewController! = rootController
            // Each ViewController keeps track of the view it has presented, so we
            // can move from the head to the tail, which will always be the current view
            while( currentController.presentedViewController != nil ) {
                currentController = currentController.presentedViewController
            }
            return currentController
        }
        return nil
    }

    // Returns the navigation controller if it exists
    func getNavigationController() -> UINavigationController? {
        if let navigationController = UIApplication.shared.keyWindow?.rootViewController {
            return navigationController as? UINavigationController
        }
        return nil
    }

}

