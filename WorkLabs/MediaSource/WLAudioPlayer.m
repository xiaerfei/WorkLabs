//
//  WLAudioPlayer.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/24.
//

#import "WLAudioPlayer.h"
#import <QuartzCore/QuartzCore.h>
#import "WLResample.h"


@interface WLAudioPlayer () {
    AudioUnit _audioUnit;
}

@property (nonatomic, weak) id<MXAudioPlayerDelegate> delegate;

@end

@implementation WLAudioPlayer
- (instancetype)init {
    self = [super init];
    if (self) {
        [self setupAudioUnit];
    }
    return self;
}

- (void)setupAudioUnit {
    // 1. 描述音频组件
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_DefaultOutput; // MacOS 默认输出
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    // 2. 查找并创建实例
    AudioComponent inputComponent = AudioComponentFindNext(NULL, &desc);
    AudioComponentInstanceNew(inputComponent, &_audioUnit);
    
    // 3. 设置音频格式 (假设 FFmpeg 输出为 Packed Float32, 44100Hz, 立体声)
    // 注意：这里的格式必须与你 FFmpeg 解码/重采样后的格式完全一致
    AudioStreamBasicDescription streamFormat;
    streamFormat.mSampleRate = 44100;
    streamFormat.mFormatID = kAudioFormatLinearPCM;
    streamFormat.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
    streamFormat.mFramesPerPacket = 1;
    streamFormat.mChannelsPerFrame = 2;
    streamFormat.mBitsPerChannel = 32;
    streamFormat.mBytesPerPacket = 8; // 4 bytes * 2 channels
    streamFormat.mBytesPerFrame = 8;
    
    AudioUnitSetProperty(_audioUnit,
                         kAudioUnitProperty_StreamFormat,
                         kAudioUnitScope_Input,
                         0,
                         &streamFormat,
                         sizeof(streamFormat));
    
    // 4. 设置回调函数 (渲染回调)
    AURenderCallbackStruct callbackStruct;
    callbackStruct.inputProc = &AudioPlayerCallback;
    callbackStruct.inputProcRefCon = (__bridge void * _Nullable)(self); // 传 self 引用
    
    AudioUnitSetProperty(_audioUnit,
                         kAudioUnitProperty_SetRenderCallback,
                         kAudioUnitScope_Input,
                         0,
                         &callbackStruct,
                         sizeof(callbackStruct));
    
    // 5. 初始化 Audio Unit
    AudioUnitInitialize(_audioUnit);
}

- (void)play {
    AudioOutputUnitStart(_audioUnit);
}

- (void)stop {
    AudioOutputUnitStop(_audioUnit);
}

- (void)destroy {
    [self stop];
    if (_audioUnit) {
        AudioUnitUninitialize(_audioUnit);
        AudioComponentInstanceDispose(_audioUnit);
        _audioUnit = nil;
    }
}

- (void)dealloc {
    [self destroy];
}


// 核心渲染回调：系统需要数据时会调用这里
static OSStatus AudioPlayerCallback(void *inRefCon,
                                    AudioUnitRenderActionFlags *ioActionFlags,
                                    const AudioTimeStamp *inTimeStamp,
                                    UInt32 inBusNumber,
                                    UInt32 inNumberFrames,
                                    AudioBufferList *ioData) {
    
    WLAudioPlayer *player = (__bridge WLAudioPlayer *)inRefCon;
    
    // 初始化缓冲区为 0 (静音)
    for (int i = 0; i < ioData->mNumberBuffers; i++) {
        memset(ioData->mBuffers[i].mData, 0, ioData->mBuffers[i].mDataByteSize);
    }
    
    // --- 关键步骤 ---
    // 这里你应该从你的 FFmpeg 音频队列中读取数据
    // 伪代码如下：
    /*
     uint8_t *buffer = [player.audioQueue popDataWithSize:ioData->mBuffers[0].mDataByteSize];
     if (buffer) {
     memcpy(ioData->mBuffers[0].mData, buffer, ioData->mBuffers[0].mDataByteSize);
     free(buffer);
     }
     */
    
    return noErr;
}
@end
