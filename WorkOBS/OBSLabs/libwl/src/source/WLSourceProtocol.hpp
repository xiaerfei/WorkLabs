//
//  WLSourceProtocol.hpp
//  OBSLabs
//
//  源协议（对齐 OBS obs_source_info 回调面）。
//
//  C++ 纯虚基类 = ObjC @protocol：
//    - 零数据成员、零实现代码（默认空 = @optional）
//    - 实现方只表达"遵守协议"
//    - 壳通过 backend_ 指针调用
//
//  命名规范：对外 PascalCase，内部 camelCase。
//

#ifndef WLSourceProtocol_hpp
#define WLSourceProtocol_hpp

#include <stdint.h>

class WLSourceProtocol {
public:
    virtual ~WLSourceProtocol() {}                    // 必须有：壳 delete backend 需要虚析构

    // ── 必选（= 0）──
    virtual int  Start() = 0;                         // 返回 0 成功
    virtual void Stop()  = 0;                         // 幂等

    // ── 可选（默认空 = @optional）──
    virtual void Pause(bool paused) {}
    virtual void Seek(int64_t seek_ts_us) {}
    virtual void Update(const char *settings) {}

    // ── 信息查询（默认值 = 不支持）──
    virtual int64_t GetDuration() { return -1; }
    virtual int     GetWidth()    { return 0; }
    virtual int     GetHeight()   { return 0; }

    // ── 同步源绘制（M3 占位）──
    virtual void VideoRender() {}
};

#endif /* WLSourceProtocol_hpp */
