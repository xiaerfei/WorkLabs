现在我们来实现 WLScene 视图容器

WLSceneManagerView 负责管理 WLScene 视图，包括切换场景、添加/删除场景、添加/删除视图等。

1. WLSceneManagerView 是最底层的视图，由 WLSceneManager 持有。
2. WLSceneView 是具体的场景视图，由每个 WLScene 持有。
3. WLScene 管理着多个 MediaSource(WLMediaSourceProvider)

每个 MediaSource 对应一个 WLMetalPreview，如果这个 MediaSource 存在视频流，则渲染视频流。