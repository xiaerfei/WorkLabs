//
//  WLDefines.h
//  WorkLabs
//
//  NewPlan 基础类型定义
//

#import <Foundation/Foundation.h>

#pragma mark - 节点类型

typedef NS_ENUM(NSInteger, WLNodeType) {
    WLNodeTypeNone,
    WLNodeTypeVideo,
    WLNodeTypeAudio
};

#pragma mark - 数据来源

typedef NS_ENUM(NSInteger, WLFromType) {
    WLFromTypeCamera,
    WLFromTypeMic,
    WLFromTypeMedia,
    WLFromTypeNetwork,
};
