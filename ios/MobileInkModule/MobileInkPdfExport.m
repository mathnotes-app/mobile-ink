#import <React/RCTBridgeModule.h>

@interface RCT_EXTERN_MODULE(MobileInkPdfExport, NSObject)

RCT_EXTERN_METHOD(begin:(NSString * _Nullable)sourceUri resolver:(RCTPromiseResolveBlock)resolver rejecter:(RCTPromiseRejectBlock)rejecter)
RCT_EXTERN_METHOD(append:(NSString *)identifier pages:(NSArray<NSDictionary *> *)pages resolver:(RCTPromiseResolveBlock)resolver rejecter:(RCTPromiseRejectBlock)rejecter)
RCT_EXTERN_METHOD(finish:(NSString *)identifier resolver:(RCTPromiseResolveBlock)resolver rejecter:(RCTPromiseRejectBlock)rejecter)
RCT_EXTERN_METHOD(cancel:(NSString *)identifier resolver:(RCTPromiseResolveBlock)resolver rejecter:(RCTPromiseRejectBlock)rejecter)

@end
