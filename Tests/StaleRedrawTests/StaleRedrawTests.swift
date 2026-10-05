import XCTest
import StaleRedraw

/// The scenario: a page shows a profile (name + city). The user taps "Done":
/// the action chain clears two keys the page root observes, then immediately
/// re-enters the same page (a full rebuild). Each write schedules an async
/// root redraw: operation queue -> dispatch_async(main) -> rebuild by tag.
@MainActor
final class StaleRedrawTests: XCTestCase {

    private let loadedProfile = [nameKey: "Ada", cityKey: "London"]

    // MARK: - Helpers

    /// A page that has been built and has finished loading its content.
    private func makeLoadedPage(redrawer make: (PageRegistry) -> Redrawer) -> (PageRegistry, Redrawer) {
        let store = DataStore()
        let registry = PageRegistry(store: store)
        let redrawer = make(registry)
        registry.buildPage()
        registry.requests.completeRequest(pageLoadRequest, payload: loadedProfile)
        return (registry, redrawer)
    }

    /// The "Done" chain: two writes the root observes, then re-enter the page.
    private func tapDone(_ registry: PageRegistry, _ redrawer: Redrawer) {
        registry.store.set(nil, forKey: nameKey)
        registry.store.set(nil, forKey: cityKey)
        // The operations are cheap and run immediately on their queue: by the
        // time navigation starts, their dispatch_async(main) blocks are queued.
        redrawer.operationQueue.waitUntilAllOperationsAreFinished()
        // Navigation: cancel pending redraws, then build the page again.
        redrawer.cancelPendingRedraws()
        registry.buildPage()
    }

    /// Lets every block already queued on the main queue run (FIFO).
    private func drainMainQueue() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    // MARK: - Baseline: no navigation, both redrawers work

    // Proves the naive redrawer is correct when nothing rebuilds the page in between.
    func test_naive_redrawWithoutNavigation_showsNewData() {
        let (registry, redrawer) = makeLoadedPage(redrawer: NaiveRedrawer.init(registry:))
        registry.store.set("Grace", forKey: nameKey)
        redrawer.operationQueue.waitUntilAllOperationsAreFinished()
        drainMainQueue()
        XCTAssertEqual(registry.rootView?.text(forDataKey: nameKey), "Grace")
        XCTAssertEqual(redrawer.performedCount, 1)
    }

    // Proves the generation check does not suppress legitimate redraws.
    func test_fixed_redrawWithoutNavigation_showsNewData() {
        let (registry, redrawer) = makeLoadedPage(redrawer: FixedRedrawer.init(registry:))
        registry.store.set("Grace", forKey: nameKey)
        redrawer.operationQueue.waitUntilAllOperationsAreFinished()
        drainMainQueue()
        XCTAssertEqual(registry.rootView?.text(forDataKey: nameKey), "Grace")
        XCTAssertEqual(redrawer.performedCount, 1)
        XCTAssertEqual(redrawer.droppedCount, 0)
    }

    // MARK: - Platform facts the bug relies on

    // Proves cancelAllOperations cannot recall a block an operation already sent to the main queue.
    func test_naive_cancelAllOperations_doesNotRecallBlocksAlreadyOnMainQueue() {
        let (registry, redrawer) = makeLoadedPage(redrawer: NaiveRedrawer.init(registry:))
        registry.store.set("Grace", forKey: nameKey)
        redrawer.operationQueue.waitUntilAllOperationsAreFinished()
        redrawer.cancelPendingRedraws()
        drainMainQueue()
        XCTAssertEqual(redrawer.performedCount, 1, "the redraw ran despite the cancel")
    }

    // Proves cancelAllOperations does help, but only for operations that have not started yet.
    func test_naive_cancelAllOperations_cancelsOperationsNotYetStarted() {
        let (registry, redrawer) = makeLoadedPage(redrawer: NaiveRedrawer.init(registry:))
        redrawer.operationQueue.isSuspended = true
        registry.store.set("Grace", forKey: nameKey)
        redrawer.cancelPendingRedraws()
        redrawer.operationQueue.isSuspended = false
        redrawer.operationQueue.waitUntilAllOperationsAreFinished()
        drainMainQueue()
        XCTAssertEqual(redrawer.performedCount, 0)
    }

    // Proves a tag is not an identity: every build hands out the same tags to new objects.
    func test_tagsAreReusedAcrossBuilds() {
        let (registry, _) = makeLoadedPage(redrawer: NaiveRedrawer.init(registry:))
        let firstRoot = registry.rootView
        registry.buildPage()
        XCTAssertEqual(registry.rootView?.tag, firstRoot?.tag)
        XCTAssertFalse(registry.rootView === firstRoot)
    }

    // MARK: - The bug

    // Proves the late redraw tears down the NEW build: its views are unregistered and off screen.
    func test_naive_staleRedraw_destroysTheNewBuild() {
        let (registry, redrawer) = makeLoadedPage(redrawer: NaiveRedrawer.init(registry:))
        tapDone(registry, redrawer)
        let newBuildRoot = registry.rootView!

        drainMainQueue()

        XCTAssertEqual(redrawer.performedCount, 2, "both stale redraws ran")
        XCTAssertFalse(registry.rootView === newBuildRoot, "new page was replaced by a copy")
        XCTAssertTrue(newBuildRoot.allViews().allSatisfy { !registry.isRegistered($0) },
                      "new build's registrations were stripped")
    }

    // Proves the user ends up stuck on placeholders: the copy's load request is
    // swallowed by de-duplication and the response lands on the detached new build.
    func test_naive_staleRedraw_leavesPageStuckOnPlaceholders() {
        let (registry, redrawer) = makeLoadedPage(redrawer: NaiveRedrawer.init(registry:))
        tapDone(registry, redrawer)
        let newBuildRoot = registry.rootView!
        drainMainQueue()

        XCTAssertEqual(registry.requests.skippedCount, 2, "copies' load requests were de-duplicated away")
        registry.requests.completeRequest(pageLoadRequest, payload: loadedProfile)

        XCTAssertEqual(newBuildRoot.text(forDataKey: nameKey), "Ada", "response went to a view no one sees")
        XCTAssertEqual(registry.rootView?.text(forDataKey: nameKey), placeholderText)
        XCTAssertEqual(registry.rootView?.text(forDataKey: cityKey), placeholderText)
    }

    // MARK: - The fix

    // Proves redraws queued for a departed build are dropped and the new build survives.
    func test_fixed_dropsRedrawsQueuedBeforeNavigation() {
        let (registry, redrawer) = makeLoadedPage(redrawer: FixedRedrawer.init(registry:))
        tapDone(registry, redrawer)
        let newBuildRoot = registry.rootView!

        drainMainQueue()

        XCTAssertEqual(redrawer.performedCount, 0)
        XCTAssertEqual(redrawer.droppedCount, 2)
        XCTAssertTrue(registry.rootView === newBuildRoot)
        XCTAssertTrue(newBuildRoot.allViews().allSatisfy { registry.isRegistered($0) })
        XCTAssertTrue(redrawer.log.allSatisfy { $0.hasPrefix("drop stale redraw") })
    }

    // Proves the page loads normally after the fix: the response reaches the live view.
    func test_fixed_responseReachesTheLivePage() {
        let (registry, redrawer) = makeLoadedPage(redrawer: FixedRedrawer.init(registry:))
        tapDone(registry, redrawer)
        drainMainQueue()

        XCTAssertEqual(registry.requests.skippedCount, 0)
        registry.requests.completeRequest(pageLoadRequest, payload: loadedProfile)
        XCTAssertEqual(registry.rootView?.text(forDataKey: nameKey), "Ada")
        XCTAssertEqual(registry.rootView?.text(forDataKey: cityKey), "London")
    }

    // Proves a change notified AFTER the rebuild still redraws (it belongs to the current build).
    func test_fixed_changeAfterRebuild_isStillRedrawn() {
        let (registry, redrawer) = makeLoadedPage(redrawer: FixedRedrawer.init(registry:))
        tapDone(registry, redrawer)
        registry.requests.completeRequest(pageLoadRequest, payload: loadedProfile)
        registry.store.set("Paris", forKey: cityKey)
        redrawer.operationQueue.waitUntilAllOperationsAreFinished()
        drainMainQueue()

        XCTAssertEqual(redrawer.droppedCount, 2)
        XCTAssertEqual(redrawer.performedCount, 1)
        XCTAssertEqual(registry.rootView?.text(forDataKey: cityKey), "Paris")
    }
}
