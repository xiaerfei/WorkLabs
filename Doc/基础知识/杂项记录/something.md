# 音视频技术资料整理

## 一、视频基础与编码标准

### 1.1 视频基础概念

- [零基础，史上最通俗视频编码技术入门](https://segmentfault.com/a/1190000023362309)
- [实时音视频技术基础知识全面盘点](https://segmentfault.com/a/1190000023362309)
- [ffplay 播放器源代码分析](https://cloud.tencent.com/developer/article/1004559)
- [视频和视频帧：H264编码格式整理](https://zhuanlan.zhihu.com/p/71928833)
- [H264 编码分析](https://www.yuque.com/keith-an9fr/aab7xp/vng2pb)
- [关于视频的一些概念](https://www.samirchen.com/video-concept/)
- [音视频笔记｜H264 基础原理介绍](https://www.erenship.com/posts/1db7.html)
- [音视频基础概念：PCM、采样率、位深和比特率](https://blog.rosuh.me/2021-05-26-av-basic-pcm-samplerate-bit-depth-and-bitrate-and-more/)
- [音视频开发之音频基础知识](https://cloud.tencent.com/developer/article/2215365)
- [音视频开发入门：音频基础](https://blog.jianchihu.net/av-develop-audio-basis.html)
- [实时音视频的那些事儿（一）](https://blog.csdn.net/weixin_42684521/article/details/129388459)
- [移动端音视频从零到上手（强烈推荐）](https://www.jianshu.com/p/228b668361bd)
- [视频中为什么需要这么多的颜色空间？](https://xie.infoq.cn/article/eedc456f74d119896e3c8c567)
- [在视频中，颜色空间使用 YUV420 好，还是 YUV444 好？](https://developer.volcengine.com/articles/7175466416382935097)
- [YUV 转 RGB 有哪些重要的点](https://juejin.cn/post/7033237038446936101)
- [音视频面试涨知识（一）](https://juejin.cn/post/7174374017980661791)
- [音视频压缩：H264码流层次结构和NALU详解](https://cloud.tencent.com/developer/article/1746993)
- [音频技术编程概要](https://zhuanlan.zhihu.com/p/687277624)
- [音视频开发中文网（论坛）](https://avmedia.0voice.com/?id=287)
- [实时音视频技术基础知识全面盘点](https://segmentfault.com/a/1190000023362309)

### 1.2 H264 / H265 编码

- [H.264 学习笔记](https://www.nxrte.com/jishu/2422.html)
- [H.264 码流结构和编解码过程](https://www.nxrte.com/jishu/21000.html)
- [H264 的编码帧类型（IDR 帧、I 帧、P 帧或 B 帧）和帧结构](https://www.nxrte.com/jishu/21382.html)
- [音视频压缩：H264 码流层次结构和 NALU 详解](https://cloud.tencent.com/developer/article/1746993)
- [音视频问题汇总 – H264 标准中 u 和 ue 的差别](https://www.nxrte.com/jishu/yinshipin/32270.html)
- [自己动手写 H.264 解码器](https://www.zzsin.com/catalog/write_avc_decoder.html)
- [实现一个 H264 编码器前期准备](https://www.nxrte.com/jishu/36031.html)
- [如何在 H264 码流的 SPS 中获取宽和高信息？](https://www.nxrte.com/jishu/14432.html)
- [H264码流中SPS PPS详解](https://zhuanlan.zhihu.com/p/27896239)
- [H.264基本概念总结之SPS，PPS，SEI](https://pavelhan.vercel.app/2022-03-16-h264-sps-pps-sei)
- [H264码流中 SPS PPS SEI 详解](https://blog.csdn.net/u011425939/article/details/130114706)
- [音视频开发—H264编码【SPS和PPS】](https://juejin.cn/post/7172132096733872158)
- [H264码流中SPS PPS SEI概念及详解](https://blog.csdn.net/huabiaochen/article/details/120321905)
- [H.264流媒体协议格式中的Annex B格式和AVCC格式深度解析](https://blog.csdn.net/romantic_energy/article/details/50508332)
- [【H264】码流结构详解](https://www.cnblogs.com/linuxAndMcu/p/14533228.html)
- [h264结构与码流](https://blog.csdn.net/qq_42330920/article/details/129023341)
- [视频编解码——帧类型](https://blog.csdn.net/qq_28258885/article/details/116156357)
- [H264码流结构](https://blog.csdn.net/qq_34999565/article/details/134916099)
- [【H264/AVC 句法和语义详解】(三)：NALU详解二（EBSP、RBSP与SODB）](https://www.jianshu.com/p/5f89ea2c3a28)
- [Annex-B 和 AVCC](https://stackoverflow.com/questions/24884827/possible-locations-for-sequence-picture-parameter-sets-for-h-264-stream)
- [H264 编码分析](https://www.yuque.com/keith-an9fr/aab7xp/vng2pb)
- [H.264 NALU语法结构](https://blog.csdn.net/newthinker_wei/article/details/8748442)
- [H.264分层结构与码流结构](https://www.cnblogs.com/Lxk0825/p/9925064.html)
- [H.264裸流结构分析](https://catcheroftime.github.io/blog/2021-08/h.264%E8%A3%B8%E6%B5%81%E7%BB%93%E6%9E%84%E5%88%86%E6%9E%90/)
- [码流结构：原来你是这样的H264](http://175.178.58.43/%E6%9E%81%E5%AE%A2%E6%97%B6%E9%97%B4-html/201-250/222-%E6%94%BB%E5%85%8B%E8%A7%86%E9%A2%91%E6%8A%80%E6%9C%AF/03-%E8%A7%86%E9%A2%91%E7%BC%96%E7%A0%81(3%E8%AE%B2)/05%E4%B8%A8%E7%A0%81%E6%B5%81%E7%BB%93%E6%9E%84%EF%BC%9A%E5%8E%9F%E6%9D%A5%E4%BD%A0%E6%98%AF%E8%BF%99%E6%A0%B7%E7%9A%84H264.html)
- [我需要知道：H.264](https://blog.piasy.com/2017/09/22/I-Need-Know-About-H264/index.html)
- [h264 防竞争机制](https://www.cnblogs.com/micoblog/p/13630602.html) / [另一篇](https://blog.csdn.net/yangleo1987/article/details/54838567)
- [H.264学习笔记（图文并茂）](https://www.nxrte.com/jishu/2422.html)
- [图像和流媒体 -- I帧,B帧,P帧,IDR帧的区别](https://blog.csdn.net/qq_29350001/article/details/73770702)
- [如何在H264码流的SPS中获取宽和高信息？](https://www.nxrte.com/jishu/14432.html)
- [基于iOS11的HEVC(H.265)硬编码/硬解码功能开发指南](https://blog.csdn.net/m0_60259116/article/details/124899769)
- [音视频学习–iOS适配H265实战踩坑记](https://www.nxrte.com/jishu/yinshipin/6147.html)
- [说说 FFmpeg 和 H264 视频编解码的那些事](https://www.nxrte.com/jishu/2498.html)
- [HEVC/H265帧类型分析](https://blog.51cto.com/fengyuzaitu/1614985)
- [h26x sps info parse](https://github.com/monktan89/h26x_sps_parse/tree/main)
- [H264 vs H265](https://www.cnblogs.com/wujianming-110117/p/12640533.html)
- [从视频编码谈起，聊聊H264到H265的变化](https://zhuanlan.zhihu.com/p/670796293)
- [视频编码原理简介](https://skywind.me/blog/archives/1566)
- [如何写一个视频编码器演示篇](https://skywind.me/blog/archives/1609)
- [音视频中的码率控制（CBR、VBR、CVBR、FIXQP）](https://blog.csdn.net/qq_28258885/article/details/118891810)
- [FFmpeg h264_mp4toannexb 的重大缺陷](https://mp.weixin.qq.com/s/oxDBUHZQuo4O-SxThJ2sZw)
- [码流格式: Annex-B, AVCC(H.264)与HVCC(H.265), extradata详解](https://blog.csdn.net/yue_huang/article/details/75126155)
- [H.264流媒体协议格式中的Annex B格式和AVCC格式深度解析](https://blog.csdn.net/Romantic_Energy/article/details/50508332)
- [H.264 中的 AnnexB 格式和 AVCC 格式](https://juejin.cn/post/7135092756095401998)
- [极客时间（破解）](http://175.178.58.43/%E6%9E%81%E5%AE%A2%E6%97%B6%E9%97%B4-html/151-200/)

### 1.3 SEI

- [如何理解和使用 SEI（媒体补充增强信息）？](https://www.nxrte.com/jishu/23419.html)
- [SEI 补充增强信息（全网最全 SEI 指南）](https://www.nxrte.com/jishu/10446.html)
- [什么是 H.264 SEI？H.264 SEI 的编码和获取](https://www.nxrte.com/jishu/44484.html)

### 1.4 AV1

- [关于苹果 AV1 支持您需要了解的一切](https://www.nxrte.com/jishu/42456.html)

### 1.5 HDR / SDR

- [Example of converting HDR video to SDR in Android](https://github.com/JonaNorman/HDRSample/tree/main)
- [HDR转SDR实践之旅(一)流程总结](https://juejin.cn/post/7205908717886865469)

---

## 二、FFmpeg 系列

### 2.1 FFmpeg 基础

- [FFmpeg 官方 Demo](https://ffmpeg.org/doxygen/7.0/examples.html)
- [最简单的基于FFmpeg的封装格式处理：视音频分离器简化版](https://blog.csdn.net/leixiaohua1020/article/details/39767055)
- [av_bitstream_filter_filter()](https://blog.csdn.net/m0_37346206/article/details/94029945)
- [AVPacket 的使用记录(初始化、引用、解引用、释放)](https://blog.csdn.net/ihmhm12345/article/details/115507698)
- [深入理解FFmpeg音视频编程：处理封装、解码、播放](https://developer.aliyun.com/article/1467268)
- [FFmpeg视频播放的内存管理](https://juejin.cn/post/6844903698515099656)
- [FFmpeg数据结构：AVPacket解析](https://www.cnblogs.com/wangguchangqing/p/5790705.html)
- [iOS 利用 FFmpeg 解码音频数据并播放](https://xiaodongxie1024.github.io/2019/06/30/20190630_ios_audio_decoder/)
- [iOS 利用 FFmpeg parse 音视频数据流](https://xiaodongxie1024.github.io/2019/06/11/20190611_ios_parseavdata_ffmpeg/)
- [说说 FFmpeg 和 H264 视频编解码的那些事](https://www.nxrte.com/jishu/2498.html)

### 2.2 ffplay 源码分析

- [ffplay.c源码分析与理解](https://github.com/xiaerfei/ffplay-explained)
- [ffplay packet queue 分析](https://zhuanlan.zhihu.com/p/43295650)
- [ffplay源码分析2-数据结构(环形缓冲器)](https://cloud.tencent.com/developer/article/1409508)
- [ffplay 源码分析(结构体有详细的参数说明)](https://www.cnblogs.com/juju-go/p/16489044.html)
- [音视频开发技术(博客 分析 FFMpeg 和 FFplay 相关的结构体和源码)](https://cloud.tencent.com/developer/column/75651)
- [ffplay 视频播放原理分析](https://xie.infoq.cn/article/6e2c7e13db8d1d3f68db70ce0)
- [txp玩Linux(涉及音视频 ffplay、基础知识、心得和源码分析)](https://cloud.tencent.com/developer/column/94726)
- [FFplay源码分析-nobuffer](https://www.bilibili.com/read/cv15950768/)
- [ffplay源码分析6-音频重采样](https://www.cnblogs.com/leisure_chn/p/10312713.html)
- [ffplay.c源码分析【2】](https://www.cnblogs.com/juju-go/p/16500356.html)

---

## 三、播放器技术

### 3.1 ijkplayer

- [官方 GitHub](https://github.com/bilibili/ijkplayer)
- [个人维护版](https://github.com/debugly/ijkplayer)
- [fsplayer](https://github.com/debugly/fsplayer)
- [ijkplayer中遇到的问题汇总](https://juejin.cn/post/6844903694845083655)
- [ijkplayer丢帧的处理方案](https://www.jianshu.com/p/ecf51ee32589)
- [ijkplay播放直播流延时控制小结](https://www.jianshu.com/p/d6a5d8756eec)
- [开源播放器 ijkplayer (二) ：ijkplayer倍速变调问题解决方案](https://www.cnblogs.com/renhui/p/6510872.html)
- [ijkplayer直播播放器使用经验之谈——卡顿优化和秒开实现](https://blog.csdn.net/cmshao/article/details/80149176)
- [Ijkplayer、ExoPlayer、VLC播放器综合比较](https://juejin.cn/post/6956604648476622856)
- [ijkplayer播放卡顿分析(VideoToolBox 出来的解码帧需要排序)](https://zhuanlan.zhihu.com/p/1936582324625080968)
- [视频解码延迟(更进一步分析延迟问题)](https://zhuanlan.zhihu.com/p/1936593615523644821)
- [0.8.8 ios硬解码h264/h265丢帧或失败 #4141](https://github.com/bilibili/ijkplayer/issues/4141)

### 3.2 播放器技术通用

- [播放器技术分享（1）：架构设计](https://blog.51cto.com/ticktick/2324928)
- [播放器技术分享（2）：缓冲区管理](https://blog.51cto.com/ticktick/2326207)
- [播放器技术分享（3）：音画同步](https://blog.51cto.com/ticktick/2328003)
- [播放器技术分享（4）：首开时间](https://blog.51cto.com/ticktick/2334148)
- [播放器技术分享（5）：延时优化](https://blog.51cto.com/ticktick/2339355)
- [从零开始敲一个播放器（002）媒体流解析流程](https://zhuanlan.zhihu.com/p/622260387)
- [倚天屠龙化长虹——音视频与渲染](https://zhuanlan.zhihu.com/p/350594727)
- [如何学习音视频开发?](https://www.zhihu.com/question/325943454)
- [极致首帧播放方案：零首帧解决方案](https://www.infoq.cn/article/S9sDLJR2oWEooJyvt7ro)
- [喜马拉雅直播秒开优化实践](https://www.infoq.cn/article/baJrvmHAWaVQ3BK61dWS)
- ["零耗时"首帧视频体验的优化实践](https://www.infoq.cn/article/YuA5hUImSpPPP46lpmG1)

---

## 四、iOS 音频开发

### 4.1 AudioUnit

- [Audio Unit: iOS 中最底层最强大的音频控制 API](https://zhuanlan.zhihu.com/p/615587742)
- [Audio Unit 工作原理](https://acefish.github.io/15773512971221.html)
- [构造 Audio Unit 应用](https://acefish.github.io/15776919276552.html)
- [深入理解 AudioUnit (一) ~ IO Unit 结构和运行机制](https://xueshi.io/2022/03/12/AudioUnit-01-IOUnit/)
- [深入理解 AudioUnit (二) ~ Mixing Unit & Effect Unit & Converter Unit](https://xueshi.io/2022/03/19/AudioUnit-02-Mixer-and-Effect-Units/)
- [iOS 底层音频处理初步研究](http://masterviva.cn/2020/10/05/AudioUnit-Effect/)
- [AudioUnit](https://www.sunyazhou.com/2018/05/AudioUnit/)
- [AudioUnit 框架详细解析](https://developer.aliyun.com/article/663835)
- [iOS 音频 - AudioUnit（官方文档）](https://juejin.cn/post/6980729874931515399)
- [iOS 音频播放（三）AudioUnit 介绍与实战](https://juejin.cn/post/6844903944930459655)
- [iOS 音频-audioUnit 总结](https://www.jianshu.com/p/f859640fcb33)
- [iOS 音频之 Audio Unit & AudioEngine](https://github.com/zhenshub/WorkNote/blob/master/%E9%9F%B3%E8%A7%86%E9%A2%91%E6%8A%80%E6%9C%AF/iOS%E9%9F%B3%E9%A2%91%E4%B9%8BAudioUnit%26AudioEngine.md)
- [使用 Audio Unit 录制音频](https://github.com/zhonglaoban/AudioUnitRecorder)
- [AudioUnitRecorder Demo](https://github.com/XueshiQiao/AudioUnitSamples/blob/main/AudioUnitSamples/Common/AudioUnitRecorder.mm)
- [AudioUnit 播放FFmpeg解码的音频](https://blog.51cto.com/u_16124099/6328630)
- [Audio Unit Hosting Fundamentals](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitHostingGuide_iOS/AudioUnitHostingFundamentals/AudioUnitHostingFundamentals.html)
- [About Audio Unit Hosting](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioUnitHostingGuide_iOS/Introduction/Introduction.html)
- [AudioToolBox 音频硬编码 AAC](https://juejin.cn/post/7069395297239040037)
- [iOS CoreAudio AudioStreamBasicDescription 音频格式概念简介](https://cloud.tencent.com/developer/article/1873839)
- [互动连麦场景实现：从技术角度解析](https://developer.baidu.com/article/details/2824868)

### 4.2 AVAudioEngine

- [iOS 混音之 AVAudioEngine 详解](https://www.rongcloud.cn/blog/?p=4222)
- [iOS Audio hand by hand: 变声，混响，语音合成 TTS](https://juejin.cn/post/6844903957144272903)
- [AVAudioEngine Tutorial for iOS: Getting Started](https://www.kodeco.com/21672160-avaudioengine-tutorial-for-ios-getting-started)
- [一步一步教你实现iOS音频频谱动画（一）](https://juejin.cn/post/6844903784011792391)
- [一步一步教你实现iOS音频频谱动画（二）](https://juejin.cn/post/6844903791670591495)
- [iOS AVAudioEngine 使用教程](https://blog.csdn.net/Philm_iOS/article/details/81664556)
- [AVFoundation 框架解析（二十七）—— 基于 AVAudioEngine 的简单使用示例](https://www.jianshu.com/p/56ceba2f8a30)
- [【融云分析】iOS 混音之 AVAudioEngine 详解](https://zhuanlan.zhihu.com/p/252852148)
- [Audio API Overview](https://www.objc.io/issues/24-audio/audio-api-overview/)
- [iOS Audio : 变声，混响，语音合成 TTS, AVAudioEngine](https://zhuanlan.zhihu.com/p/85136922)
- [Chrome 中 AVAudioEngine](https://source.chromium.org/chromium/chromium/src/+/main:third_party/tflite_support/src/tensorflow_lite_support/ios/task/audio/core/audio_record/sources/TFLAudioRecord.m)
- [iOS音频---AVAudioEngine(介绍使用方法和例子代码)](https://blog.csdn.net/u014084081/article/details/89142348)
- [Building Modern Audio Apps with AVAudioEngine(PPT)](https://www.slideshare.net/slideshow/building-modern-audio-apps-with-avaudioengine/41630043#1)
- [iOS AVAudioEngine(有代码)](https://www.jianshu.com/p/506c62183763)
- [实现唱吧清唱功能的理解](https://oliverqueen.cn/2018-06-19-MusicAbout/)

### 4.3 AVAudioSession

- [Configuring an Audio Session](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html)
- [AudioSession Programming Guide](https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/Introduction/Introduction.html)
- [iOS 音频-AVAudioSession](https://www.jianshu.com/p/fb0e5fb71b3c)
- [AVAudioSession-Category 各种姿势](https://www.sunyazhou.com/2018/01/AVAudioSessionCategory/)
- [AVAudioSession Programming Guide](https://maxwellqi.github.io/ios-avaudiosession-guide/)
- [iOS AudioSession 详解 Category 选择 听筒扬声器切换](https://blog.51cto.com/u_16124099/6801235)
- [WebRTC 系列之音频会话管理](https://blog.csdn.net/netease_im/article/details/113875029)

### 4.4 音频解码与处理

- [音频解码 Audio Converter](https://www.jianshu.com/p/25188072a11a)
- [音频解码 Audio Converter](https://xiaodongxie1024.github.io/2019/05/19/20190519_AudioDecoder/)
- [音频编码 Audio Converter](https://xiaodongxie1024.github.io/2019/05/15/20190515_audioEncoder/)
- [AudioToolBox 音频硬编码 AAC](https://juejin.cn/post/7069395297239040037)
- [音频之声道那些事 -- PCM 声道](https://www.cnblogs.com/smartNeo/p/14789302.html)
- [视音频数据处理入门：PCM 音频采样数据处理](https://blog.csdn.net/leixiaohua1020/article/details/50534316)
- [PCM音量控制（高级篇）](https://blog.jianchihu.net/pcm-vol-control-advance.html)
- [PCM音量控制](https://blog.jianchihu.net/pcm-volume-control.html)
- [音频左右声道数据合并到一个声道](https://blog.csdn.net/qq_42014563/article/details/107953692)
- [AAC音频基础和ADTS打包方案详解](https://cloud.tencent.com/developer/article/1746985)
- [在线教室 iOS 端声音问题综合解决方案](https://mp.weixin.qq.com/s?__biz=MzI1MzYzMjE0MQ==&mid=2247488032&idx=1&sn=a8e8948fcd043cd0124e8bfe26aa0784)

### 4.5 音频播放

- [iOS 音频播放（三）：AudioFileStream](https://msching.github.io/blog/2014/07/09/audio-in-ios-3/)
- [AudioQueue 知识](https://www.jianshu.com/p/ed6d0862bd0d)
- [AudioStreamer](https://github.com/mattgallagher/AudioStreamer)
- [DOUAudioStreamer - 豆瓣开源的播放器](https://github.com/douban/DOUAudioStreamer)
- [AudioQueue 实现音频流实时播放实战](https://xiaodongxie1024.github.io/2019/06/29/20190629_ios_audioqueue_player/)
- [Audio File 音频文件录制（AudioQueue, AudioUnit, AudioConverter 音频来源）](https://xiaodongxie1024.github.io/2019/05/11/20190511_audioFile_record/)
- [Audio Queue 多种格式支持采集音频实战](https://xiaodongxie1024.github.io/2019/05/11/20190511_AudioQueue_capture/)
- [Audio Queue Services Programming Guide](https://developer.apple.com/library/archive/documentation/MusicAudio/Conceptual/AudioQueueProgrammingGuide/AboutAudioQueues/AboutAudioQueues.html)
- [iOS 端音频的采集与播放](https://xie.infoq.cn/article/b8c110b4c6d696b05a7c2f22c)
- [iOS 采集录制音视频 API 选择推荐](https://xiaodongxie1024.github.io/2019/05/11/20190511_AudioSelect/)
- [Audio Unit 采集音频实战](https://xiaodongxie1024.github.io/2019/05/11/20190511_AudioUnit_capture/)
- [音视频开发之音频基础知识](https://cloud.tencent.com/developer/article/2215365)

### 4.6 音频变速变调与特效

- [音频变速变调 - sonic 源码分析](https://xie.infoq.cn/article/d71ced957347f6f70f3c0775d)
- [音频变速变调原理及 soundtouch 代码分析](https://xie.infoq.cn/article/6c522d10615dfaa4abe6df4f6)
- [音频均衡器 EQ](https://xie.infoq.cn/article/7d89f0251237cc6b8ce740e77)
- [增益和音量的关系](http://erji.net/forum.php?mod=viewthread&tid=2159506&page=2)
- [音频增益会影响声音大小吗](http://www.erji.net/forum.php?mod=viewthread&tid=2173604)

### 4.7 其他音频资源

- [Audiokit](https://www.audiokit.io/)
- [SFBAudioEngine](https://github.com/sbooth/SFBAudioEngine)

---

## 五、iOS 视频开发

### 5.1 VideoToolbox

- [iOS VideoToolbox 硬编指南](https://www.nxrte.com/jishu/4368.html)
- [使用 VideoToolbox 探索低延迟视频编码 | WWDC 演讲实录](https://www.cnblogs.com/wangyiyunxin/p/14923220.html)
- [WebRTC Native 源码导读（九）：iOS 视频硬编码实现分析](https://blog.piasy.com/2018/05/04/WebRTC-iOS-HW-Encode-Video/index.html)
- [iOS视频编码实战VideoToolbox](https://juejin.cn/post/6844903853800816647)
- [iOS-VideoToolbox硬编码H264](https://www.cnblogs.com/tangyuanby2/p/11449460.html)
- [videotoolbox 硬解 H264 annexb](https://blackox.cn/2023/12/07/videotoolbox-%E7%A1%AC%E8%A7%A3-H264-annexb/)
- [iOS VideoToolBox decoder解码失败（-12909和-12911）问题解决](https://www.cnblogs.com/jiayayao/p/9575186.html)
- [iOS VideoToolBox decoder解码失败（-12909和-12911）问题解决（二）](https://www.cnblogs.com/jiayayao/p/15764315.html)
- [H264解码过滤花屏视频帧](https://cloud.tencent.com/developer/article/2039391)
- [iOS VideoToolBox 解码 HEVC Open-GOP 视频的问题排查](https://blog.csdn.net/zhying719/article/details/137157038)
- [How to use VideoToolbox to decompress H.264 video stream](https://stackoverflow.com/questions/29525000/how-to-use-videotoolbox-to-decompress-h-264-video-stream)
- [音视频教程-第二节](https://glumes.com/video-lesson-2/)
- [基于iOS11的HEVC(H.265)硬编码/硬解码功能开发指南](https://blog.csdn.net/m0_60259116/article/details/124899769)
- [音视频学习–iOS适配H265实战踩坑记](https://www.nxrte.com/jishu/yinshipin/6147.html)

### 5.2 音视频编辑

- [Cabbage 音视频编辑器](https://github.com/VideoFlint/Cabbage)
- [iOS 视频编辑核心架构](https://github.com/VideoFlint/Cabbage/wiki/%E4%B8%AD%E6%96%87%E8%AF%B4%E6%98%8E)
- [AVFoundation Programming Guide](https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/00_Introduction.html)
- [WWDC 2013 Session 612: Advanced Editing with AV Foundation](https://developer.apple.com/videos/play/wwdc2013/612/)
- [WWDC 2012 Session 517: Real-Time Media Effects and Processing during Playback](https://developer.apple.com/videos/play/wwdc2012/517/)
- [Apple AVFoundation 文档](https://developer.apple.com/av-foundation/)
- [AVFoundation Document](https://developer.apple.com/documentation/avfoundation?language=objc)
- [Apple Developer Documentation](https://developer.apple.com/documentation?language=objc)

**推荐书籍：**
- [《Learning AV Foundation》](https://www.amazon.com/Learning-Foundation-Hands-Mastering-Framework/dp/0321961803)
- 中文《AVFoundation 开发秘籍》

**推荐应用：**
- [猫饼 (Cabbage)](https://github.com/VideoFlint/Cabbage)
- [Videoleap](https://www.videoleap.com/)

**参考文章：**
- [短视频这么火，微视的特效是怎么做的？](https://www.infoq.cn/article/t0kvcqyhtehfvty5eyql)
- [视频清晰度优化指南 | 得物技术](https://mp.weixin.qq.com/s/YHfAjr_MG_N7nGLtrLEFEw)

### 5.3 AVFoundation 学习

- [iOSPrinciple_AVFoundation](https://github.com/ReverseScale/iOSPrinciple_AVFoundation)
- [AVFoundation 框架解析](https://developer.aliyun.com/article/663875)
- [iOS 音频采集、转换和播放](https://xie.infoq.cn/article/b8c110b4c6d696b05a7c2f22c)

### 5.4 iOS 相机相关

- [相机拍摄新变化(系统温度等级获取)](https://juejin.cn/post/7105945841629823012)
- [AVCaptureOutput 的前世今生](https://juejin.cn/post/7037076601594478629)

### 5.5 iOS 组件化 / UI

- [有赞移动 iOS 组件化（模块化）架构设计实践](https://tech.youzan.com/you-zan-ioszu-jian-hua-jia-gou-she-ji-shi-jian/)
- [iOS组件二进制源码调试热切换方案](https://anyhong.com/archives/debug-with-sourcecode)
- [ObjectiveUI：使用Objective-C实现类似SwiftUI的界面开发框架](https://juejin.cn/post/7078934919874871327)
- [关于Objective-C版本的SwiftUI库的自动生成布局的研究心得](https://joserccblog.github.io/post/guan-yu-objective-c-ban-ben-de-swiftui-ku-de-zi-dong-sheng-cheng-bu-ju-de-yan-jiu-xin-de/)

---

## 六、WebRTC

- [WebRTC 源码分析（8）- 拥塞控制（上）- 码率预估](https://www.cnblogs.com/ishen/p/15249678.html)
- [WebRTC 源码分析汇总](https://www.cnblogs.com/ishen/category/1619028.html)
- [WebRTC Native 源码导读](https://blog.piasy.com/tags/index.html#WebRTC)
- [WebRTC 源码分析（博主 list）](https://chensongpoixs.github.io/tags/?tag=WebRTC)
- [WebRTC 源码分析（4）- 视频发送流程](https://www.cnblogs.com/ishen/p/15154959.html)
- [WebRTC 源码分析起步](https://blog.csdn.net/ababab12345/article/details/119834031)
- [WebRTC TURN 协议源码分析](https://justme0.com/archive/turn.html)
- [WebRTC 的音视频如何同步](https://www.fanyamin.com/blog/webrtc-de-yin-shi-pin-ru-he-tong-bu.html)
- [WebRTC Native 源码导读（九）：iOS 视频硬编码实现分析](https://blog.piasy.com/2018/05/04/WebRTC-iOS-HW-Encode-Video/index.html)
- [WebRTC 源码的目录结构](https://www.bytezonex.com/archives/0J0eSAbe.html)
- [WebRTC架构分析 源码目录结构介绍](https://zhuanlan.zhihu.com/p/81361664)
- [B 站 WebRTC 测试实践](https://www.nxrte.com/jishu/webrtc/40585.html)
- [WebRTC 系列之音频的那些事](https://worktile.com/kb/p/5925)
- [WebRTC 开发（九）音频采集与渲染](https://depthlove.github.io/2019/12/17/webrtc-development-9-audio-capture-and-render/)
- [剑痴乎的博客(WebRTC 相关)](https://blog.jianchihu.net/)
- [音频采集与播放（AudioRecord与AudioTrack）最全笔记](https://juejin.cn/post/7286307632192356411)
- [WebRTC本地音频回调、选用音频采集设备及自定义输入音频](https://blog.csdn.net/weixin_39343678/article/details/99948451)
- [音视频通信为什么要选择WebRTC](https://blog.avdancedu.com/b363212d/)
- [WebRTC IOS视频硬编码流程及其中传递的CVPixelBufferRef](https://www.jianshu.com/p/a27930e722c1)
- [DTLS协议中client/server的认证过程和密钥协商过程](https://blog.csdn.net/pengkunlun_hit/article/details/52177227)
- [WebRTC源码分析之IOS Audio Unit](https://www.jianshu.com/p/e86380eca764)
- [WebRTC 混音分析](https://www.jianshu.com/p/eeb5ea6ef097)
- [游戏实时语音解决方案是怎么炼成的](https://blog.csdn.net/zego_0616/article/details/78803475)
- [深入探究音视频开源库WebRTC中NetEQ音频抗网络延时与抗丢包的实现机制](https://developer.volcengine.com/articles/7317915600867557430)
- [Chrome audio_encoder.cc](https://source.chromium.org/chromium/chromium/src/+/main:media/cast/encoding/audio_encoder.cc)
- [WebRTC 系列之音频会话管理](https://blog.csdn.net/netease_im/article/details/113875029)
- [Piasy - WebRTC 系列博客](https://blog.piasy.com/index.html)
- [loyinglin - LearnVideoToolBox 音视频 Demo](https://github.com/loyinglin/LearnVideoToolBox/tree/master)

---

## 七、直播技术

- [【音视频】OBS原理分析](https://keenjin.github.io/2020/03/obs%E5%8E%9F%E7%90%86%E8%A7%A3%E6%9E%90/)
- [obs音视频同步方法](https://www.jianshu.com/p/999aeccba3c0)
- [obs视频采集源码分析](https://jiantaofu.github.io/2015/07/12/obs%E8%A7%86%E9%A2%91%E9%87%87%E9%9B%86%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90/)
- [如何开发出一款仿映客直播 APP 项目实践篇 - 原理篇](https://www.jianshu.com/p/b2674fc2ac35)
- [视频直播的技术原理和实现思路方案整理](https://github.com/f2e-journey/xueqianban/issues/61)
- [移动端实时音视频直播技术详解（一）：开篇](https://www.cnblogs.com/laughingQing/p/10312707.html)
- [移动端实时音视频直播技术详解（五）：推流和传输](http://www.52im.net/thread-967-1-1.html)
- [移动直播技术知多少：基础原理解析 & 腾讯云直播接入](https://cloud.tencent.com/developer/article/1623467)
- [视频直播技术干货(十二)：从入门到放弃，快速学习Android端直播技术](http://www.52im.net/thread-4714-1-1.html)
- [视频直播技术大全、直播架构、技术原理和实现思路方案整理](https://blog.csdn.net/zgpeace/article/details/108552358)
- [移动端实时视频直播技术实践：如何做到实时秒开、流畅不卡](https://blog.csdn.net/yinshipin007/article/details/126444195)
- [Android实现直播功能（全过程，超详细/附源码）](https://blog.csdn.net/weixin_52263647/article/details/123923603)
- [移动端实时音视频直播技术详解（三）：处理](https://www.sohu.com/a/343022920_120122487)
- [做一套像映客的直播App？看我就够了](https://cloud.tencent.com/developer/article/1140940)
- [LiveVideoCoreSDK(直播推流开源框架)](https://github.com/runner365/LiveVideoCoreSDK)
- [技术福利：最全实时音视频开发要用到的开源工程汇总](https://cloud.tencent.com/developer/article/1198404)
- [LFLiveKit](https://github.com/LaiFengiOS/LFLiveKit/tree/master)
- [实战：超低延时直播技术的落地实践](https://www.infoq.cn/article/r3J9F7CtFJyljwQWwl79)
- [抖音世界杯直播的低延迟是怎么做到的？](https://www.infoq.cn/article/S2Zh7B2P0V1xtZVXYAvv)

---

## 八、流媒体协议与传输

- [DASH 流媒体协议 —— Dynamic Adaptive Streaming over HTTP](https://www.cnblogs.com/farewellyi/p/16801567.html)
- [DASH、HLS和MP4格式有什么播放体验区别？](https://support.huaweicloud.com/vod_faq/vod080002.html)
- [SRS - 为何DASH是个很烂的直播协议](https://ossrs.net/lts/zh-cn/blog/why-dash-is-bad-solution-for-live-streaming)
- [iOS端播放DASH协议视频流，实现类似Ytb、bilibili的无缝切换清晰度效果](https://www.bilibili.com/read/cv16133939/)
- [我们为什么使用DASH](https://www.bilibili.com/read/cv855111/)
- [FLV：不许动手动脚](https://blog.csdn.net/Tomascn/article/details/103602901)
- [StreamEye](http://www.streameye.com/)
- [Web 性能权威指南（High Performance Browser Networking）](https://hpbn.co/)
- [视频直播技术干货：一文读懂主流视频直播系统的推拉流架构、传输协议等](https://cloud.tencent.com/developer/article/2013841)

---

## 九、音视频同步

- [深入聊聊音视频同步](https://zhuanlan.zhihu.com/p/832217090)
- [快速音视频同步-RFC6501](https://zhuanlan.zhihu.com/p/557441630)
- [WebRTC音视频同步](https://zhuanlan.zhihu.com/p/346004563)
- [ITU-R BT.1359 音视频同步国际标准](https://www.itu.int/dms_pubrec/itu-r/rec/bt/R-REC-BT.1359-1-199811-I!!PDF-E.pdf)
- [vlc源码分析（五） 流媒体的音视频同步](https://www.cnblogs.com/jiayayao/p/6890882.html)
- [WebRTC 的音视频如何同步](https://www.fanyamin.com/blog/webrtc-de-yin-shi-pin-ru-he-tong-bu.html)
- [时间戳 音视频同步](https://www.cnblogs.com/my_life/articles/6842155.html)
- [ExoPlayer 中的音频时间戳计算](https://blog.csdn.net/chituhuan/article/details/125515305)

---

## 十、OBS

- [OBS Studio's documentation](https://docs.obsproject.com/)
- [【音视频】OBS原理分析](https://keenjin.github.io/2020/03/obs%E5%8E%9F%E7%90%86%E8%A7%A3%E6%9E%90/)
- [obs-studio入门到放弃](https://blog.csdn.net/qq_33844311/category_11493642.html)
- [OBS 架构体系 obs平台](https://blog.51cto.com/u_16213691/11043747)
- [OBS-Studio(26.0.2)源码分析](https://www.cnblogs.com/Haijunzhu/p/14443768.html)
- [obs 系列分析博客](https://blog.csdn.net/u014162133/category_8827150.html)
- [obs音视频同步方法](https://www.jianshu.com/p/999aeccba3c0)
- [obs视频采集源码分析](https://jiantaofu.github.io/2015/07/12/obs%E8%A7%86%E9%A2%91%E9%87%87%E9%9B%86%E6%BA%90%E7%A0%81%E5%88%86%E6%9E%90/)

---

## 十一、图形渲染与特效

### 11.1 图形渲染 / Shader

- [构建和使用自己的 Shader 炫酷特效](https://www.zzsin.com/shaderplus.html)
- [【UE4没意思啊】从入门到入坟](https://zhuanlan.zhihu.com/p/196363738)
- [veImageX 演进之路：iOS 高性能图片加载 SDK](https://developer.volcengine.com/articles/7238813685727100965)

### 11.2 特效

- [FULiveDemo（Faceunity 面部跟踪、美颜、Animoji等）](https://github.com/Faceunity/FULiveDemo)
- [超分开源项目 Real-ESRGAN](https://github.com/xinntao/Real-ESRGAN)

---

## 十二、计算机基础

### 12.1 C++

- [深入浅出c++协程](https://www.cnblogs.com/ishen/p/14617708.html)
- [C++ 随笔](https://www.cnblogs.com/ishen/category/1603530.html)
- [Lewis Baker's C++ Coroutine Blog](https://lewissbaker.github.io/)
- [C++20 Coroutines Complete Guide](https://itnext.io/c-20-coroutines-complete-guide-7c3fc08db89d)
- [STL map, hash_map, unordered_map区别、对比](https://blog.csdn.net/haluoluo211/article/details/80877558)
- [C++ 学习（cpp 一些知识和知名大学计算机系开源课程收录）](https://github.com/chengxumiaodaren/cpp-learning)
- [C++ 教程网址](https://www.studycpp.cn/basic/chapter1/variable-init-assign/)

### 12.2 协程

- [nju M2 参考资料 - libco](https://github.com/phoulx/nju-os-workbench/blob/main/M2%20-%20libco/README.md)
- [nju Lab 参考资料](https://github.com/vdack/njuOS)
- [有栈协程与无栈协程](https://mthli.xyz/stackful-stackless/)
- [有栈协程 vs. 无栈协程](https://ruststack.org/stackless-coroutine/)
- [有栈协程和无栈协程](https://www.ibyte.me/42.html)
- [浅谈有栈协程与无栈协程](https://github.com/0voice/cpp_backend_awsome_blog/blob/main/%E3%80%90NO.349%E3%80%91%E6%B5%85%E8%B0%88%E6%9C%89%E6%A0%88%E5%8D%8F%E7%A8%8B%E4%B8%8E%E6%97%A0%E6%A0%88%E5%8D%8F%E7%A8%8B.md)
- [初识协程](https://chuquan.me/2021/05/05/getting-to-know-coroutine/)
- [有栈协程和无栈协程](https://cloud.tencent.com/developer/article/1888257)
- [C++20协程原理和应用](https://www.cnblogs.com/Netsharp/p/17279750.html)
- [c++无栈协程为什么会比有栈协程性能高?](https://www.zhihu.com/question/538436096)
- [C++20协程原理和应用](https://blog.csdn.net/csdnnews/article/details/124123024)
- [Python 的协程实现属于有栈还是无栈协程？](https://www.zhihu.com/question/320424555/answer/653576288)
- [万字好文：从无栈协程到C++异步框架！](https://juejin.cn/post/7163829883238350856)
- [async_simple无栈协程和有栈协程的定量分析](http://www.purecpp.cn/detail?id=2318)
- [破解 Kotlin 协程（13）：协程的几类常见的实现](https://www.bennyhuo.com/2019/12/01/coroutine-implementations/)
- [C：实现一个迷你无栈协程框架——Minico](https://www.less-bug.com/posts/c-implement-a-mini-stackless-coroutine-framework-minico/)
- [从无栈协程，到 Asio 的协程实现](https://www.bluepuni.com/archives/stackless-coroutine-and-asio-coroutine/)
- [再探 C++20 协程](https://sf-zhou.github.io/coroutine/cpp_20_explore_coroutines.html)
- [C++ Coroutine in Action](http://blog.gerryyang.com/c/c++/2023/08/02/cpp-coroutine-in-action.html)
- [协程介绍：原理与应用](https://shawn.thisis.host/2024/intro-of-coroutine/)
- [从汇编角度理解 "函数调用栈" 和 "有栈协程"](https://www.yigegongjiang.com/2023/stackForFunc/)
- [C++11 里也能玩无栈协程了？](http://www.purecpp.cn/detail?id=2414)

### 12.3 ELF

- [深入分析ELF文件结构及其载入过程](https://blog.csdn.net/weixin_46222091/article/details/108645592)
- [深入ELF文件结构](https://cs.pynote.net/sf/c/cdm/202111232/)
- [ELF文件结构详解](https://bbs.kanxue.com/thread-255670.htm)
- [计算机那些事(4)——ELF文件结构](https://chuquan.me/2018/05/21/elf-introduce/)
- [第 4 章：深入理解 ELF 文件格式](https://weichao.io/5dcfb5b9f13c/)
- [ELF文件基本结构](https://ciphersaw.me/ctf-wiki/executable/elf/elf_structure/)
- [ELF文件结构描述](https://www.cnblogs.com/linhaostudy/p/8855238.html)
- [ELF文件可执行栈的深入分析](https://mudongliang.github.io/2015/10/23/elf.html)
- [逆向分析：ELF文件的组成结构](https://developer.aliyun.com/article/1206965)
- [ELF 文件](https://ctf-wiki.org/executable/elf/structure/basic-info/)
- [ELF 文件格式分析](https://garlicspace.com/2019/06/11/elf-%E6%96%87%E4%BB%B6%E6%A0%BC%E5%BC%8F%E5%88%86%E6%9E%90/)
- [含大量图文解析及例程 | Linux下的ELF文件、链接、加载与库（上）](https://cloud.tencent.com/developer/article/2058294)
- [ELF 格式简述 - eBPF基础知识 Part1](https://blog.mygraphql.com/zh/notes/low-tec/elf/elf-format/)
- [linux系统的ELF文件解析（二）](https://juejin.cn/post/7355763456082624552)
- [ELF文件格式（一）](https://mp.weixin.qq.com/s?__biz=MzkzNzI0MDMxNQ==&mid=2247487115&idx=1&sn=d3e3160c7ea40f2465f545dffc68f01f&source=41#wechat_redirect)
- [《编译系统-自底向上研究方法》ELF格式简介](https://www.xianwaizhiyin.net/?p=2179)

### 12.4 计算机网络

- [深入理解TCP协议-从原理到实战](https://tf2jaguar.github.io/understand-tcp-in-depth.html)
- [TCP协议灵魂之问](https://tf2jaguar.github.io/net-protocol-tcp.html)
- [通过实验深入了解 TCP 数据的发送和接收](https://developer.aliyun.com/article/1611047)
- [【CS144 fa20 笔记】手摸手教你写一个TCP协议](https://blog.csdn.net/weixin_44179892/article/details/110675514)
- [CS144 笔记](https://zhuanlan.zhihu.com/p/382380361)
- [用了TCP协议，就一定不会丢包吗？](https://developer.aliyun.com/article/1317894)
- [网络包的内核漂流记 Part 1 - 图解网络包接收流程](https://blog.mygraphql.com/zh/notes/low-tec/network/kernel-net-stack/)

### 12.5 Swift

- [闲话 Swift 协程（0）：前言](https://www.bennyhuo.com/2021/10/11/swift-coroutines-00-foreword/)

---

## 十三、工具与资源

### 13.1 视频质量评估

- [VMAF 开源项目](https://github.com/Netflix/vmaf)
- [揭秘 VMAF 视频质量评测标准](https://xie.infoq.cn/article/26aaf2ab83f56192a65ba22ea)
- [Netflix VMAF 视频质量评估工具概述](https://zhuanlan.zhihu.com/p/94223056)
- [B帧对视频清晰度/码率的影响（VIP）](https://blog.csdn.net/matrix_laboratory/article/details/82726897)
- [B帧对视频清晰度/码率的影响（Free）](https://blog.csdn.net/TyearLin/article/details/130882363)

### 13.2 Ring Buffer

- [ring buffer，一篇文章讲透它？](https://juejin.cn/post/7113550346835722276) / [另一篇](https://zhuanlan.zhihu.com/p/534098236)
- [Ring Buffer 的应用(云风的 BLOG)](https://blog.codingnow.com/2012/02/ring_buffer.html)
- [Ring Buffer 原理](https://blog.csdn.net/xiandang8023/article/details/126511818)
- [一种极致性能的缓冲队列](https://heapdump.cn/article/2983398)
- [DPDK Ring 库](https://dpdk-docs.readthedocs.io/en/latest/prog_guide/ring_lib.html)

### 13.3 z-lib

- [z-library](https://z-library.sk/s/Introduction%20to%20Probability)

### 13.4 学习资源

- [CS自学指南](https://csdiy.wiki/)
- [CS自学指南 GitHub](https://github.com/PKUFlyingPig/cs-self-learning)
- [《深入理解计算机系统》中文电子版（原书第 3 版）与实验材料](https://hansimov.gitbook.io/csapp)

### 13.5 Windows 激活

- [知乎](https://www.zhihu.com/question/57942172)
- [Microsoft Activation Scripts (MAS)](https://github.com/massgravel/Microsoft-Activation-Scripts)

---

## 十四、博客与社区

- [掘金 - blackstar666](https://juejin.cn/user/255551407668360/posts)
- [博客园 - blackstar666](https://home.cnblogs.com/u/smartNeo/)
- [blackstar666 博客园 - 音频](https://www.cnblogs.com/smartNeo/category/1977258.html)
- [音视频技术 - 知乎](https://www.zhihu.com/column/avtec)
- [音视频编解码自学篇 - 知乎](https://www.zhihu.com/column/c_1629631086241153024)
- [殷文杰 - CSDN](https://yinwenjie.blog.csdn.net/?type=blog)
- [缥缈峰 - 知乎](https://www.zhihu.com/people/liu-sheng-71-36/posts)
- [剑痴乎的博客](https://blog.jianchihu.net/)
- [Piasy's Blog](https://blog.piasy.com/index.html)

---

## 十五、待解决问题

### 重采样缓冲区不足问题

处理当 `outData` 不足以容纳重采样出来的数据时，会丢失数据或者 crash：

```objc
uint8_t **inData = inputFrame->extended_data ? inputFrame->extended_data : inputFrame->data;
uint8_t *outData[AV_NUM_DATA_POINTERS] = {0};
outData[0] = (uint8_t *)outBuffer->mAudioData;
////TODO: 处理当 outData 不足以容纳重采样出来的数据时，会丢失数据或者crash
// 执行重采样
int samplesConverted = swr_convert(_swrContext,
                                   outData,
                                   availableOutFrames,
                                   (const uint8_t **)inData,
                                   inputFrame->nb_samples);
```

当 `availableOutFrames` 不足以容纳重采样输出时：
- 数据丢失：超出缓冲区的样本会被丢弃
- 音频卡顿：连续丢帧会导致播放不连贯
- 同步问题：PTS 时间戳计算会出错

---

## 附录：代码片段

### AudioUnit 创建 IO Unit

```c
// 创建 IO Unit
AudioComponentDescription io_unit_description;
io_unit_description.componentType = kAudioUnitType_Output;
io_unit_description.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
io_unit_description.componentManufacturer = kAudioUnitManufacturer_Apple;
io_unit_description.componentFlags = 0;
io_unit_description.componentFlagsMask = 0;
```

疑问：
1. componentType 如何配置
2. componentSubType 如何配置

### 立体声转单声道

```c
- (int)convertStereoToMono:(int16_t *)stereo_data size:(int)stereo_size mono:(int16_t *)mono {
    if (stereo_size % 2 != 0) {
        return -1;
    }
    int mono_size = stereo_size / 2;
    for (int i = 0; i < stereo_size / 4 ; i++) {
        mono[i] = stereo_data[2*i];
    }
    return mono_size;
}
```

### AudioStreamBasicDescription 示例

```c
struct AudioStreamBasicDescription
{
    Float64             mSampleRate;
    AudioFormatID       mFormatID;
    AudioFormatFlags    mFormatFlags;
    UInt32              mBytesPerPacket;
    UInt32              mFramesPerPacket;
    UInt32              mBytesPerFrame;
    UInt32              mChannelsPerFrame;
    UInt32              mBitsPerChannel;
    UInt32              mReserved;
};

// 输入PCM
AudioStreamBasicDescription inputFormat = {0};
inputFormat.mSampleRate = 48000;
inputFormat.mFormatID = kAudioFormatLinearPCM;
inputFormat.mFormatFlags = 41;
inputFormat.mBytesPerPacket = 4;
inputFormat.mFramesPerPacket = 1;
inputFormat.mBytesPerFrame = 4;
inputFormat.mChannelsPerFrame = 1;
inputFormat.mBitsPerChannel = 32;

// 输出AAC
AudioStreamBasicDescription outputFormat;
memset(&outputFormat, 0, sizeof(outputFormat));
outputFormat.mSampleRate = inputFormat.mSampleRate;
outputFormat.mFormatID = kAudioFormatMPEG4AAC;
outputFormat.mFormatFlags = kMPEG4Object_AAC_LC;
outputFormat.mBytesPerPacket = 0;
outputFormat.mChannelsPerFrame = kTVUAudioEncoderStereoChannel;
outputFormat.mFramesPerPacket = kTVUAudioEncoderFramesPerPacket;
outputFormat.mBytesPerFrame = 0;
outputFormat.mBitsPerChannel = 0;
outputFormat.mReserved = 0;
```

### 判断硬件编码支持

如何判断是否支持硬编码：

[Determining the availability of the AAC hardware encoder at runtime](https://developer.apple.com/library/archive/qa/qa1663/_index.html)

---
