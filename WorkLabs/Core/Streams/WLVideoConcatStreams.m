//
//  WLVideoConcatStreams.m
//  WorkLabs
//
//  Created by erfeixia on 2026/3/27.
//

#import "WLVideoConcatStreams.h"
#import "WLPushStreamsManager.h"
#import "WLRenderingManager.h"
#import "WLStreamsManager.h"
#import "WLNodeQueue.h"
#include <pthread.h>

#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>


@interface WLVideoConcatStreams ()
@property (nonatomic, strong) NSDictionary <NSNumber * ,WLNodeQueue *> *queueDict;
@property (nonatomic, assign) BOOL rendering;
- (BOOL)isRendering;
- (void)setRendering:(BOOL)rendering;

@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) id<MTLDevice> metalDevice;
@end

@implementation WLVideoConcatStreams {
    pthread_mutex_t _rendering_mutex;
    pthread_mutex_t _wait_mutex;
    pthread_cond_t _wait_cond;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        [self configure];
    }
    return self;
}

- (BOOL)isRendering {
    pthread_mutex_lock(&_rendering_mutex);
    BOOL value = _rendering;
    pthread_mutex_unlock(&_rendering_mutex);
    return value;
}

- (void)setRendering:(BOOL)rendering {
    pthread_mutex_lock(&_rendering_mutex);
    _rendering = rendering;
    pthread_mutex_unlock(&_rendering_mutex);
}

- (void)dealloc {
    pthread_mutex_destroy(&_rendering_mutex);
    pthread_mutex_destroy(&_wait_mutex);
    pthread_cond_destroy(&_wait_cond);
}
#pragma mark - Public Methods
- (void)addNode:(WLNode *)node {
    if (!self.isRendering) {
        [node flush];
        return;
    }
    WLNodeQueue *queue = self.queueDict[@(node.fromType)];
    // 摄像头流使用非阻塞模式（丢弃旧帧策略）
    if (node.fromType == WLFromTypeCamera) {
        [queue enQueueNonBlocking:node];
    } else {
        // 媒体文件流使用阻塞模式
        [queue enQueue:node];
    }
    pthread_mutex_lock(&_wait_mutex);
    pthread_cond_signal(&_wait_cond);
    pthread_mutex_unlock(&_wait_mutex);
}

- (void)startConcat {
    if (self.isRendering) { return; }
    self.rendering = YES;
    [NSThread detachNewThreadSelector:@selector(encoderThread) toTarget:self withObject:nil];
}

- (void)stopConcat {
    self.rendering = NO;
    pthread_mutex_lock(&_wait_mutex);
    pthread_cond_broadcast(&_wait_cond);
    pthread_mutex_unlock(&_wait_mutex);
}
#pragma mark - Thread
- (void)encoderThread {
    static Float64 base_time = 0;
    WLRenderingManager *manager = [WLRenderingManager manager];
    WLStreamsManager *streams = [WLStreamsManager manager];
    while (self.isRendering) {
        pthread_mutex_lock(&_wait_mutex);
        while (self.isRendering && [self allQueueCount] == 0) {
            pthread_cond_wait(&_wait_cond, &_wait_mutex);
        }
        pthread_mutex_unlock(&_wait_mutex);
        
        if (self.isRendering == NO) break;
        
        WLVideoRenderType videoRenderType = streams.videoRenderType;
        switch (videoRenderType) {
            case WLVideoRenderTypeCamera:
            {
                WLNodeQueue *queue = self.queueDict[@(WLFromTypeCamera)];
                WLNode *node = [queue deQueueWithBlock:NO];
                if (node == nil) { break; }
                CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)node.data;
                Float64 current_time = CFAbsoluteTimeGetCurrent();
                if (base_time == 0) {
                    base_time = current_time;
                }
                [manager pixelBuffer:pixelBuffer pts:node.pts];
                [node flush];
                break;
            }
            case WLVideoRenderTypeMedia:
            {
                WLNodeQueue *queue = self.queueDict[@(WLFromTypeMedia)];
                WLNode *node = [queue deQueueWithBlock:NO];
                if (node == nil) { break; }
                CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)node.frame->data[3];
                Float64 current_time = CFAbsoluteTimeGetCurrent();
                if (base_time == 0) {
                    base_time = current_time;
                }
                [manager pixelBuffer:pixelBuffer pts:node.pts];
                [node flush];
                break;
            }
            case WLVideoRenderTypeConcat:
            {
                
                
                
                
                break;
            }
                
            default: break;
        }
    }
    [self doExit];
}
#pragma mark - Pirvate Methods
- (void)configure {
    WLNodeQueue *lqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:4];
    WLNodeQueue *cqueue = [[WLNodeQueue alloc] initWithType:WLNodeTypeVideo size:4];
    self.queueDict = @{
        @(WLFromTypeMedia) : lqueue,
        @(WLFromTypeCamera) : cqueue,
    };
    
    pthread_mutex_init(&_rendering_mutex, NULL);
    pthread_mutex_init(&_wait_mutex, NULL);
    pthread_cond_init(&_wait_cond, NULL);
}

- (NSInteger)allQueueCount {
    NSInteger count = 0;
    for (WLNodeQueue *queue in self.queueDict.allValues) {
        count += queue.count;
    }
    return count;
}

- (void)setVideoRenderType:(WLVideoRenderType)videoRenderType {
    _videoRenderType = videoRenderType;
}

- (void)doExit {
    
}
#pragma mark - Rendering
- (void)setupCIContext {
    // 1. 获取系统默认的 GPU 设备 (Metal)
    self.metalDevice = MTLCreateSystemDefaultDevice();
    
    if (!self.metalDevice) {
        NSLog(@"WLVideoProcessor: 当前设备不支持 Metal");
        return;
    }

    // 2. 配置上下文选项
    // kCIContextWorkingColorSpace: 设置为 [NSNull null] 可以禁用色彩空间转换，提升性能（适合直播流）
    // kCIContextUseSoftwareRenderer: 强制不使用软件渲染
    NSDictionary *options = @{
        kCIContextWorkingColorSpace: [NSNull null],
        kCIContextUseSoftwareRenderer: @(NO),
        kCIContextCacheIntermediates: @(NO) // 实时流建议关闭中间缓存
    };

    // 3. 创建基于 Metal 的 CIContext
    // 这种方式创建的 Context 在渲染 CIImage 到 CVPixelBuffer 时效率最高
    self.ciContext = [CIContext contextWithMTLDevice:self.metalDevice options:options];
    
    NSLog(@"WLVideoProcessor: CIContext 初始化完成 (Metal)");
}

- (CIImage *)createBlackCanvasWithWidth:(CGFloat)width height:(CGFloat)height {
    // 1. 创建纯黑滤镜
    CIFilter *blackGenerator = [CIFilter filterWithName:@"CIConstantColorGenerator"];
    CIColor *black = [CIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:1.0];
    [blackGenerator setValue:black forKey:kCIInputColorKey];
    
    // 2. 裁剪到指定分辨率 (1920x1080)
    CIImage *blackImage = [blackGenerator.outputImage imageByCroppingToRect:CGRectMake(0, 0, width, height)];
    
    return blackImage;
}

- (CIImage *)processPixelBuffer:(CVPixelBufferRef)pixelBuffer
                        toFrame:(CGRect)targetFrame
                   canvasHeight:(CGFloat)canvasHeight {
    if (!pixelBuffer) return nil;

    // 1. 从 Buffer 创建 CIImage
    CIImage *inputImage = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    
    // 2. 计算缩放比例 (将原始 Buffer 缩放到目标 frame 的大小)
    CGFloat scaleX = targetFrame.size.width / inputImage.extent.size.width;
    CGFloat scaleY = targetFrame.size.height / inputImage.extent.size.height;
    
    // 3. 坐标转换逻辑：
    // UI坐标(x, y) 是左上角 -> CI坐标(x, canvasHeight - y - targetHeight) 是左下角
    CGFloat ciOriginY = canvasHeight - targetFrame.origin.y - targetFrame.size.height;
    
    // 4. 应用变换：先缩放，再平移到正确的位置
    CGAffineTransform transform = CGAffineTransformMakeScale(scaleX, scaleY);
    // 注意：CGAffineTransformTranslate 是基于当前缩放后的坐标系，所以位移需除以 scale
    transform = CGAffineTransformTranslate(transform, targetFrame.origin.x / scaleX, ciOriginY / scaleY);
    
    return [inputImage imageByApplyingTransform:transform];
}

- (void)renderCompositionWithCameraBuffer:(CVPixelBufferRef)cameraBuffer
                               cameraFrame:(CGRect)cameraFrame
                               videoBuffer:(CVPixelBufferRef)videoBuffer
                                videoFrame:(CGRect)videoFrame
                            outputBuffer:(CVPixelBufferRef)outputBuffer {
    
    const CGFloat canvasWidth = 1920.0;
    const CGFloat canvasHeight = 1080.0;
    
    // 1. 获取黑色背景
    CIImage *finalImage = [self createBlackCanvasWithWidth:canvasWidth height:canvasHeight];
    
    // 2. 叠加相机层
    CIImage *processedCamera = [self processPixelBuffer:cameraBuffer
                                                toFrame:cameraFrame
                                           canvasHeight:canvasHeight];
    if (processedCamera) {
        finalImage = [processedCamera imageByCompositingOverImage:finalImage];
    }
    
    // 3. 叠加本地视频层 (PiP)
    CIImage *processedVideo = [self processPixelBuffer:videoBuffer
                                               toFrame:videoFrame
                                          canvasHeight:canvasHeight];
    if (processedVideo) {
        finalImage = [processedVideo imageByCompositingOverImage:finalImage];
    }
    
    // 4. 渲染到输出的 PixelBuffer
    // 指定输出区域，确保不会超出 1920x1080
    CGRect renderBounds = CGRectMake(0, 0, canvasWidth, canvasHeight);
    
    [self.ciContext render:finalImage
          toCVPixelBuffer:outputBuffer
                   bounds:renderBounds
               colorSpace:nil]; // 直播流通常不传 colorSpace 以追求性能
}
@end
