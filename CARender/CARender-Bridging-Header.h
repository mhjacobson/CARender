#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

// Forward-declare the CAPackage SPI.

@interface CAPackage : NSObject

+ (nullable CAPackage *)packageWithContentsOfURL:(NSURL *)url type:(NSString *)type options:(nullable NSDictionary *)options error:(NSError * _Nullable *)error;

@property (nullable, readonly) CALayer *rootLayer;

@end

extern NSString *const kCAPackageTypeArchive;
extern NSString *const kCAPackageTypeCAMLBundle;
extern NSString *const kCAPackageTypeCAMLFile;
