#import "StaleRedraw.h"

@interface SRRedrawer ()
@property (nonatomic, readwrite) NSUInteger performedCount;
@property (nonatomic, readwrite) NSUInteger droppedCount;
- (void)appendLog:(NSString *)line;
@end

@implementation SRRedrawer {
    NSMutableArray<NSString *> *_log;
}

- (instancetype)initWithRegistry:(SRPageRegistry *)registry {
    if ((self = [super init])) {
        _registry = registry;
        _operationQueue = [NSOperationQueue new];
        _operationQueue.maxConcurrentOperationCount = 1;
        _log = [NSMutableArray array];
        [registry.store addObserver:self];
    }
    return self;
}

- (NSArray<NSString *> *)log { return [_log copy]; }

- (void)appendLog:(NSString *)line { [_log addObject:line]; }

- (void)cancelPendingRedraws {
    // Only cancels operations that have not started yet. Blocks an operation
    // already handed to dispatch_async(main) are out of the queue's reach.
    [self.operationQueue cancelAllOperations];
}

- (void)dataStore:(SRDataStore *)store didChangeValueForKey:(NSString *)key {
    [self doesNotRecognizeSelector:_cmd];
}

@end

#pragma mark - Naive

@implementation SRNaiveRedrawer

- (void)dataStore:(SRDataStore *)store didChangeValueForKey:(NSString *)key {
    SRPageRegistry *registry = self.registry;
    [self.operationQueue addOperationWithBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            // Runs a few run-loop turns later. By now the page may have been
            // rebuilt, and SRBaseTag belongs to the NEW build's root.
            [registry rebuildSubtreeWithTag:SRBaseTag];
            self.performedCount += 1;
            [self appendLog:[NSString stringWithFormat:@"redraw tag %ld (change of %@)", (long)SRBaseTag, key]];
        });
    }];
}

@end

#pragma mark - Fixed

@implementation SRFixedRedrawer

- (void)dataStore:(SRDataStore *)store didChangeValueForKey:(NSString *)key {
    SRPageRegistry *registry = self.registry;
    // Capture the build this change belongs to, at notification time.
    NSUInteger generation = registry.pageBuildGeneration;
    [self.operationQueue addOperationWithBlock:^{
        dispatch_async(dispatch_get_main_queue(), ^{
            if (generation != registry.pageBuildGeneration) {
                // A newer build already rendered from current data: dead work.
                self.droppedCount += 1;
                [self appendLog:[NSString stringWithFormat:@"drop stale redraw (change of %@): build %lu, now %lu",
                                 key, (unsigned long)generation, (unsigned long)registry.pageBuildGeneration]];
                return;
            }
            [registry rebuildSubtreeWithTag:SRBaseTag];
            self.performedCount += 1;
            [self appendLog:[NSString stringWithFormat:@"redraw tag %ld (change of %@)", (long)SRBaseTag, key]];
        });
    }];
}

@end
