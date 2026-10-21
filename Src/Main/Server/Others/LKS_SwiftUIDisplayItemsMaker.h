#ifdef SHOULD_COMPILE_LOOKIN_SERVER
#import <Foundation/Foundation.h>
@class LookinDisplayItem, LookinDisplayItemDetail, LookinStaticAsyncUpdateTask;

@interface LKS_SwiftUIDisplayItemsMaker : NSObject
+ (NSArray<LookinDisplayItem *> *)displayItemsForHostingView:(NSObject *)hostView;
+ (void)populateScreenshotsForItems:(NSArray<LookinDisplayItem *> *)items;
+ (BOOL)isSnapshotObject:(NSObject *)object;
+ (NSError *)modifyStateValue:(id)value identifier:(NSString *)identifier;
+ (LookinDisplayItemDetail *)detailForObject:(NSObject *)object task:(LookinStaticAsyncUpdateTask *)task;
@end
#endif
