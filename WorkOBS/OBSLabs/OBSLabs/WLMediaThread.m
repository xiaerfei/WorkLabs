//
//  WLMediaThread.m
//  OBSLabs
//

#import "WLMediaThread.h"
#import "wl_media_thread.h"

@implementation WLMediaThread {
    wl_media_thread_t *_mt;   // 拥有；close/dealloc 时 free
}

- (nullable instancetype)initWithPath:(NSString *)path hwType:(nullable NSString *)hwType {
    self = [super init];
    if (self) {
        // fileSystemRepresentation 正确处理路径编码（优于 UTF8String）
        _mt = wl_media_thread_create(path.fileSystemRepresentation,
                                     hwType.length ? hwType.UTF8String : NULL);
        if (!_mt) return nil;   // ARC 下 return nil：self 被释放
    }
    return self;
}

- (BOOL)start {
    return _mt && wl_media_thread_start(_mt) == 0;
}

- (void)setPaused:(BOOL)paused {
    if (_mt) wl_media_thread_pause(_mt, paused);
}

- (void)seekToMicroseconds:(int64_t)us {
    if (_mt) wl_media_thread_seek(_mt, us);
}

- (void)close {
    if (_mt) {
        wl_media_thread_free(_mt);   // 内部：should_stop + signal + join + 释放
        _mt = NULL;
    }
}

- (void)dealloc {
    [self close];
}

@end
