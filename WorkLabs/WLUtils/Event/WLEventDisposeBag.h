//
//  WLEventDisposeBag.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLEventDisposeBag : NSObject
- (void)disposeObserve:(id)observe;
- (void)dispose;
@end

NS_ASSUME_NONNULL_END
