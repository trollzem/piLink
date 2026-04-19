#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

// Private CoreGraphics API for creating virtual displays.
// These classes live in CoreGraphics.framework and are discovered at runtime.

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@property (nonatomic, readonly) unsigned int width;
@property (nonatomic, readonly) unsigned int height;
@property (nonatomic, readonly) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property (nonatomic, assign) unsigned int hiDPI;
@property (nonatomic, copy, nullable) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property (nonatomic, strong, nullable) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) dispatch_block_t terminationHandler;
@property (nonatomic, copy, nullable) NSString *name;
@property (nonatomic, assign) unsigned int maxPixelsWide;
@property (nonatomic, assign) unsigned int maxPixelsHigh;
@property (nonatomic, assign) CGSize sizeInMillimeters;
@property (nonatomic, assign) unsigned int productID;
@property (nonatomic, assign) unsigned int vendorID;
@property (nonatomic, assign) unsigned int serialNum;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property (nonatomic, readonly) unsigned int displayID;
@property (nonatomic, readonly) unsigned int hiDPI;
@property (nonatomic, readonly, nullable) NSArray<CGVirtualDisplayMode *> *modes;
@end

NS_ASSUME_NONNULL_END
