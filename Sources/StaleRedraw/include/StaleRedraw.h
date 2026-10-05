// A Foundation-only model of a declarative UI framework that rebuilds screens
// from a data store. No UIKit: SRView stands in for UIView so the race can be
// reproduced with `swift test` on macOS.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Text a label shows when its data key is empty.
FOUNDATION_EXPORT NSString *const SRPlaceholderText NS_SWIFT_NAME(placeholderText);
/// Tag every page build starts numbering from.
FOUNDATION_EXPORT const NSInteger SRBaseTag NS_SWIFT_NAME(baseTag);
/// Identifier of the request a page issues to load its content.
FOUNDATION_EXPORT NSString *const SRPageLoadRequest NS_SWIFT_NAME(pageLoadRequest);
/// Data keys the demo page renders: root (SRBaseTag) > name label (+1), city label (+2).
FOUNDATION_EXPORT NSString *const SRNameKey NS_SWIFT_NAME(nameKey);
FOUNDATION_EXPORT NSString *const SRCityKey NS_SWIFT_NAME(cityKey);

#pragma mark - View

/// Stand-in for UIView: a tag, some text and children.
NS_SWIFT_NAME(View)
@interface SRView : NSObject
@property (nonatomic, readonly) NSInteger tag;
@property (nonatomic, copy, nullable) NSString *text;
/// Data key this view renders (nil for containers).
@property (nonatomic, copy, readonly, nullable) NSString *dataKey;
@property (nonatomic, readonly) NSArray<SRView *> *subviews;
- (instancetype)initWithTag:(NSInteger)tag dataKey:(nullable NSString *)dataKey NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
- (void)addSubview:(SRView *)view;
/// Self plus every descendant, depth first.
- (NSArray<SRView *> *)allViews;
/// Text of the first descendant (or self) bound to `key`.
- (nullable NSString *)textForDataKey:(NSString *)key NS_SWIFT_NAME(text(forDataKey:));
@end

#pragma mark - Data store

@class SRDataStore;

NS_SWIFT_NAME(DataObserver)
@protocol SRDataObserver <NSObject>
- (void)dataStore:(SRDataStore *)store didChangeValueForKey:(NSString *)key;
@end

/// Key-value store; every write notifies observers synchronously on the caller's thread.
NS_SWIFT_NAME(DataStore)
@interface SRDataStore : NSObject
- (nullable NSString *)stringForKey:(NSString *)key NS_SWIFT_NAME(string(forKey:));
- (void)setString:(nullable NSString *)value forKey:(NSString *)key NS_SWIFT_NAME(set(_:forKey:));
- (void)addObserver:(id<SRDataObserver>)observer;
@end

#pragma mark - Requests

/// De-duplicates requests: a request already in flight is not started twice.
/// The response is delivered to the view that started the request.
NS_SWIFT_NAME(RequestGate)
@interface SRRequestGate : NSObject
@property (nonatomic, readonly) NSUInteger skippedCount;
/// Returns NO (and counts a skip) if `requestID` is already in flight.
- (BOOL)startRequest:(NSString *)requestID forView:(SRView *)view;
/// Fills the requesting view's labels from `payload` and clears the in-flight entry.
- (void)completeRequest:(NSString *)requestID payload:(NSDictionary<NSString *, NSString *> *)payload;
@end

#pragma mark - Registry

/// Tag -> view table for the page on screen, plus the build-generation token.
NS_SWIFT_NAME(PageRegistry)
@interface SRPageRegistry : NSObject
@property (nonatomic, readonly) SRDataStore *store;
@property (nonatomic, readonly) SRRequestGate *requests;
/// The page view currently "on screen".
@property (nonatomic, readonly, nullable) SRView *rootView;
/// Incremented by every page build (navigation, re-entry, rotation, theme reload).
@property (nonatomic, readonly) NSUInteger pageBuildGeneration;
@property (nonatomic, readonly) NSUInteger registeredViewCount;

- (instancetype)initWithStore:(SRDataStore *)store NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Builds the page from scratch: bumps the generation, resets tags to SRBaseTag,
/// registers every view, puts the root on screen and starts SRPageLoadRequest.
- (void)buildPage;
- (nullable SRView *)viewWithTag:(NSInteger)tag NS_SWIFT_NAME(view(withTag:));
- (BOOL)isRegistered:(SRView *)view;

/// The redraw body: finds the views by tag, unregisters them, builds a fresh copy
/// from the current store, registers it and splices it in place of the old one.
/// Re-issues SRPageLoadRequest for the copy (subject to de-duplication).
- (void)rebuildSubtreeWithTag:(NSInteger)tag NS_SWIFT_NAME(rebuildSubtree(withTag:));
@end

#pragma mark - Redrawers

/// Observes the store and schedules an async redraw of the page root:
/// operation queue -> dispatch_async(main) -> rebuild by tag.
NS_SWIFT_NAME(Redrawer)
@interface SRRedrawer : NSObject <SRDataObserver>
@property (nonatomic, readonly) SRPageRegistry *registry;
@property (nonatomic, readonly) NSOperationQueue *operationQueue;
@property (nonatomic, readonly) NSUInteger performedCount;
@property (nonatomic, readonly) NSUInteger droppedCount;
@property (nonatomic, readonly) NSArray<NSString *> *log;
- (instancetype)initWithRegistry:(SRPageRegistry *)registry NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
/// What navigation does before building the next page.
- (void)cancelPendingRedraws;
@end

/// Bug: the main-queue block redraws whatever currently owns the tag.
NS_SWIFT_NAME(NaiveRedrawer)
@interface SRNaiveRedrawer : SRRedrawer
@end

/// Fix: captures pageBuildGeneration at notification time and drops the
/// block if a newer build started before it ran.
NS_SWIFT_NAME(FixedRedrawer)
@interface SRFixedRedrawer : SRRedrawer
@end

NS_ASSUME_NONNULL_END
