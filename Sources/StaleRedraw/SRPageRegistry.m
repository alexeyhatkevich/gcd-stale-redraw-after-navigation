#import "StaleRedraw.h"

NSString *const SRPlaceholderText = @"N/A";
const NSInteger SRBaseTag = 100;
NSString *const SRPageLoadRequest = @"page.load";
NSString *const SRNameKey = @"profile.name";
NSString *const SRCityKey = @"profile.city";

#pragma mark - SRView

@implementation SRView {
    NSMutableArray<SRView *> *_subviews;
}

- (instancetype)initWithTag:(NSInteger)tag dataKey:(NSString *)dataKey {
    if ((self = [super init])) {
        _tag = tag;
        _dataKey = [dataKey copy];
        _subviews = [NSMutableArray array];
    }
    return self;
}

- (NSArray<SRView *> *)subviews { return [_subviews copy]; }

- (void)addSubview:(SRView *)view { [_subviews addObject:view]; }

- (NSArray<SRView *> *)allViews {
    NSMutableArray *all = [NSMutableArray arrayWithObject:self];
    for (SRView *child in _subviews) [all addObjectsFromArray:[child allViews]];
    return all;
}

- (NSString *)textForDataKey:(NSString *)key {
    for (SRView *view in [self allViews]) {
        if ([view.dataKey isEqualToString:key]) return view.text;
    }
    return nil;
}

@end

#pragma mark - SRDataStore

@implementation SRDataStore {
    NSMutableDictionary<NSString *, NSString *> *_values;
    NSHashTable<id<SRDataObserver>> *_observers;
}

- (instancetype)init {
    if ((self = [super init])) {
        _values = [NSMutableDictionary dictionary];
        _observers = [NSHashTable weakObjectsHashTable];
    }
    return self;
}

- (NSString *)stringForKey:(NSString *)key { return _values[key]; }

- (void)setString:(NSString *)value forKey:(NSString *)key {
    _values[key] = value;
    for (id<SRDataObserver> observer in _observers.allObjects) {
        [observer dataStore:self didChangeValueForKey:key];
    }
}

- (void)addObserver:(id<SRDataObserver>)observer { [_observers addObject:observer]; }

@end

#pragma mark - SRRequestGate

@implementation SRRequestGate {
    NSMutableDictionary<NSString *, SRView *> *_inFlight;
}

- (instancetype)init {
    if ((self = [super init])) _inFlight = [NSMutableDictionary dictionary];
    return self;
}

- (BOOL)startRequest:(NSString *)requestID forView:(SRView *)view {
    if (_inFlight[requestID] != nil) {
        _skippedCount += 1;   // "already loading" - the guard that hides the bug
        return NO;
    }
    _inFlight[requestID] = view;
    return YES;
}

- (void)completeRequest:(NSString *)requestID payload:(NSDictionary<NSString *, NSString *> *)payload {
    SRView *requester = _inFlight[requestID];
    [_inFlight removeObjectForKey:requestID];
    for (SRView *view in [requester allViews]) {
        NSString *text = view.dataKey ? payload[view.dataKey] : nil;
        if (text) view.text = text;
    }
}

@end

#pragma mark - SRPageRegistry

@implementation SRPageRegistry {
    NSMutableDictionary<NSNumber *, SRView *> *_viewsByTag;
    NSInteger _nextTag;
}

- (instancetype)initWithStore:(SRDataStore *)store {
    if ((self = [super init])) {
        _store = store;
        _requests = [SRRequestGate new];
        _viewsByTag = [NSMutableDictionary dictionary];
        _nextTag = SRBaseTag;
    }
    return self;
}

- (NSUInteger)registeredViewCount { return _viewsByTag.count; }

- (SRView *)viewWithTag:(NSInteger)tag { return _viewsByTag[@(tag)]; }

- (BOOL)isRegistered:(SRView *)view { return _viewsByTag[@(view.tag)] == view; }

/// Builds root > [name label, city label] from the current store, using
/// the tags handed in by `nextTag` (sequential from `firstTag`).
- (SRView *)makePageStartingAtTag:(NSInteger)firstTag {
    NSInteger tag = firstTag;
    SRView *root = [[SRView alloc] initWithTag:tag++ dataKey:nil];
    for (NSString *key in @[SRNameKey, SRCityKey]) {
        SRView *label = [[SRView alloc] initWithTag:tag++ dataKey:key];
        label.text = [self.store stringForKey:key] ?: SRPlaceholderText;
        [root addSubview:label];
    }
    _nextTag = MAX(_nextTag, tag);
    return root;
}

- (void)registerSubtree:(SRView *)root {
    for (SRView *view in [root allViews]) _viewsByTag[@(view.tag)] = view;
}

- (void)unregisterSubtree:(SRView *)root {
    for (SRView *view in [root allViews]) [_viewsByTag removeObjectForKey:@(view.tag)];
}

- (void)buildPage {
    _pageBuildGeneration += 1;
    [_viewsByTag removeAllObjects];
    _nextTag = SRBaseTag;                       // tags restart: 100, 101, 102 ... again
    SRView *root = [self makePageStartingAtTag:_nextTag];
    [self registerSubtree:root];
    _rootView = root;
    [self.requests startRequest:SRPageLoadRequest forView:root];
}

- (void)rebuildSubtreeWithTag:(NSInteger)tag {
    SRView *old = [self viewWithTag:tag];       // whoever owns this tag *now*
    if (old == nil) return;
    [self unregisterSubtree:old];
    SRView *copy = [self makePageStartingAtTag:tag];
    [self registerSubtree:copy];
    if (old == _rootView) _rootView = copy;     // splice the copy in
    [self.requests startRequest:SRPageLoadRequest forView:copy];
}

@end
