//
//  WLEncoderConfig.h
//  WorkLabs
//
//  编码参数（推流 + 录制共用一套）：视频码率 / 关键帧间隔 / 帧率 / 音频码率。
//  由设置窗口「编码」页配置、持久化到 NSUserDefaults；录制器/推流器据此初始化编码器。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WLEncoderConfig : NSObject

@property (nonatomic, assign) int videoBitrate;             // 视频码率 bps；<=0 表示按分辨率自动(w*h*4)
@property (nonatomic, assign) int keyframeIntervalSeconds;  // 关键帧间隔（秒），gop = fps * 该值
@property (nonatomic, assign) int fps;                      // 输出帧率
@property (nonatomic, assign) int audioBitrate;             // AAC 码率 bps

+ (instancetype)defaultConfig;
+ (instancetype)loadFromDefaults;   // 从 NSUserDefaults 读，缺省回退默认值
- (void)saveToDefaults;

// 实际视频码率：videoBitrate>0 用之，否则按分辨率自动(w*h*4)
- (int)effectiveVideoBitrateForWidth:(int)w height:(int)h;

@end

NS_ASSUME_NONNULL_END
