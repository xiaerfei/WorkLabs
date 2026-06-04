//
//  WLRecorder.h
//  WorkLabs
//
//  mp4 录制 muxer —— 不再自行编码。从共享编码器（WLEncoder）接收已编码的 WLEncodedPacket
//  （微秒时间基），封装为 mp4 文件。延迟到首个视频关键帧才建流写头（用包携带的格式快照），
//  以该关键帧为公共零点，支持「推流中途开录制」。
//

#import <Foundation/Foundation.h>

@class WLEncodedPacket;

NS_ASSUME_NONNULL_BEGIN

@interface WLRecorder : NSObject

@property (atomic, assign, readonly, getter=isRecording) BOOL recording;

// 开始录制到指定 mp4 路径：建 AVFormatContext + 打开文件，进入「等待首个关键帧」状态。
// 真正建流/写头延迟到第一个 isVideo&&isKeyframe 的包（此时 extradata 已随包携带）。
- (BOOL)startToPath:(NSString *)path error:(NSError * _Nullable * _Nullable)error;

// 写入一个编码后的包（来自共享编码器）。内部异步投递到自己的 queue；包是不可变 OC 对象，跨 queue 安全。
- (void)writePacket:(WLEncodedPacket *)packet;

// 停止：异步投递「写 trailer + teardown」到自己的 queue（FIFO 自动排在已投递的写包之后）。
- (void)stop;

// 同上，并在文件写完 trailer + 关闭后于主线程回调 completion（用于「录制完成」提示，避免文件未完成）。
- (void)stopWithCompletion:(nullable void (^)(void))completion;

@end

NS_ASSUME_NONNULL_END
