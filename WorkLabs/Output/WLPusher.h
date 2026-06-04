//
//  WLPusher.h
//  WorkLabs
//
//  RTMP 推流 muxer —— 不再自行编码。从共享编码器（WLEncoder）接收已编码的 WLEncodedPacket
//  （微秒时间基），用 FLV muxer 推送到 rtmp:// 服务器。结构与 WLRecorder 一致（等首关键帧
//  建流写头 + 公共零点），差异在 FLV/rtmp、异步连接与断流检测。
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@class WLPusher;
@class WLEncodedPacket;

@protocol WLPusherDelegate <NSObject>
@optional
- (void)pusherDidStart:(WLPusher *)pusher;                          // 连接成功、开始推流
- (void)pusher:(WLPusher *)pusher didFailWithError:(NSError *)error; // 连接失败或推流中断
- (void)pusherDidStop:(WLPusher *)pusher;                           // 主动停止完成
@end

@interface WLPusher : NSObject

@property (nonatomic, weak) id<WLPusherDelegate> delegate;
@property (atomic, assign, readonly, getter=isPushing) BOOL pushing;

// 异步连接 rtmp（后台进行，不阻塞调用线程）；结果经 delegate（主线程）回调。
// 连接成功后进入「等待首个关键帧」状态，由 writePacket: 喂入编码后的包。
- (void)startWithURL:(NSString *)url;

// 写入一个编码后的包（来自共享编码器）。内部异步投递到自己的 queue；包是不可变 OC 对象，跨 queue 安全。
- (void)writePacket:(WLEncodedPacket *)packet;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
