//
//  NSView+BackgroundColor.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/11/10.
//

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface NSView (BackgroundColor)
@property (nonatomic, strong) NSColor *backgroundColor;

- (void)backgroundColorWithHexString:(NSString *)hexString;
- (void)backgroundColorWithHex:(NSUInteger)hexValue;
@end

NS_ASSUME_NONNULL_END
