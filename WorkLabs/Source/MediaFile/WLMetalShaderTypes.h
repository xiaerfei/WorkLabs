//
//  WLMetalShaderTypes.h
//  WorkLabs
//
//  在 Metal shader(.metal) 与 Objective-C(.m) 之间共享的结构体定义。
//  纯 C，无 ObjC / 无 import，保证两侧内存布局逐字节一致。
//  全部字段为 4 字节标量（float / int32），顺序固定、无 vector 对齐陷阱。
//

#ifndef WLMetalShaderTypes_h
#define WLMetalShaderTypes_h

// 基础视频滤镜参数（filterFragment 的 uniform）。
// 镜像/裁剪在 fragment 内对采样坐标变换；颜色校正在采样后做。
typedef struct {
    int   hMirror;      // 水平镜像 0/1
    int   vMirror;      // 垂直镜像 0/1
    float cropL;        // 各边裁剪比例 0~0.45（左/右/上/下）
    float cropR;
    float cropT;
    float cropB;
    float brightness;   // -1 ~ 1，加法
    float contrast;     //  0 ~ 2，围绕 0.5
    float saturation;   //  0 ~ 2，向 luma 插值
    float hueRadians;   // 色相旋转（弧度）
    int   isYUV;        // 1=NV12 双平面(Y+CbCr) / 0=单纹理 RGB
    int   isFullRange;  // YUV 时：1=full range / 0=video range
} WLFilterParams;

#endif /* WLMetalShaderTypes_h */
