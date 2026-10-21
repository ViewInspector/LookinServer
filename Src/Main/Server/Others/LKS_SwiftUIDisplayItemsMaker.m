#ifdef SHOULD_COMPILE_LOOKIN_SERVER
#import "LKS_SwiftUIDisplayItemsMaker.h"
#import "LookinDisplayItem.h"
#import "LookinDisplayItemDetail.h"
#import "LookinStaticAsyncUpdateTask.h"
#import "LookinAttributesGroup.h"
#import "LookinAttributesSection.h"
#import "LookinAttribute.h"
#import "LookinAttrIdentifiers.h"
#import "LookinAttrType.h"
#import "NSObject+LookinServer.h"
#import "LKSConfigManager.h"
#import <objc/runtime.h>
#import <stdlib.h>

#ifdef LOOKIN_SERVER_SWIFT_ENABLED
#if __has_include(<LookinServer/LookinServer-Swift.h>)
#import <LookinServer/LookinServer-Swift.h>
#define LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
#elif __has_include("LookinServer-Swift.h")
#import "LookinServer-Swift.h"
#define LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
#endif
#endif
#ifdef SPM_LOOKIN_SERVER_ENABLED
@import LookinServerSwift;
#define LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
#endif

#ifdef LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
// This must run before SwiftUI builds its first graph. No business View modifiers
// or method swizzling are required. The switch is contained in the debug SDK.
__attribute__((constructor)) static void LKS_EnableSwiftUIRuntimeDebugging(void) {
    if (getenv("LOOKIN_SWIFTUI_DISABLED")) { return; }
    const char *existing = getenv("SWIFTUI_VIEW_DEBUG");
    unsigned long mask = existing ? strtoul(existing, NULL, 0) : 0;
    char value[32];
    snprintf(value, sizeof(value), "%lu", mask | 31UL);
    setenv("SWIFTUI_VIEW_DEBUG", value, 1);
}

@class LKS_SwiftUISnapshot;
@interface LKS_SwiftUIRecord : NSObject
@property(nonatomic, weak) LKS_SwiftUISnapshot *snapshot;
@property(nonatomic, copy) NSString *path;
@property(nonatomic, strong) LKS_SwiftUIViewNode *node;
@property(nonatomic, strong) LookinDisplayItem *item;
@end
@implementation LKS_SwiftUIRecord
@end

@interface LKS_SwiftUISnapshot : NSObject
@property(nonatomic, weak) UIView *host;
@property(nonatomic, strong) NSMutableDictionary<NSString *, LKS_SwiftUIRecord *> *records;
@property(nonatomic, strong) UIImage *image;
@property(nonatomic, strong) LookinDisplayItem *root;
@end
@implementation LKS_SwiftUISnapshot
@end
static char LKS_SwiftUISnapshotKey;
#endif

@implementation LKS_SwiftUIDisplayItemsMaker
+ (NSError *)modifyStateValue:(id)value identifier:(NSString *)identifier {
    NSString *message = @"SwiftUI state editing is unavailable.";
#ifdef LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
    if (NSThread.isMainThread && value && [identifier hasPrefix:@"lookin.swiftui.binding."]) {
        message = [LKS_SwiftUIStateEditor modifyValue:value identifier:identifier];
        if (!message) { return nil; }
    }
#endif
    return [NSError errorWithDomain:@"LookinSwiftUIState" code:1 userInfo:@{NSLocalizedDescriptionKey: message}];
}

+ (NSArray<LookinDisplayItem *> *)displayItemsForHostingView:(NSObject *)hostView {
#ifdef LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
    if (getenv("LOOKIN_SWIFTUI_DISABLED") || !NSThread.isMainThread ||
        ![hostView isKindOfClass:UIView.class] || ![LKS_SwiftUIInspector isSwiftUIHostingView:hostView]) { return nil; }
    UIView *host = (UIView *)hostView;
    LKS_SwiftUISnapshot *snapshot = objc_getAssociatedObject(host, &LKS_SwiftUISnapshotKey);
    if (!snapshot) {
        snapshot = [LKS_SwiftUISnapshot new];
        snapshot.host = host;
        snapshot.records = [NSMutableDictionary dictionary];
        objc_setAssociatedObject(host, &LKS_SwiftUISnapshotKey, snapshot, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [self refresh:snapshot];
    return snapshot.root ? @[snapshot.root] : nil;
#else
    return nil;
#endif
}

+ (void)populateScreenshotsForItems:(NSArray<LookinDisplayItem *> *)items {
#ifdef LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
    if (!NSThread.isMainThread) { return; }
    for (LookinDisplayItem *item in [LookinDisplayItem flatItemsFromHierarchicalItems:items]) {
        NSObject *object = [NSObject lks_objectWithOid:item.layerObject.oid];
        if (item.shouldCaptureImage && [self isSnapshotObject:object] && ((LKS_SwiftUIRecord *)object).node.hasGeometry) {
            UIImage *image = [self imageForRecord:(LKS_SwiftUIRecord *)object];
            item.groupScreenshot = image;
            item.soloScreenshot = image;
            item.screenshotEncodeType = LookinDisplayItemImageEncodeTypeNSData;
        }
    }
#endif
}

+ (BOOL)isSnapshotObject:(NSObject *)object {
#ifdef LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
    return [object isKindOfClass:LKS_SwiftUIRecord.class];
#else
    return NO;
#endif
}

+ (LookinDisplayItemDetail *)detailForObject:(NSObject *)object task:(LookinStaticAsyncUpdateTask *)task {
    LookinDisplayItemDetail *detail = [LookinDisplayItemDetail new];
    detail.displayItemOid = task.oid;
    detail.failureCode = -1;
#ifdef LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
    if (![self isSnapshotObject:object] || !NSThread.isMainThread) { return detail; }
    LKS_SwiftUIRecord *record = (LKS_SwiftUIRecord *)object;
    LKS_SwiftUISnapshot *snapshot = record.snapshot;
    if (!snapshot.host.window || snapshot.records[record.path] != record) { return detail; }
    if (task.needBasisVisualInfo || task.needSubitems) {
        [self refresh:snapshot];
        if (snapshot.records[record.path] != record) { return detail; }
    }
    detail.failureCode = 0;
    detail.attributesGroupList = record.item.attributesGroupList;
    detail.frameValue = [NSValue valueWithCGRect:record.item.frame];
    detail.boundsValue = [NSValue valueWithCGRect:record.item.bounds];
    detail.hiddenValue = @NO;
    detail.alphaValue = @1;
    if (task.needSubitems) { detail.subitems = record.item.subitems ?: @[]; }
    if (task.taskType != LookinStaticAsyncUpdateTaskTypeNoScreenshot && record.node.hasGeometry) {
        UIImage *image = [self imageForRecord:record];
        if (task.taskType == LookinStaticAsyncUpdateTaskTypeSoloScreenshot) {
            // A crop is a composited region, never a fake isolated render layer.
            detail.soloScreenshot = image;
        } else {
            detail.groupScreenshot = image;
        }
    }
#endif
    return detail;
}

#ifdef LOOKIN_SERVER_SWIFT_ENABLED_SUCCESSFULLY
+ (void)refresh:(LKS_SwiftUISnapshot *)snapshot {
    UIView *host = snapshot.host;
    if (!host) { return; }
    [host layoutIfNeeded];
    LKS_SwiftUIViewNode *root = [LKS_SwiftUIInspector swiftUIViewTreeOfHostingView:host];
    snapshot.image = nil;
    if (!root) { snapshot.records = [NSMutableDictionary dictionary]; snapshot.root = nil; return; }
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    snapshot.root = [self itemForNode:root path:@"root" parentOrigin:host.bounds.origin snapshot:snapshot next:next];
    snapshot.records = next; // Releases removed nodes; registry holds only weak references.
    NSArray *fields = [LKS_SwiftUIStateEditor fieldsForHostingView:host];
    NSMutableArray *sections = [NSMutableArray array];
    for (NSDictionary *field in fields) {
        LookinAttribute *attr = [LookinAttribute new];
        attr.identifier = LookinAttr_UserCustom;
        attr.displayTitle = field[@"title"];
        NSString *kind = field[@"valueType"];
        attr.attrType = [kind isEqual:@"bool"] ? LookinAttrTypeBOOL :
            ([kind isEqual:@"number"] ? LookinAttrTypeDouble :
             ([kind isEqual:@"enum"] ? LookinAttrTypeEnumString : LookinAttrTypeNSString));
        attr.value = field[@"value"];
        attr.extraValue = field[@"options"];
        attr.customSetterID = [field[@"editable"] boolValue] ? field[@"identifier"] : nil;
        LookinAttributesSection *section = [LookinAttributesSection new];
        section.identifier = LookinAttrSec_UserCustom;
        section.attributes = @[attr];
        [sections addObject:section];
    }
    if (!sections.count) {
        LookinAttribute *status = [LookinAttribute new];
        status.identifier = LookinAttr_UserCustom;
        status.displayTitle = @"State editing";
        status.attrType = LookinAttrTypeNSString;
        status.value = @"No editable state was found. Enable Debug SwiftUI AOP to inspect unbound @State and model fields; control binding discovery also depends on the system adapter.";
        LookinAttributesSection *section = [LookinAttributesSection new];
        section.identifier = LookinAttrSec_UserCustom;
        section.attributes = @[status];
        [sections addObject:section];
    }
    {
        LookinAttributesGroup *group = [LookinAttributesGroup new];
        group.identifier = LookinAttrGroup_UserCustom;
        group.userCustomTitle = @"SwiftUI State & Models";
        group.attrSections = sections;
        snapshot.root.attributesGroupList = [@[group] arrayByAddingObjectsFromArray:snapshot.root.attributesGroupList];
    }
    if ([LKSConfigManager shouldCaptureScreenshotOfLayer:host.layer] && host.window &&
        host.bounds.size.width > 0 && host.bounds.size.height > 0 &&
        host.bounds.size.width <= 20000 && host.bounds.size.height <= 20000) {
        CGFloat scale = MIN(host.window.screen.scale, 4096 / MAX(host.bounds.size.width, host.bounds.size.height));
        UIGraphicsBeginImageContextWithOptions(host.bounds.size, NO, scale);
        BOOL drawn = [host drawViewHierarchyInRect:(CGRect){CGPointZero, host.bounds.size} afterScreenUpdates:YES];
        if (drawn) { snapshot.image = UIGraphicsGetImageFromCurrentImageContext(); }
        UIGraphicsEndImageContext();
    }
}

+ (LookinDisplayItem *)itemForNode:(LKS_SwiftUIViewNode *)node path:(NSString *)path
                    parentOrigin:(CGPoint)parentOrigin snapshot:(LKS_SwiftUISnapshot *)snapshot
                            next:(NSMutableDictionary *)next {
    LKS_SwiftUIRecord *record = snapshot.records[path];
    if (![record.node.fullTypeName isEqualToString:node.fullTypeName]) { record = nil; }
    if (!record) { record = [LKS_SwiftUIRecord new]; record.path = path; record.snapshot = snapshot; }
    record.node = node;
    next[path] = record;
    LookinDisplayItem *item = [LookinDisplayItem new];
    record.item = item;
    LookinObject *object = [LookinObject new];
    object.oid = [record lks_registerOid];
    object.memoryAddress = @"(SwiftUI runtime snapshot)";
    object.classChainList = @[node.typeName];
    NSString *summary = [node.valueDescription stringByReplacingOccurrencesOfString:@"\n" withString:@" "];
    object.specialTrace = summary.length > 120 ? [[summary substringToIndex:120] stringByAppendingString:@"…"] : summary;
    item.viewObject = object;
    item.layerObject = object; // Existing client detail requests are addressed by layerObject.oid.
    item.frame = CGRectOffset(node.frameInHost, -parentOrigin.x, -parentOrigin.y);
    item.bounds = (CGRect){CGPointZero, node.frameInHost.size};
    item.alpha = 1;
    // This wire flag is a subtree privacy policy in existing clients. Setting it
    // to NO for a layout-less wrapper also suppresses its drawable descendants.
    // Geometry availability is checked when serving each screenshot instead.
    item.shouldCaptureImage = [LKSConfigManager shouldCaptureScreenshotOfLayer:snapshot.host.layer];
    item.attributesGroupList = [self attributesForNode:node];
    NSMutableArray *children = [NSMutableArray array];
    [node.children enumerateObjectsUsingBlock:^(LKS_SwiftUIViewNode *child, NSUInteger idx, BOOL *stop) {
        [children addObject:[self itemForNode:child path:[path stringByAppendingFormat:@"/%lu", (unsigned long)idx]
                                parentOrigin:node.frameInHost.origin snapshot:snapshot next:next]];
    }];
    item.subitems = children;
    return item;
}

+ (UIImage *)imageForRecord:(LKS_SwiftUIRecord *)record {
    LKS_SwiftUISnapshot *snapshot = record.snapshot;
    UIImage *image = snapshot.image;
    CGRect rect = CGRectOffset(record.node.frameInHost, -snapshot.host.bounds.origin.x, -snapshot.host.bounds.origin.y);
    CGRect intersection = CGRectIntersection(rect, (CGRect){CGPointZero, image.size});
    if (!image || CGRectIsNull(intersection) || CGRectIsEmpty(intersection) || rect.size.width > 20000 || rect.size.height > 20000) { return nil; }
    // Preserve the full node bounds, leaving clipped/offscreen areas transparent.
    CGFloat scale = MIN(image.scale, 4096 / MAX(rect.size.width, rect.size.height));
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, scale);
    [image drawAtPoint:CGPointMake(-rect.origin.x, -rect.origin.y)];
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return result;
}

+ (NSArray<LookinAttributesGroup *> *)attributesForNode:(LKS_SwiftUIViewNode *)node {
    NSMutableArray *values = [NSMutableArray arrayWithArray:@[
        @[@"Type", node.fullTypeName], @[@"Geometry", node.geometryDescription],
        @[@"Inspection", @"Snapshot attributes are read-only. Select the SwiftUI root to edit available live bindings; refresh to capture structure changes."],
        @[@"Preview", @"Composited HostingView region; includes overlapping content, not an isolated SwiftUI layer."]]];
    if (node.hasGeometry) { [values addObject:@[@"Bounds in HostingView", NSStringFromCGRect(node.frameInHost)]]; }
    if (node.valueDescription.length) { [values addObject:@[@"Value", node.valueDescription]]; }
    if (node.modifierDescription.length) { [values addObject:@[@"Modifier", node.modifierDescription]]; }
    if (node.attributeDescription.length) { [values addObject:@[@"Runtime attributes", node.attributeDescription]]; }
    NSMutableArray *sections = [NSMutableArray array];
    for (NSArray *pair in values) {
        LookinAttribute *attr = [LookinAttribute new];
        attr.identifier = LookinAttr_UserCustom;
        attr.displayTitle = pair[0]; attr.attrType = LookinAttrTypeNSString; attr.value = pair[1];
        LookinAttributesSection *section = [LookinAttributesSection new];
        section.identifier = LookinAttrSec_UserCustom; section.attributes = @[attr];
        [sections addObject:section];
    }
    LookinAttributesGroup *group = [LookinAttributesGroup new];
    group.identifier = LookinAttrGroup_UserCustom; group.userCustomTitle = @"SwiftUI"; group.attrSections = sections;
    return @[group];
}
#endif
@end
#endif
