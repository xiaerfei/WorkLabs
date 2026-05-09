## chrome 源码
Chrome: https://source.chromium.org/chromium/chromium/src/+/main:media/cast/encoding/audio_encoder.cc

## ijkplayer 相关
● ijkplayer中遇到的问题汇总 https://juejin.cn/post/6844903694845083655
● ijkplayer丢帧的处理方案 https://www.jianshu.com/p/ecf51ee32589
● ijkplay播放直播流延时控制小结  https://www.jianshu.com/p/d6a5d8756eec?utm_campaign=hugo&utm_medium=reader_share&utm_content=note&utm_source=qq
● 开源播放器 ijkplayer (二) ：ijkplayer倍速变调问题解决方案 https://www.cnblogs.com/renhui/p/6510872.html
● ijkplayer直播播放器使用经验之谈——卡顿优化和秒开实现 https://blog.csdn.net/cmshao/article/details/80149176

Ijkplayer、ExoPlayer、VLC播放器综合比较  https://juejin.cn/post/6956604648476622856

## 音视频面试涨知识
音视频面试涨知识（一） https://juejin.cn/post/7174374017980661791


## Web性能权威指南
High Performance Browser Networking(Web性能权威指南) https://hpbn.co/#toc

## 文章收集
[Android 原创] FLV：不许动手动脚(本文将着重分析 FLV 容器的语法语义，结合我遇到的几个安卓平台的 FLV 加密进行分析，同时对这几个样本做解密还原。) 

StreamEye

音视频编解码自学篇(从零开始敲一个播放器-知乎) https://www.zhihu.com/column/c_1629631086241153024
音视频技术(音视频技术从0到1, 详细解析了 ffplay 中的队列以及同步) https://www.zhihu.com/column/avtec

殷文杰 https://yinwenjie.blog.csdn.net/?type=blog
缥缈峰天津大学信号硕士，音视频技术专家，程序员，压缩播放3D渲染 https://www.zhihu.com/people/liu-sheng-71-36/posts

## 音视频编辑器
Cabbage 音视频编辑器
iOS 视频编辑核心架构(详细描述了音视频编辑的整个过程) https://github.com/VideoFlint/Cabbage/wiki/%E4%B8%AD%E6%96%87%E8%AF%B4%E6%98%8E
● AVFoundation Programming Guide https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/AVFoundationPG/Articles/00_Introduction.html
● WWDC 2013 Session 612: Advanced Editing with AV Foundation https://developer.apple.com/videos/play/wwdc2013/612/
● WWDC 2012 Session 517: Real-Time Media Effects and Processing during Playback https://developer.apple.com/videos/play/wwdc2012/517/
● Apple 整理的完整的 AVFoundation 文档 https://developer.apple.com/av-foundation/

● 推荐书籍：
  ○ 《Learning AV Foundation》 https://www.amazon.com/Learning-Foundation-Hands-Mastering-Framework/dp/0321961803
  ○ 中文《AVFoundation 开发秘籍》
● 推荐应用：
  ○ 猫饼ö Cabbage 框架是从猫饼内的编辑器代码重构而来，猫饼 app 已经验证了这套框架的可行性，并且填了很多坑。
  ○ Videoleap，目前看到视频编辑功能最完善的移动端 app

短视频这么火，微视的特效是怎么做的？(详细讲述了特效的原理和难点) https://www.infoq.cn/article/t0kvcqyhtehfvty5eyql

视频清晰度优化指南 ｜ 得物技术：https://mp.weixin.qq.com/s/YHfAjr_MG_N7nGLtrLEFEw
参考文章：
VMAF开源项目
 https://github.com/Netflix/vmaf
揭秘 VMAF 视频质量评测标准
https://xie.infoq.cn/article/26aaf2ab83f56192a65ba22ea
Netflix VMAF 视频质量评估工具概述
https://zhuanlan.zhihu.com/p/94223056
B帧对视频清晰度/码率的影响
https://blog.csdn.net/matrix_laboratory/article/details/82726897(VIP)
https://blog.csdn.net/TyearLin/article/details/130882363(Free)
H264 vs H265
https://www.cnblogs.com/wujianming-110117/p/12640533.html
超分开源项目
https://github.com/xinntao/Real-ESRGAN


## 视频基础总结
![](./images/video-nodes.png)

● 零基础，史上最通俗视频编码技术入门(讲述了相关的知识点) https://segmentfault.com/a/1190000023362309
● 实时音视频技术基础知识全面盘点 https://segmentfault.com/a/1190000023362309
● ffplay 播放器源代码分析 https://cloud.tencent.com/developer/article/1004559
● H264 编码分析 https://www.yuque.com/keith-an9fr/aab7xp/vng2pb
● 视频和视频帧：H264编码格式整理 https://zhuanlan.zhihu.com/p/71928833

## 音频相关
iOS 音频采集、转换和播放
IOS 端音频的采集与播放(豆瓣开源的播放器) https://xie.infoq.cn/article/b8c110b4c6d696b05a7c2f22c
豆瓣 https://github.com/douban/DOUAudioStreamer

Configuring an Audio Session https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/AudioSessionBasics/AudioSessionBasics.html
WebRTC 系列之音频会话管理 https://blog.csdn.net/netease_im/article/details/113875029?utm_medium=distribute.pc_relevant.none-task-blog-OPENSEARCH-10.control&dist_request_id=&depth_1-utm_source=distribute.pc_relevant.none-task-blog-OPENSEARCH-10.control

音频解码 Audio Converter https://www.jianshu.com/p/25188072a11a
iOS 音频-AVAudioSession  https://www.jianshu.com/p/fb0e5fb71b3c
在线教室 iOS 端声音问题综合解决方案 https://mp.weixin.qq.com/s?__biz=MzI1MzYzMjE0MQ==&mid=2247488032&idx=1&sn=a8e8948fcd043cd0124e8bfe26aa0784&chksm=e9d0d9c2dea750d45cb31e321c2206cc5e2c1d6a6ce1ea888432d7529660254df18325bb0582&mpshare=1&scene=1&srcid=0302VQAMfPTnksVVWajpjD31&sharer_sharetime=1614681590686&sharer_shareid=56acb924444b93ede624b545b0383c04#rd
音频解码 Audio Converter https://xiaodongxie1024.github.io/2019/05/19/20190519_AudioDecoder/
Chrome audio_encoder https://source.chromium.org/chromium/chromium/src/+/main:media/cast/encoding/audio_encoder.cc

iOS音频-audioUnit总结 https://www.jianshu.com/p/f859640fcb33
【iOS音视频学习】AudioToolBox音频硬编码AAC https://juejin.cn/post/7069395297239040037

AudioSession Programming Guide https://developer.apple.com/library/archive/documentation/Audio/Conceptual/AudioSessionProgrammingGuide/Introduction/Introduction.html#//apple_ref/doc/uid/TP40007875-CH1-SW1
Media Playback Programming Guide https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/Introduction/Introduction.html#//apple_ref/doc/uid/TP40016757-CH1-SW1
Multimedia Programming Guide(已过时)https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MultimediaPG/UsingAudio/UsingAudio.html#//apple_ref/doc/uid/TP40009767-CH2-SW9
AVFoundation Document https://developer.apple.com/documentation/avfoundation?language=objc
AVFoundation Programming Guides and Reference(和 AVFoundation 相关的资源) https://developer.apple.com/av-foundation/
Apple Developer Documentation https://developer.apple.com/documentation?language=objc
IOS 端音频的采集与播放 https://xie.infoq.cn/article/b8c110b4c6d696b05a7c2f22c


于实现唱吧清唱功能的理解 https://oliverqueen.cn/2018-06-19-MusicAbout/
【融云分析】iOS 混音之 AVAudioEngine 详解 https://www.rongcloud.cn/blog/?p=4222
iOS Audio hand by hand: 变声，混响，语音合成 TTS，Swift5，基于 AVAudioEngine 等 https://juejin.cn/post/6844903957144272903
Chrome 中 AVAudioEngine https://source.chromium.org/chromium/chromium/src/+/main:third_party/tflite_support/src/tensorflow_lite_support/ios/task/audio/core/audio_record/sources/TFLAudioRecord.m

AVAudioEngine Tutorial for iOS: Getting Started https://www.kodeco.com/21672160-avaudioengine-tutorial-for-ios-getting-started

一步一步教你实现iOS音频频谱动画（一）https://juejin.cn/post/6844903784011792391
一步一步教你实现iOS音频频谱动画（二）https://juejin.cn/post/6844903791670591495

iOSPrinciple_AVFoundation(读书推荐《音视频开发进阶指南 基于Android与iOS平台的实践》) https://github.com/ReverseScale/iOSPrinciple_AVFoundation

AVFoundation 框架解析 https://developer.aliyun.com/article/663875

## AudioUnit 研究
资源收集
iOS 音视频高级编程：Audio Unit播放FFmpeg解码的音频(对于 AudioUnit 播放音频的初始化过程进行了研究)
https://blog.51cto.com/u_16124099/6328630?articleABtest=0

 ijkplay播放直播流延时控制小结 https://www.jianshu.com/p/d6a5d8756eec
iOS 音视频高级编程：Audio Unit播放FFmpeg解码的音频 https://blog.51cto.com/u_16124099/6328630?articleABtest=0
WebRTC源码分析之IOS Audio Unit https://www.jianshu.com/p/e86380eca764
Media Playback Programming Guide https://developer.apple.com/library/archive/documentation/AudioVideo/Conceptual/MediaPlaybackGuide/Contents/Resources/en.lproj/Introduction/Introduction.html#//apple_ref/doc/uid/TP40016757
Audio Unit 工作原理 https://acefish.github.io/15773512971221.html

AudioQueue 知识 https://www.jianshu.com/p/ed6d0862bd0d
iOS音频之Audio Unit & AudioEngine https://github.com/zhenshub/WorkNote/blob/master/%E9%9F%B3%E8%A7%86%E9%A2%91%E6%8A%80%E6%9C%AF/iOS%E9%9F%B3%E9%A2%91%E4%B9%8BAudioUnit%26AudioEngine.md
IOS 端音频的采集与播放 https://xie.infoq.cn/article/b8c110b4c6d696b05a7c2f22c
(强烈推荐)移动端音视频从零到上手 https://www.jianshu.com/p/228b668361bd
【iOS音视频学习】AudioToolBox音频硬编码AAC https://juejin.cn/post/7069395297239040037
深入理解 AudioUnit (一) ~ IO Unit 结构和运行机制 https://xueshi.me/2022/03/12/AudioUnit-01-IOUnit/




待解决问题
处理当 outData 不足以容纳重采样出来的数据时，会丢失数据或者crash
```objc
    uint8_t **inData = inputFrame->extended_data ? inputFrame->extended_data : inputFrame->data;
    uint8_t *outData[AV_NUM_DATA_POINTERS] = {0};
    outData[0] = (uint8_t *)outBuffer->mAudioData;
    ///TODO: 处理当 outData 不足以容纳重采样出来的数据时，会丢失数据或者crash
    // 执行重采样
    int samplesConverted = swr_convert(_swrContext,
                                       outData,
                                       availableOutFrames,
                                       (const uint8_t **)inData,
                                       inputFrame->nb_samples);
```

当 availableOutFrames 不足以容纳重采样输出时：
数据丢失：超出缓冲区的样本会被丢弃
音频卡顿：连续丢帧会导致播放不连贯
同步问题：PTS时间戳计算会出错

## ffplay
ffplay packet queue分析(知乎) https://zhuanlan.zhihu.com/p/43295650


## 讨论
如果研究生阶段方向是音视频编解码，本科期间应该打好哪些基础？

作者：诚明飞
链接：https://www.zhihu.com/question/27005982/answer/51158064
来源：知乎
著作权归作者所有。商业转载请联系作者获得授权，非商业转载请注明出处。

在视频编解码领域从事工作几年，还没有仔细总结一路怎么走来。趁知友提的问题，再回头看看，稍有心得体会，希望对你有帮助。
视频编解码所从事的工作大致分成3类：编解码算法研究、编解码标准实现、编解码应用开发。
1. 编解码算法研究主要指制定标准相关工作，参与标准组织，制定新一代标准，比如HEVC、AVS等。该方向研究性较强，需要扎实的基础学科功底，如果在学校期间能够很好掌握线性代数、矩阵论、信息论、通信原理、数字信号处理、统计信号处理等课程，对该方面的发展帮助较大。目前国内参与标准制定的单位主要是高等院校、研究机构、以及一些大企业（海思、三星、联发科等）。
2. 编解码标准实现主要在不同的平台实现符合标准的编码组件和解码组件。该方向要求熟悉标准文档、熟练掌握C语言编程、熟悉平台指令集优化、熟悉嵌入式开发、能够设计编码3大算法（模式选择、码率控制、运动搜索）等。国内设立这种岗位的公司很多，视频监控行业、视频会议行业、互联网行业、机器视觉行业等与多媒体相关的企业都会有。当然，大的公司分工细，会设定专门做编解码组件的岗位，专业化程度；小公司则要求全面，做事杂些。
3. 编解码应用开发主要是在编解码组件的基础上，进行系统级开发，包括系统封装层、多媒体软件、传输协议、QoS等。该方向所从事的工作更编解码标准中的技术没有关系，主要要求软件集成能力、应用开发能力等。
从后往前看，回到“如何打好基础”的问题上来，有几个建议步骤：
1. 学好线性代数、矩阵论、信息论、通信原理、数字信号处理、统计信号处理等课程；
2. 专业方面熟悉一门标准，建议学H.264。相比H.265来说，H.264更加成熟，材料多。推荐看Iain E G Richardon 写的入门教程“H.264 and MPEG-4 Video Compression”，该书浅显易懂，思路清晰。随后，需要看H.264标准文档以了解更多细节，结合参考软件JM的解码部分一起看；
3. 围绕预测编码、变换编码、熵编码，看一些学术文章，弄清楚标准中各技术背后的原理；
4. 调试开源代码，该步骤可以与前面并行。多去玩玩ffmpeg等、x264等，提高编程能力，主要是C语言开发能力。试着去优化一、两个独立的模块，优化的平台选X86、ARM都可以。
5. 试着用开源代码实现一些应用demo，这方面可以参看 @张晖 的回答。


建议往2、3方向发展，纯的算法研究以后路子较窄，