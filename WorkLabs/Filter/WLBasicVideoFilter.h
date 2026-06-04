//
//  WLBasicVideoFilter.h
//  WorkLabs
//
//  基础视频滤镜 — 每路源一个，承载 镜像 / 颜色校正 / 裁剪 三类基本调整。
//  作为 perStreamFilter 接在 Source → fork 之前，实时作用于预览 + 合成 + 录制/推流。
//  所有参数为默认值时（isIdentity = YES）直接透传输入帧，零渲染开销。
//

#import <Foundation/Foundation.h>
#import "WLStreamFilterProtocol.h"

NS_ASSUME_NONNULL_BEGIN

// 参数字典键（值均为 NSNumber）。镜像为 bool，其余为 float（单位即滤镜内部单位）。
extern NSString * const WLFilterKeyHMirror;     // BOOL  水平翻转
extern NSString * const WLFilterKeyVMirror;     // BOOL  垂直翻转
extern NSString * const WLFilterKeyBrightness;  // float -1 ~ 1，默认 0
extern NSString * const WLFilterKeyContrast;    // float  0 ~ 2，默认 1
extern NSString * const WLFilterKeySaturation;  // float  0 ~ 2，默认 1
extern NSString * const WLFilterKeyHue;         // float -180 ~ 180（度），默认 0
extern NSString * const WLFilterKeyCropTop;     // float  0 ~ 0.45（比例），默认 0
extern NSString * const WLFilterKeyCropBottom;  // float  0 ~ 0.45
extern NSString * const WLFilterKeyCropLeft;    // float  0 ~ 0.45
extern NSString * const WLFilterKeyCropRight;   // float  0 ~ 0.45

@interface WLBasicVideoFilter : NSObject <WLVideoFilterProtocol>

// 镜像
@property (nonatomic, assign) BOOL hMirror;
@property (nonatomic, assign) BOOL vMirror;

// 颜色校正（CIColorControls + CIHueAdjust）
@property (nonatomic, assign) float brightness;  // -1 ~ 1，默认 0
@property (nonatomic, assign) float contrast;    //  0 ~ 2，默认 1
@property (nonatomic, assign) float saturation;  //  0 ~ 2，默认 1
@property (nonatomic, assign) float hue;         // 色相角度 -180 ~ 180（度），默认 0

// 裁剪（各边裁掉的比例 0 ~ 0.45；左右之和 / 上下之和 < 1）
@property (nonatomic, assign) float cropTop;
@property (nonatomic, assign) float cropBottom;
@property (nonatomic, assign) float cropLeft;
@property (nonatomic, assign) float cropRight;

// 全部为默认值（不改变画面）→ YES
@property (nonatomic, assign, readonly, getter=isIdentity) BOOL identity;

// 参数序列化（与设置 UI / manager 交互）。缺省键按默认值处理。
- (NSDictionary<NSString *, NSNumber *> *)params;
- (void)applyParams:(NSDictionary<NSString *, NSNumber *> *)params;

// 各参数默认值（UI 初始 / 重置用）
+ (NSDictionary<NSString *, NSNumber *> *)defaultParams;

@end

NS_ASSUME_NONNULL_END
