// A display of its own for the App Store screenshots: 1920x1200 points at 2x, so the app's
// window captures have a Retina Mac's pixels on a Mac without one. It is there while this
// runs: it prints "ready <name>" and stays until its input closes or it is stopped.
//
// CGVirtualDisplay is not public API (DeskPad and BetterDisplay use it the same way); only
// `make screenshots` builds this, never the app.
//
//   clang -fobjc-arc -framework Foundation -framework CoreGraphics display.m -o display

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain) dispatch_queue_t queue;
@property(retain) NSString *name;
@property unsigned int maxPixelsWide;
@property unsigned int maxPixelsHigh;
@property CGSize sizeInMillimeters;
@property unsigned int productID;
@property unsigned int vendorID;
@property unsigned int serialNum;
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property unsigned int hiDPI;
@property(retain) NSArray *modes;
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly) unsigned int displayID;
@end

static NSString *const name = @"Screenshots";
static const unsigned int width = 1920, height = 1200;

int main(void) {
    @autoreleasepool {
        CGVirtualDisplayDescriptor *descriptor = [CGVirtualDisplayDescriptor new];
        descriptor.queue = dispatch_get_main_queue();
        descriptor.name = name;
        descriptor.maxPixelsWide = width * 2;
        descriptor.maxPixelsHigh = height * 2;
        // A 15-inch panel's size, so the system takes 2x as its native scale.
        descriptor.sizeInMillimeters = CGSizeMake(331, 207);
        descriptor.productID = 0x5853;
        descriptor.vendorID = 0x5849;
        descriptor.serialNum = 1;
        CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:descriptor];
        CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
        settings.hiDPI = 1;
        settings.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:width
                                                                 height:height
                                                            refreshRate:60] ];
        if (display == nil || ![display applySettings:settings]) {
            fprintf(stderr, "No virtual display\n");
            return 1;
        }
        printf("ready %s\n", name.UTF8String);
        fflush(stdout);
        // Gone when the input closes: the script that started it ended, however it ended.
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            char buffer[64];
            while (fgets(buffer, sizeof buffer, stdin) != NULL) {
            }
            exit(0);
        });
        dispatch_main();
    }
}
