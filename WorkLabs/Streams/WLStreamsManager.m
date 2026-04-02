//
//  WLStreamsManager.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/29.
//

#import "WLStreamsManager.h"
#import "WLVideoConcatStreams.h"
#import "WLAudioMixStreams.h"

@interface WLStreamsManager ()

@property (nonatomic, strong) WLVideoConcatStreams *videoStream;
@property (nonatomic, strong) WLAudioMixStreams *audioStream;

@end

@implementation WLStreamsManager

- (instancetype)init {
    self = [super init];
    if (self) {
        self.videoStream = [[WLVideoConcatStreams alloc] init];
        self.audioStream = [[WLAudioMixStreams alloc] init];
    }
    return self;
}

#pragma mark - Public Methods
+ (instancetype)manager {
    static WLStreamsManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[WLStreamsManager alloc] init];
    });
    return manager;
}


- (void)addVideoNode:(WLDecodeNode *)node {
    [self.videoStream addNode:node];
}

- (void)addAudioNode:(WLDecodeNode *)node {
    [self.audioStream addNode:node];
}

@end
