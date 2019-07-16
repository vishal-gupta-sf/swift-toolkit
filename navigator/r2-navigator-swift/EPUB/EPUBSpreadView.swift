//
//  EPUBSpreadView.swift
//  r2-navigator-swift
//
//  Created by Winnie Quinn, Alexandre Camilleri, Mickaël Menu on 8/23/17.
//
//  Copyright 2019 Readium Foundation. All rights reserved.
//  Use of this source code is governed by a BSD-style license which is detailed
//  in the LICENSE file present in the project repository where this source code is maintained.
//

import WebKit
import R2Shared


protocol EPUBSpreadViewDelegate: class {
    
    /// Called before the spread view animates its content (eg. page change in reflowable).
    func spreadViewWillAnimate(_ spreadView: EPUBSpreadView)
    /// Called after the spread view animates its content (eg. page change in reflowable).
    func spreadViewDidAnimate(_ spreadView: EPUBSpreadView)
    
    /// Called when the user tapped on the spread contents.
    func spreadView(_ spreadView: EPUBSpreadView, didTapAt point: CGPoint)
    
    /// Called when the user tapped on an external link.
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnExternalURL url: URL)
    
    /// Called when the user tapped on an internal link.
    func spreadView(_ spreadView: EPUBSpreadView, didTapOnInternalLink href: String)
    
    /// Called when the pages visible in the spread changed.
    func spreadViewPagesDidChange(_ spreadView: EPUBSpreadView)
    
}

class EPUBSpreadView: UIView, TriptychResourceView, Loggable {

    weak var delegate: EPUBSpreadViewDelegate?
    // Location to scroll to in the spread once the pages are loaded.
    var initialLocation: Locator
    let publication: Publication
    let spread: EPUBSpread
    
    let resourcesURL: URL?
    let webView: WebView

    let contentLayout: ContentLayoutStyle
    let readingProgression: ReadingProgression
    let userSettings: UserSettings

    /// If YES, the content will be faded in once loaded.
    let animatedLoad: Bool
    
    let contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]

    weak var activityIndicatorView: UIActivityIndicatorView?
    
    private(set) var progression: Double?

    /// Whether the continuous scrolling mode is enabled.
    var isScrollEnabled: Bool {
        let userEnabled = (userSettings.userProperties.getProperty(reference: ReadiumCSSReference.scroll.rawValue) as? Switchable)?.on ?? false
        // Force-enables scroll when VoiceOver is running.
        return userEnabled || UIAccessibility.isVoiceOverRunning
    }

    private var spreadLoaded = false
    private var sizeObservation: NSKeyValueObservation?

    required init(publication: Publication, spread: EPUBSpread, resourcesURL: URL?, initialLocation: Locator, contentLayout: ContentLayoutStyle, readingProgression: ReadingProgression, userSettings: UserSettings, animatedLoad: Bool = false, editingActions: EditingActionsController, contentInset: [UIUserInterfaceSizeClass: EPUBContentInsets]) {
        self.publication = publication
        self.spread = spread
        self.resourcesURL = resourcesURL
        self.initialLocation = initialLocation
        self.contentLayout = contentLayout
        self.readingProgression = readingProgression
        self.userSettings = userSettings
        self.animatedLoad = animatedLoad
        self.webView = WebView(editingActions: editingActions)
        self.contentInset = contentInset

        super.init(frame: .zero)
        
        isOpaque = false
        backgroundColor = .clear
        
        webView.frame = bounds
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(webView)
        setupWebView()

        sizeObservation = scrollView.observe(\.contentSize, options: .new) { [weak self] scrollView, value in
            guard let self = self, self.spreadLoaded, value.newValue != value.oldValue else {
                return
            }
            self.delegate?.spreadViewPagesDidChange(self)
        }

        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(didTapBackground)))
        
        for script in makeScripts() {
            webView.configuration.userContentController.addUserScript(script)
        }
        registerJSMessages()

        NotificationCenter.default.addObserver(self, selector: #selector(voiceOverStatusDidChange), name: Notification.Name(UIAccessibilityVoiceOverStatusChanged), object: nil)
        
        updateActivityIndicator()
        loadSpread()
    }
    
    deinit {
        sizeObservation = nil  // needs to be deallocated before the scrollView
        NotificationCenter.default.removeObserver(self)
        disableJSMessages()
    }

    func setupWebView() {
        scrollView.alpha = 0
        
        webView.backgroundColor = UIColor.clear
        scrollView.backgroundColor = UIColor.clear
        
        webView.allowsBackForwardNavigationGestures = false

        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        
        if #available(iOS 11.0, *) {
            // Prevents the pages from jumping down when the status bar is toggled
            scrollView.contentInsetAdjustmentBehavior = .never
        }

        webView.navigationDelegate = self
        webView.uiDelegate = self
        scrollView.delegate = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    var scrollView: UIScrollView {
        return webView.scrollView
    }

    override func didMoveToSuperview() {
        super.didMoveToSuperview()
        
        if superview == nil {
            disableJSMessages()
            // Fixing an iOS 9 bug by explicitly clearing scrollView.delegate before deinitialization
            scrollView.delegate = nil
        } else {
            enableJSMessages()
            scrollView.delegate = self
        }
    }
    
    func loadSpread() {
        switch spread {
        case .one(let link):
            guard let url = publication.url(to: link) else {
                log(.error, "Can't get URL for link \(link.href)")
                return
            }
            webView.load(URLRequest(url: url))
        case .two:
            log(.error, "Two-page spreads is not supported with \(type(of: self))")
        }
    }

    /// Evaluates the given JavaScript into the resource's HTML page.
    /// Don't use directly webView.evaluateJavaScript as the resource might be displayed into an iframe in a wrapper HTML page.
    func evaluateScript(_ script: String, inResource href: String, completion: ((Any?, Error?) -> Void)? = nil) {
        webView.evaluateJavaScript(script, completionHandler: completion)
    }
  
    /// Called from the JS code when a tap is detected.
    private func didTap(body: Any) {
        guard let body = body as? [String: Any],
            let point = pointFromTap(body) else
        {
            return
        }

        delegate?.spreadView(self, didTapAt: point)
    }
    
    /// Converts the touch data returned by the JavaScript `tap` event into a point in the webview's coordinate space.
    func pointFromTap(_ data: [String: Any]) -> CGPoint? {
        // To override in subclasses.
        return nil
    }
    
    /// Called by the UITapGestureRecognizer as a fallback tap when tapping around the webview.
    @objc private func didTapBackground(_ gesture: UITapGestureRecognizer) {
        let point = gesture.location(in: self)
        delegate?.spreadView(self, didTapAt: point)
    }

    /// Called by the javascript code when the spread contents is fully loaded.
    /// The JS message `spreadLoaded` needs to be emitted by a subclass script, EPUBSpreadView's scripts don't.
    private func spreadDidLoad(body: Any) {
        spreadLoaded = true

        applyUserSettingsStyle()

        // FIXME: We need to give the CSS and webview time to layout correctly. 0.2 seconds seems like a good value for it to work on an iPhone 5s. Look into solving this better
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            self.go(to: self.initialLocation) {
                self.activityIndicatorView?.stopAnimating()
                UIView.animate(withDuration: self.animatedLoad ? 0.3 : 0, animations: {
                    self.scrollView.alpha = 1
                })
            }
        }
    }
    
    func go(to locator: Locator) {
        go(to: locator, completion: {})
    }

    func go(to locator: Locator, completion: @escaping () -> Void) {
        guard spreadLoaded else {
            // Delays moving to the location until the document is loaded.
            initialLocation = locator
            return
        }

        // FIXME: check that the fragment is actually a tag ID
        if let id = locator.locations?.fragment, !id.isEmpty {
            go(toHref: locator.href, tagID: id, completion: completion)
        } else if let progression = locator.locations?.progression {
            go(toHref: locator.href, progression: progression, completion: completion)
        }
    }

    // Scroll at position 0-1 (0%-100%)
    private func go(toHref href: String, progression: Double, completion: @escaping () -> Void) {
        guard progression >= 0 && progression <= 1 else {
            log(.warning, "Scrolling to invalid progression \(progression)")
            completion()
            return
        }
        
        // Note: The JS layer does not take into account the scroll view's content inset. So it can't be used to reliably scroll to the top or the bottom of the page in scroll mode.
        if isScrollEnabled && [0, 1].contains(progression) {
            var contentOffset = scrollView.contentOffset
            contentOffset.y = (progression == 0)
                ? -scrollView.contentInset.top
                : (scrollView.contentSize.height - scrollView.bounds.height + scrollView.contentInset.bottom)
            scrollView.contentOffset = contentOffset
            completion()
        } else {
            let dir = readingProgression.rawValue
            evaluateScript("readium.scrollToPosition(\'\(progression)\', \'\(dir)\')", inResource: href) { _, _ in completion () }
        }
    }
    
    // Scroll at the tag with id `tagId`.
    private func go(toHref href: String, tagID: String, completion: @escaping () -> Void) {
        evaluateScript("readium.scrollToId(\'\(tagID)\');", inResource: href) { _, _ in completion() }
    }

    enum Direction {
        case left
        case right
    }
    
    func go(to direction: Direction, animated: Bool = false, completion: @escaping () -> Void = {}) -> Bool {
        // The default implementation of a spread view consider that its content is entirely visible on screen.
        return false
    }

    /// Update webview style to userSettings.
    /// To override in subclasses.
    func applyUserSettingsStyle() {
        assert(Thread.isMainThread, "User settings must be updated from the main thread")
    }
    
    
    // MARK: - Progression change
    
    // To check if a progression change was cancelled or not.
    private var previousProgression: Double?

    // Called by the javascript code to notify that scrolling ended.
    private func progressionDidChange(body: Any) {
        guard spreadLoaded, let bodyString = body as? String, let newProgression = Double(bodyString) else {
            return
        }
        if previousProgression == nil {
            previousProgression = progression
        }
        progression = newProgression
    }
    
    @objc private func notifyPagesDidChange() {
        guard previousProgression != progression else {
            return
        }
        previousProgression = nil
        delegate?.spreadViewPagesDidChange(self)
    }
    
    
    // MARK: - Scripts
    
    private static let gesturesScript = loadScript(named: "gestures")
    private static let utilsScript = loadScript(named: "utils")

    class func loadScript(named name: String) -> String {
        return Bundle(for: EPUBSpreadView.self)
            .url(forResource: "Scripts/\(name)", withExtension: "js")
            .flatMap { try? String(contentsOf: $0) }!
    }
    
    func loadResource(at path: String) -> String {
        return (resourcesURL?.appendingPathComponent(path))
            .flatMap { try? String(contentsOf: $0) }!
    }
    
    func makeScripts() -> [WKUserScript] {
        return [
            WKUserScript(source: EPUBSpreadView.gesturesScript, injectionTime: .atDocumentStart, forMainFrameOnly: false),
            WKUserScript(source: EPUBSpreadView.utilsScript, injectionTime: .atDocumentStart, forMainFrameOnly: false)
        ]
    }
    
    
    // MARK: - JS Messages
    
    private var JSMessages: [String: (Any) -> Void] = [:]
    private var JSMessagesEnabled = false

    /// Register a new JS message handler to be emitted from scripts.
    func registerJSMessage(named name: String, handler: @escaping (Any) -> Void) {
        guard JSMessages[name] == nil else {
            log(.error, "JS message already registered: \(name)")
            return
        }
        
        JSMessages[name] = handler
        if JSMessagesEnabled {
            webView.configuration.userContentController.add(self, name: name)
        }
    }
    
    /// To override in subclasses if needed.
    func registerJSMessages() {
        registerJSMessage(named: "tap", handler: didTap)
        registerJSMessage(named: "spreadLoaded", handler: spreadDidLoad)
        registerJSMessage(named: "updateProgression", handler: progressionDidChange)
    }
    
    /// Add the message handlers for incoming javascript events.
    private func enableJSMessages() {
        guard !JSMessagesEnabled else {
            return
        }
        JSMessagesEnabled = true
        for name in JSMessages.keys {
            webView.configuration.userContentController.add(self, name: name)
        }
    }
    
    // Removes message handlers (preventing strong reference cycle).
    private func disableJSMessages() {
        guard JSMessagesEnabled else {
            return
        }
        JSMessagesEnabled = false
        for name in JSMessages.keys {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: name)
        }
    }
    
    
    // MARK: - Accessibility
    
    private var isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
    
    @objc private func voiceOverStatusDidChange() {
        // Avoids excessive settings refresh when the status didn't change.
        guard isVoiceOverRunning != UIAccessibility.isVoiceOverRunning else {
            return
        }
        isVoiceOverRunning = UIAccessibility.isVoiceOverRunning
        // Scroll mode will be activated if VoiceOver is on
        applyUserSettingsStyle()
    }

}

// MARK: - WKScriptMessageHandler for handling incoming message from the javascript layer.
extension EPUBSpreadView: WKScriptMessageHandler {

    /// Handles incoming calls from JS.
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let handler = JSMessages[message.name] else {
            return
        }
        handler(message.body)
    }

}

extension EPUBSpreadView: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Do not remove: overriden in subclasses.
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        var policy: WKNavigationActionPolicy = .allow

        if navigationAction.navigationType == .linkActivated {
            if let url = navigationAction.request.url {
                // Check if url is internal or external
                if let baseURL = publication.baseURL, url.host == baseURL.host {
                    let href = url.absoluteString.replacingOccurrences(of: baseURL.absoluteString, with: "/")
                    delegate?.spreadView(self, didTapOnInternalLink: href)
                } else {
                    delegate?.spreadView(self, didTapOnExternalURL: url)
                }
                
                policy = .cancel
            }
        }

        decisionHandler(policy)
    }
}

extension EPUBSpreadView: UIScrollViewDelegate {
    
    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        scrollView.isUserInteractionEnabled = true
        delegate?.spreadViewDidAnimate(self)
    }
    
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        webView.dismissUserSelection()
    }
    
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        delegate?.spreadViewDidAnimate(self)
    }
    
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        delegate?.spreadViewDidAnimate(self)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        // Makes sure we always receive the "ending scroll" event.
        // ie. https://stackoverflow.com/a/1857162/1474476
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(notifyPagesDidChange), object: nil)
        perform(#selector(notifyPagesDidChange), with: nil, afterDelay: 0.3)
    }

}

extension EPUBSpreadView: WKUIDelegate {
    
    // The property allowsLinkPreview is default false in iOS9, so it should be safe to use @available(iOS 10.0, *)
    @available(iOS 10.0, *)
    func webView(_ webView: WKWebView, shouldPreviewElement elementInfo: WKPreviewElementInfo) -> Bool {
        // Preview allowed only if the link is not internal
        return (elementInfo.linkURL?.host != publication.baseURL?.host)
    }
}

private extension EPUBSpreadView {

    func updateActivityIndicator() {
        guard let appearance = userSettings.userProperties.getProperty(reference: ReadiumCSSReference.appearance.rawValue) as? Enumerable,
            appearance.values.count > appearance.index else
        {
            return
        }
        let value = appearance.values[appearance.index]
        switch value {
        case "readium-night-on":
            createActivityIndicator(style: .white)
        default:
            createActivityIndicator(style: .gray)
        }
    }
    
    func createActivityIndicator(style: UIActivityIndicatorView.Style) {
        guard activityIndicatorView?.style != style else {
            return
        }
        
        activityIndicatorView?.removeFromSuperview()
        let view = UIActivityIndicatorView(style: style)
        view.translatesAutoresizingMaskIntoConstraints = false
        self.addSubview(view)
        view.centerXAnchor.constraint(equalTo: self.centerXAnchor).isActive = true
        view.centerYAnchor.constraint(equalTo: self.centerYAnchor).isActive = true
        view.startAnimating()
        activityIndicatorView = view
    }

}
