# A stale GCD redraw that destroys the next screen

A minimal Objective-C reproduction of a race in a declarative UI framework:
a redraw that was handed to `dispatch_async(dispatch_get_main_queue(), ...)`
**before** a navigation runs **after** it, finds the new screen's views by
their (reused) tags, and replaces the fresh page with a copy built from stale,
just-cleared data. The user is left on a page full of `N/A` placeholders that
never loads.

Everything is Foundation-only (`SRView` stands in for `UIView`), so it runs with
`swift test` on macOS.

## How to run

**In Xcode (demo app + tests):**

1. Open `Demo/Demo.xcodeproj` (Xcode resolves the local `StaleRedraw` package from the repo root).
2. Pick any iPhone simulator (iOS 17+) and press **Cmd+R**. No signing team is needed for the simulator.
3. Wait for the card to show "Ada / London", then tap **Done (clear + re-enter page)**.
   - **Naive**: about a second later the card is still on `N/A` and the status turns red. The
     log shows two `redraw tag 100` lines that ran after the re-entry, and the stats show two load
     requests skipped as "already in flight": the response went to a page no longer on screen.
   - **Fixed**: the card shows "Ada / London" again. The log shows two `drop stale redraw` lines.
   - Switch the **Naive / Fixed** segment to reset the page with the other redrawer.
   - Scripted run: the app accepts launch arguments `-mode naive|fixed` and `-autorun 1` (taps
     **Done** once after the first load), e.g.
     `xcrun simctl launch booted com.alexeyhatkevich.gcd-stale-redraw-after-navigation.demo -mode fixed -autorun 1`.
     In Xcode, add them under *Edit Scheme > Run > Arguments*.
4. Press **Cmd+U** to run the package tests (`StaleRedrawTests`) on the simulator from the same `Demo` scheme.

**From the command line:** the library is Foundation-only, so `swift test` runs the same tests on macOS:

```bash
swift test
```

## The setup

- Screens are built from a description. Every page build numbers its views
  from a fixed base tag (100, 101, 102, ...) and registers them in a
  tag -> view table.
- Every data-store write notifies observing elements. Each notification
  schedules an async redraw: an `NSOperationQueue` operation that does
  `dispatch_async(main, ^{ rebuild subtree with tag 100 })`.
- A "Done" action writes two keys the page root observes and immediately
  re-enters the same page. Navigation calls `cancelAllOperations` first.

## What goes wrong

1. Both writes enqueue an operation; the operations run at once and put two
   redraw blocks on the main queue.
2. Navigation calls `cancelAllOperations`, which only affects operations that
   have **not started**. The blocks already on the main queue are untouched.
3. The re-entry builds the page again and hands out tags 100, 101, 102 to the
   **new** views.
4. The stale blocks run, look up tag 100, find the new build's root, unregister
   it, and splice in a copy built from the cleared data.
5. The copy's load request is skipped by the "already in flight" guard (the new
   build started it), and the response is delivered to the detached new build.
   The screen stays on placeholders.

## The fix

A `pageBuildGeneration` counter on the registry, incremented by every page
build. The redraw captures the generation when the change is notified and drops
the block if a newer build started before it ran:

```objc
NSUInteger generation = registry.pageBuildGeneration;
[queue addOperationWithBlock:^{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (generation != registry.pageBuildGeneration) return; // departed build
        [registry rebuildSubtreeWithTag:SRBaseTag];
    });
}];
```

## Layout

- `Sources/StaleRedraw/include/StaleRedraw.h` - public API
- `Sources/StaleRedraw/SRPageRegistry.m` - view, data store, request gate, registry
- `Sources/StaleRedraw/SRRedrawer.m` - `SRNaiveRedrawer` (bug) and `SRFixedRedrawer` (fix)
- `Tests/StaleRedrawTests/StaleRedrawTests.swift` - `test_naive_*` tests pin the
  broken behaviour, `test_fixed_*` tests pin the fix
- `Demo/` - UIKit demo app (`project.yml` for XcodeGen, generated `Demo.xcodeproj`)

## Run the tests (command line)

```bash
swift test
```

## License

MIT

Write-up: https://alexeyhatkevich.blogspot.com
