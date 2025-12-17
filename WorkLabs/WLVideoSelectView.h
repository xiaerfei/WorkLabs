//
//  WLVideoSelectView.h
//  WorkLabs
//
//  Created by TVUM4Pro on 2025/12/17.
//

#import <Cocoa/Cocoa.h>
#import "WLDevicesManager.h"

NS_ASSUME_NONNULL_BEGIN

typedef void(^WLVideoSelectChangedBlock)(WLDeviceItem * _Nullable device,
                                        WLDeviceFormat * _Nullable format,
                                        NSNumber * _Nullable frameRate);

@interface WLVideoSelectView : NSView <NSComboBoxDataSource, NSComboBoxDelegate>
@property(nonatomic, copy) WLVideoSelectChangedBlock onSelectionChanged;

- (void)updateWithDeviceItems:(NSArray <WLDeviceItem *>*)deviceItems;

- (void)setSelectedDeviceByUniqueID:(NSString *)uniqueID;
- (void)setSelectedDeviceByLocalizedName:(NSString *)localizedName;
- (void)setSelectedResolution:(CMVideoDimensions)dimension;
- (void)setSelectedFrameRate:(NSNumber *)frameRate;

@end

NS_ASSUME_NONNULL_END
