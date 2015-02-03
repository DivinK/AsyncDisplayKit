//
//  ASRangeDelegate.h
//  AsyncDisplayKit
//
//  Created by Ryan Nystrom on 2/18/15.
//  Copyright (c) 2015 Facebook. All rights reserved.
//

#import <Foundation/Foundation.h>

#import <AsyncDisplayKit/ASLayoutRangeType.h>

@class ASDisplayNode;

@protocol ASRangeDelegate <NSObject>

@required

- (void)node:(ASDisplayNode *)node enteredRangeType:(ASLayoutRangeType)rangeType;
- (void)node:(ASDisplayNode *)node exitedRangeType:(ASLayoutRangeType)rangeType;

@end
