//
//  WLNode.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/21.
//

#import "WLNode.h"

@implementation WLNode

- (void)dealloc {
    [self flush]; // 彻底释放 FFmpeg 引用计数
}

- (void)flush {
    if (_packet) {
        av_packet_free(&_packet); // 严谨释放
        _packet = NULL;
    }
    if (_frame) {
        av_frame_free(&_frame); // 严谨释放
        _frame = NULL;
    }
}
@end
