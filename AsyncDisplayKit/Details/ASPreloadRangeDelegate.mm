//
//  ASPreloadRangeDelegate.m
//  AsyncDisplayKit
//
//  Created by Ryan Nystrom on 2/18/15.
//  Copyright (c) 2015 Facebook. All rights reserved.
//

#import "ASPreloadRangeDelegate.h"

#import "ASDisplayNode.h"
#import "ASDisplayNode+Subclasses.h"

@implementation ASPreloadRangeDelegate

- (void)node:(ASDisplayNode *)node enteredRangeType:(ASLayoutRangeType)rangeType
{
  [node fetchRemoteData];
}

- (void)node:(ASDisplayNode *)node exitedRangeType:(ASLayoutRangeType)rangeType
{
  [node recursivelyClearRemoteData];
}

@end
