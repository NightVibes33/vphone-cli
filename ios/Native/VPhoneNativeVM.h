#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
NS_ASSUME_NONNULL_BEGIN
@interface VPhoneNativeVM : NSObject
+ (NSString *)capabilitySummary;
- (BOOL)prepareWithBundleURL:(NSURL *)url error:(NSError * _Nullable * _Nullable)error;
- (void)startWithCompletion:(void (^)(NSError * _Nullable))completion;
- (void)connectGuestControlWithCompletion:(void (^)(NSString *status))completion;
- (BOOL)sendHIDPressWithPage:(uint32_t)page usage:(uint32_t)usage;
- (NSString *)serialLogSnapshot;
- (void)listGuestAppsWithCompletion:(void (^)(NSArray<NSDictionary *> * _Nullable apps, NSError * _Nullable error))completion;
- (void)launchGuestApp:(NSString *)bundleID completion:(void (^)(NSString * _Nullable message, NSError * _Nullable error))completion;
- (void)installGuestIPAAtURL:(NSURL *)url
                   progress:(void (^)(uint64_t received, uint64_t total))progress
                 completion:(void (^)(NSString * _Nullable message, NSError * _Nullable error))completion;
- (BOOL)sendTouchWithPhase:(NSInteger)phase x:(double)x y:(double)y;
- (void)captureRealFrameWithCompletion:(void (^)(UIImage * _Nullable image))completion;
- (void)stopWithCompletion:(void (^)(NSError * _Nullable))completion;
@end
NS_ASSUME_NONNULL_END
