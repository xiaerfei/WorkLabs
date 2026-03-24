//
//  WLDevicesManager.m
//  WorkLabs
//
//  Created by erfeixia on 2025/11/22.
//

#import "WLDevicesManager.h"
#import <IOKit/audio/IOAudioTypes.h>
#import "NSArray+Function.h"

@implementation WLDeviceFormat

- (NSString *)description {
    return [NSString stringWithFormat:@"dimension:%dx%d frameRate: %@",
            self.dimension.width, self.dimension.height,
            [self.frameRate componentsJoinedByString:@","]];
}

@end

@implementation WLDeviceItem

- (NSString *)description {
    
    NSMutableString *string = [NSMutableString new];
    [string appendFormat:@"mediaType:%@\n", self.mediaType == AVMediaTypeVideo ? @"Video" :@"Audio"];
    [string appendFormat:@"uniqueID: %@\n", self.uniqueID];
    [string appendFormat:@"modelID: %@\n", self.modelID];
    [string appendFormat:@"manufacturer: %@\n", self.manufacturer];
    [string appendFormat:@"localizedName: %@\n", self.localizedName];
    [string appendFormat:@"transportType: %@\n", [self debugWithTransportType:self.transportType]];
    if (self.mediaType == AVMediaTypeVideo) {
        [string appendString:@"format:\n"];
        for (WLDeviceFormat *format in self.formats) {
            [string appendFormat:@"\t%@\n", format.description];
        }        
    }
    return string;
}

- (NSString *)debugWithTransportType:(int32_t)transportType {
    switch (transportType) {
        case kIOAudioDeviceTransportTypeBuiltIn:
            return [NSString stringWithFormat:@"内置设备 (BuiltIn) - 数值: %d\n描述: 设备出厂时集成在主机中（如 Mac FaceTime 相机、iPhone 后置相机）", transportType];
            
        case kIOAudioDeviceTransportTypeUSB:
            return [NSString stringWithFormat:@"USB 连接设备 (USB) - 数值: %d\n描述: 通过 USB 总线连接的外接相机（如 USB 摄像头、USB 采集模块）", transportType];
            
        case kIOAudioDeviceTransportTypePCI:
            return [NSString stringWithFormat:@"PCIe 总线设备 (PCIe) - 数值: %d\n描述: 通过 PCI Express 总线连接（含 Thunderbolt 协议设备，如高端采集卡、Thunderbolt 相机）", transportType];
            
        case kIOAudioDeviceTransportTypeNetwork:
            return [NSString stringWithFormat:@"网络设备 (Network) - 数值: %d\n描述: 通过网络协议传输视频流（如 IP 摄像头、网络流媒体相机）", transportType];
            
        case kIOAudioDeviceTransportTypeHdmi:
            return [NSString stringWithFormat:@"HDMI 输入设备 (HDMI) - 数值: %d\n描述: 通过 HDMI 接口接入的视频源（如 HDMI 采集卡连接的相机、摄像机）", transportType];
            
        case kIOAudioDeviceTransportTypeDisplayPort:
            return [NSString stringWithFormat:@"DisplayPort 输入设备 (DisplayPort) - 数值: %d\n描述: 通过 DP 接口接入的视频源（如 DP 采集卡连接的专业相机）", transportType];
        case kIOAudioDeviceTransportTypeVirtual:
            return [NSString stringWithFormat:@"Virtual 输入设备 (DisplayPort) - 数值: %d\n", transportType];
        case kAudioDeviceTransportTypeUnknown:
            return [NSString stringWithFormat:@"未知类型 (Unknown) - 数值: %d\n描述: 系统无法识别设备的传输类型（如老旧设备、非标准协议设备）", transportType];
            
        default:
            return [NSString stringWithFormat:@"未定义类型 - 数值: %d\n描述: 超出官方定义的 transportType 范围（可能是新系统扩展类型）", transportType];
    }
}
@end

@interface WLDevicesManager ()
@property(nonatomic, strong) RACSubject *videoSubject;
@property(nonatomic, strong) RACSubject *audioSubject;
@end

@implementation WLDevicesManager

+ (instancetype)manager {
    static WLDevicesManager *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [WLDevicesManager new]; });
    return m;
}

- (instancetype)init {
    if (self = [super init]) {
        _videoSubject = [RACSubject subject];
        _audioSubject = [RACSubject subject];
        [self setupNotifications];
    }
    return self;
}

- (RACSignal<WLDeviceItem *> *)videoSignal { return _videoSubject; }
- (RACSignal<WLDeviceItem *> *)audioSignal { return _audioSubject; }

#pragma mark - Device Discovery

- (NSArray<WLDeviceItem *> *)currentVideoDevices {
    AVCaptureDeviceDiscoverySession *session =
    [AVCaptureDeviceDiscoverySession
     discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera,
                                       AVCaptureDeviceTypeExternal]
     mediaType:AVMediaTypeVideo
     position:AVCaptureDevicePositionUnspecified];
    return [self wrapDevices:session.devices mediaType:AVMediaTypeVideo];
}

- (NSArray<WLDeviceItem *> *)currentAudioDevices {
    AVCaptureDeviceDiscoverySession *session =
    [AVCaptureDeviceDiscoverySession
     discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeMicrophone,
                                       AVCaptureDeviceTypeExternal]
     mediaType:AVMediaTypeAudio
     position:AVCaptureDevicePositionUnspecified];
    return [self wrapDevices:session.devices mediaType:AVMediaTypeAudio];
}

#pragma mark - Wrap

- (NSArray<WLDeviceItem *> *)wrapDevices:(NSArray<AVCaptureDevice *> *)devices
                               mediaType:(AVMediaType)mediaType {
    NSMutableArray *arr = [NSMutableArray array];

    for (AVCaptureDevice *d in devices) {
        WLDeviceItem *item = [WLDeviceItem new];
        item.mediaType = mediaType;
        item.uniqueID = d.uniqueID;
        item.modelID = d.modelID;
        item.localizedName = d.localizedName;
        item.manufacturer = d.manufacturer;
        item.transportType = d.transportType;
        item.formats = [self extractFormats:d.formats];
        item.device = d;
        [arr addObject:item];
    }
    return arr;
}

- (NSArray<WLDeviceFormat *> *)extractFormats:(NSArray<AVCaptureDeviceFormat *> *)formats {
    NSMutableArray *arr = [NSMutableArray array];
    for (AVCaptureDeviceFormat *f in formats) {
        CMVideoDimensions dim = CMVideoFormatDescriptionGetDimensions(f.formatDescription);
        WLDeviceFormat *fmt = [arr filter:^BOOL(WLDeviceFormat *obj) {
            return (obj.dimension.width == dim.width &&
                    obj.dimension.height == dim.height);
        }].firstObject;
        BOOL exist = fmt != nil;
        
        if (fmt == nil) {
            fmt = [WLDeviceFormat new];
            fmt.dimension = dim;
        }

        NSMutableArray *fpsList = [NSMutableArray array];
        
        if (fmt.frameRate.count != 0) {
            [fpsList addObjectsFromArray:fmt.frameRate];
        }
        
        
        for (AVFrameRateRange *r in f.videoSupportedFrameRateRanges) {
            if ([fpsList containsObject:@(r.maxFrameRate)]) {
                continue;
            }
            [fpsList addObject:@(r.maxFrameRate)];
        }

        fmt.frameRate = [fpsList sortedArrayUsingSelector:@selector(compare:)];
        if (exist == NO) {
            [arr addObject:fmt];            
        }
    }
    return arr;
}

#pragma mark - Notification

- (void)setupNotifications {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;

    // Device connected
    [nc addObserver:self
           selector:@selector(onDeviceChanged:)
               name:AVCaptureDeviceWasConnectedNotification
             object:nil];

    // Device disconnected
    [nc addObserver:self
           selector:@selector(onDeviceChanged:)
               name:AVCaptureDeviceWasDisconnectedNotification
             object:nil];
}

- (void)onDeviceChanged:(NSNotification *)note {
    AVCaptureDevice *d = note.object;
    AVMediaType type = [d hasMediaType:AVMediaTypeVideo] ? AVMediaTypeVideo : AVMediaTypeAudio;

    NSArray *list = (type == AVMediaTypeVideo) ? [self currentVideoDevices]
                                               : [self currentAudioDevices];

    for (WLDeviceItem *item in list) {
        if ([item.uniqueID isEqualToString:d.uniqueID]) {
            if (type == AVMediaTypeVideo) [_videoSubject sendNext:item];
            else [_audioSubject sendNext:item];
        }
    }
}

@end

