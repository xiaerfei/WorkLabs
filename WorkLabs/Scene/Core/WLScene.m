//
//  WLScene.m
//  WorkLabs
//
//  Created by erfeixia on 19/04/2026.
//

#import "WLScene.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>

#pragma mark - WLScene

@interface WLScene ()

@property (nonatomic, strong, readwrite) NSArray<id<WLMediaSourceProvider>> *sources;
@property (nonatomic, strong, readwrite) NSDictionary<NSString *, WLSourceLayout *> *sourceLayouts;

/// 内部可变源列表
@property (nonatomic, strong) NSMutableArray<id<WLMediaSourceProvider>> *mutableSources;

/// 内部布局映射（key = source.identifier，避免对 source 对象做 copy）
@property (nonatomic, strong) NSMutableDictionary<NSString *, WLSourceLayout *> *mutableSourceLayoutMap;

@end

@implementation WLScene

#pragma mark - 初始化

- (instancetype)initWithName:(NSString *)name canvasSize:(CGSize)size {
    self = [super init];
    if (self) {
        _name = [name copy];
        _canvasSize = size;
        _mutableSources = [NSMutableArray array];
        _mutableSourceLayoutMap = [NSMutableDictionary dictionary];
        _sources = [NSArray array];
        _sourceLayouts = @{};
    }
    return self;
}

#pragma mark - 媒体源管理

- (void)addSource:(id<WLMediaSourceProvider>)source atRect:(CGRect)rect {
    NSParameterAssert(source);
    NSParameterAssert(source.identifier);
    
    // 防止重复添加
    if ([self.mutableSources containsObject:source]) {
        NSLog(@"[WLScene] 源 \"%@\" 已存在于场景 \"%@\" 中，跳过添加", source.sourceName, self.name);
        return;
    }
    
    // 创建布局信息
    WLSourceLayout *layout = [WLSourceLayout layoutWithFrame:rect];
    
    // 添加到内部容器（以 source.identifier 为 key）
    [self.mutableSources addObject:source];
    self.mutableSourceLayoutMap[source.identifier] = layout;
    
    // 更新只读属性
    self.sources = [self.mutableSources copy];
    self.sourceLayouts = [self.mutableSourceLayoutMap copy];
    
    NSLog(@"[WLScene] 场景 \"%@\" 已添加源: \"%@\" (id=%@) at %@",
          self.name, source.sourceName, source.identifier, NSStringFromRect(rect));
}

- (void)removeSource:(id<WLMediaSourceProvider>)source {
    NSParameterAssert(source);
    
    if (![self.mutableSources containsObject:source]) {
        NSLog(@"[WLScene] 源 \"%@\" 不在场景 \"%@\" 中，跳过移除", source.sourceName, self.name);
        return;
    }
    
    // 先停止媒体源
    if ([source isActive]) {
        [source stop];
    }
    
    // 从内部容器移除
    [self.mutableSources removeObject:source];
    [self.mutableSourceLayoutMap removeObjectForKey:source.identifier];
    
    // 更新只读属性
    self.sources = [self.mutableSources copy];
    self.sourceLayouts = [self.mutableSourceLayoutMap copy];
    
    NSLog(@"[WLScene] 场景 \"%@\" 已移除源: \"%@\"", self.name, source.sourceName);
}

#pragma mark - 查询

- (WLSourceLayout *)layoutForIdentifier:(NSString *)identifier {
    return self.mutableSourceLayoutMap[identifier];
}

#pragma mark - Description

- (NSString *)description {
    return [NSString stringWithFormat:@"<WLScene: %@ | canvas=%.0fx%.0f | sources=%lu>",
            self.name, self.canvasSize.width, self.canvasSize.height,
            (unsigned long)self.sources.count];
}

@end
