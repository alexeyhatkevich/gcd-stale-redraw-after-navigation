import UIKit
import StaleRedraw

/// Hosts the library's page model in UIKit.
///
/// A "profile" page (name + city) loads its content from a fake request.
/// "Tap Done" runs the action chain from the write-up: clear the two keys the
/// page root observes (each write schedules an async redraw), then re-enter
/// the same page at once. Naive: the redraws queued before the re-entry run
/// after it, replace the new page with a copy built from cleared data, and the
/// page never leaves "N/A". Fixed: those redraws are dropped and the page loads.
final class DemoViewController: UIViewController {

    private enum Mode: Int { case naive, fixed }

    private let loadedProfile = [nameKey: "Ada", cityKey: "London"]
    private let responseDelay: TimeInterval = 1.0

    // Model (rebuilt whenever the mode changes)
    private var registry: PageRegistry!
    private var redrawer: Redrawer!
    private var runID = 0

    // UI
    private let modeControl = UISegmentedControl(items: ["Naive", "Fixed"])
    private let explanation = UILabel()
    private let pageCard = UIView()
    private let nameLabel = UILabel()
    private let cityLabel = UILabel()
    private let buildLabel = UILabel()
    private let statusLabel = UILabel()
    private let doneButton = UIButton(type: .system)
    private let resetButton = UIButton(type: .system)
    private let statsLabel = UILabel()
    private let logView = UITextView()

    private var mode: Mode { Mode(rawValue: modeControl.selectedSegmentIndex) ?? .naive }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Stale redraw"
        view.backgroundColor = .systemGroupedBackground
        buildUI()
        resetPage()
    }

    // MARK: - Scenario

    /// Fresh store/registry/redrawer, first page build, content loads.
    private func resetPage() {
        runID += 1
        let store = DataStore()
        registry = PageRegistry(store: store)
        redrawer = mode == .naive ? NaiveRedrawer(registry: registry) : FixedRedrawer(registry: registry)
        registry.buildPage()
        setStatus("Loading page...", color: .secondaryLabel)
        doneButton.isEnabled = false
        render()
        completeLoad(after: responseDelay, run: runID) { [weak self] in
            self?.setStatus("Page loaded. Now tap \"Done\".", color: .secondaryLabel)
            self?.doneButton.isEnabled = true
        }
    }

    /// The "Done" chain: two writes the root observes, then re-enter the page.
    @objc private func tapDone() {
        doneButton.isEnabled = false
        registry.store.set(nil, forKey: nameKey)
        registry.store.set(nil, forKey: cityKey)
        // The operations run at once; their dispatch_async(main) blocks are now queued.
        redrawer.operationQueue.waitUntilAllOperationsAreFinished()
        // Navigation: cancel pending redraws (too late for those blocks), build again.
        redrawer.cancelPendingRedraws()
        registry.buildPage()
        setStatus("Re-entered the page, loading...", color: .secondaryLabel)
        render()

        // The stale main-queue blocks run on the next run-loop turns. Show their effect.
        DispatchQueue.main.async { [weak self] in self?.render() }

        completeLoad(after: responseDelay, run: runID) { [weak self] in
            guard let self else { return }
            let stuck = self.registry.rootView?.text(forDataKey: nameKey) == placeholderText
            if stuck {
                self.setStatus("Stuck on N/A: the response went to a page that is no longer on screen.",
                               color: .systemRed)
            } else {
                self.setStatus("Loaded: the stale redraws were dropped.", color: .systemGreen)
            }
            self.doneButton.isEnabled = true
        }
    }

    /// Fake network: the page-load request completes after `delay`.
    private func completeLoad(after delay: TimeInterval, run: Int, then: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, run == self.runID else { return }
            self.registry.requests.completeRequest(pageLoadRequest, payload: self.loadedProfile)
            self.render()
            then()
        }
    }

    // MARK: - Rendering

    private func render() {
        let root = registry.rootView
        nameLabel.text = "Name: \(root?.text(forDataKey: nameKey) ?? "-")"
        cityLabel.text = "City: \(root?.text(forDataKey: cityKey) ?? "-")"
        let identity = root.map { String(UInt(bitPattern: ObjectIdentifier($0).hashValue) & 0xFFFF, radix: 16) } ?? "-"
        buildLabel.text = "build #\(registry.pageBuildGeneration) - on-screen root tag \(root?.tag ?? 0), object 0x\(identity)"
        statsLabel.text = """
        redraws performed: \(redrawer.performedCount)   dropped: \(redrawer.droppedCount)
        load requests skipped as "already in flight": \(registry.requests.skippedCount)
        """
        logView.text = redrawer.log.isEmpty ? "(no redraws yet)" : redrawer.log.joined(separator: "\n")
    }

    private func setStatus(_ text: String, color: UIColor) {
        statusLabel.text = text
        statusLabel.textColor = color
    }

    @objc private func modeChanged() { resetPage() }
    @objc private func resetTapped() { resetPage() }

    // MARK: - Layout

    private func buildUI() {
        modeControl.selectedSegmentIndex = 0
        modeControl.addTarget(self, action: #selector(modeChanged), for: .valueChanged)

        explanation.numberOfLines = 0
        explanation.font = .preferredFont(forTextStyle: .footnote)
        explanation.textColor = .secondaryLabel
        explanation.text = """
        "Done" clears the two fields (each write queues an async redraw on the main queue) \
        and immediately re-enters the page. Watch the card after the response arrives:
        - Naive: the queued redraws hit the NEW page by its reused tag, replace it with a copy \
        built from cleared data, and the card stays on N/A.
        - Fixed: the redraws carry the build number they were queued for and are dropped; \
        the card shows Ada / London again.
        """

        pageCard.backgroundColor = .secondarySystemGroupedBackground
        pageCard.layer.cornerRadius = 12
        for label in [nameLabel, cityLabel] {
            label.font = .preferredFont(forTextStyle: .title2)
        }
        buildLabel.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        buildLabel.textColor = .tertiaryLabel
        buildLabel.numberOfLines = 0
        let cardStack = UIStackView(arrangedSubviews: [nameLabel, cityLabel, buildLabel])
        cardStack.axis = .vertical
        cardStack.spacing = 6
        cardStack.translatesAutoresizingMaskIntoConstraints = false
        pageCard.addSubview(cardStack)
        NSLayoutConstraint.activate([
            cardStack.topAnchor.constraint(equalTo: pageCard.topAnchor, constant: 16),
            cardStack.bottomAnchor.constraint(equalTo: pageCard.bottomAnchor, constant: -16),
            cardStack.leadingAnchor.constraint(equalTo: pageCard.leadingAnchor, constant: 16),
            cardStack.trailingAnchor.constraint(equalTo: pageCard.trailingAnchor, constant: -16),
        ])

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .subheadline)

        var doneConfig = UIButton.Configuration.filled()
        doneConfig.title = "Done (clear + re-enter page)"
        doneButton.configuration = doneConfig
        doneButton.addTarget(self, action: #selector(tapDone), for: .touchUpInside)

        var resetConfig = UIButton.Configuration.plain()
        resetConfig.title = "Reset"
        resetButton.configuration = resetConfig
        resetButton.addTarget(self, action: #selector(resetTapped), for: .touchUpInside)

        statsLabel.numberOfLines = 0
        statsLabel.font = .monospacedSystemFont(ofSize: 12, weight: .regular)

        logView.isEditable = false
        logView.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        logView.backgroundColor = .secondarySystemGroupedBackground
        logView.layer.cornerRadius = 8

        let stack = UIStackView(arrangedSubviews: [
            modeControl, explanation, pageCard, statusLabel, doneButton, resetButton, statsLabel, logView,
        ])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: guide.topAnchor, constant: 12),
            stack.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -16),
            stack.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -12),
        ])
    }
}
