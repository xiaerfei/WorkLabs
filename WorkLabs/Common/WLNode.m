//
//  WLNode.m
//  WorkLabs
//
//  NewPlan 数据帧节点（从 Core/Queue/WLNode 扩展）
//

#import "WLNode.h"

@implementation WLNode

- (void)dealloc {
    [self flush];
}

- (void)flush {
    if (_packet) {
        av_packet_free(&_packet);
        _packet = NULL;
    }
    if (_frame) {
        av_frame_free(&_frame);
        _frame = NULL;
    }
    if (_data) {
        CVPixelBufferRelease(_data);
        _data = NULL;
    }
    if (_sampleBuffer) {
        CFRelease(_sampleBuffer);
        _sampleBuffer = NULL;
    }
}

@end
