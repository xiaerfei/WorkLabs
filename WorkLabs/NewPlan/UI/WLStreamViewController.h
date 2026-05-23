//
//  WLStreamViewController.h
//  WorkLabs
//
//  推流主界面
//

#import <Cocoa/Cocoa.h>
#import "WLStreamOutputProtocol.h"

NS_ASSUME_NONNULL_BEGIN

@interface WLStreamViewController : NSViewController <WLVideoOutputProtocol>

@end

NS_ASSUME_NONNULL_END
