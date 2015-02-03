/* Copyright (c) 2014-present, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 */

#import "ASRangeController.h"

#import "ASAssert.h"
#import "ASDisplayNodeExtras.h"
#import "ASDisplayNodeInternal.h"
#import "ASMultiDimensionalArrayUtils.h"
#import "ASRenderRangeDelegate.h"
#import "ASPreloadRangeDelegate.h"

@interface ASRangeController () {
  NSSet *_renderRangeNodes;
  BOOL _rangeIsValid;

  // keys should be ASLayoutRangeTypes and values NSSets containing NSIndexPaths
  NSMutableDictionary *_rangeTypeIndexPaths;
  NSDictionary *_rangeTypeDelegates;
  BOOL _queuedRangeUpdate;

  ASScrollDirection _scrollDirection;
}

@end

@implementation ASRangeController

- (instancetype)init {
  if (self = [super init]) {

    _rangeIsValid = YES;
    _rangeTypeIndexPaths = [[NSMutableDictionary alloc] init];

    _rangeTypeDelegates = @{
                            @(ASLayoutRangeTypeRender): [[ASRenderRangeDelegate alloc] init],
                            @(ASLayoutRangeTypePreload): [[ASPreloadRangeDelegate alloc] init],
                            };
  }

  return self;
}

#pragma mark - View manipulation.

- (void)discardNode:(ASCellNode *)node
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(node, @"invalid argument");

  id<ASRangeDelegate> rangeDelegate = _rangeTypeDelegates[@(ASLayoutRangeTypeRender)];
  if ([_renderRangeNodes containsObject:node]) {
    // move the node's view to the working range area, so its rendering persists
//    [self addNodeToRenderRange:node];
    [rangeDelegate node:node enteredRangeType:ASLayoutRangeTypeRender];
  } else {
    // this node isn't in the working range, remove it from the view hierarchy
    [rangeDelegate node:node exitedRangeType:ASLayoutRangeTypeRender];
//    [self removeNodeFromRenderRange:node];
  }
}

- (void)moveNode:(ASCellNode *)node toView:(UIView *)view
{
  ASDisplayNodeAssertMainThread();
  ASDisplayNodeAssert(node && view, @"invalid argument, did you mean -removeNodeFromRenderRange:?");

  [view addSubview:node.view];
}


#pragma mark -
#pragma mark API.

- (void)visibleNodeIndexPathsDidChangeWithScrollDirection:(ASScrollDirection)scrollDirection
{
  _scrollDirection = scrollDirection;

  if (_queuedRangeUpdate) {
    return;
  }

  // coalesce these events -- handling them multiple times per runloop is noisy and expensive
  _queuedRangeUpdate = YES;
  [self performSelector:@selector(updateVisibleNodeIndexPaths)
             withObject:nil
             afterDelay:0
                inModes:@[ NSRunLoopCommonModes ]];
}

- (void)updateVisibleNodeIndexPaths
{
  if (!_queuedRangeUpdate) {
    return;
  }

  NSArray *visibleNodePaths = [_delegate rangeControllerVisibleNodeIndexPaths:self];
  NSSet *visibleNodePathsSet = [NSSet setWithArray:visibleNodePaths];
  CGSize viewportSize = [_delegate rangeControllerViewportSize:self];

  // the layout controller needs to know what the current visible indices are to calculate range offsets
  [_layoutController setVisibleNodeIndexPaths:visibleNodePaths];

  for (NSInteger i = 0; i < ASLayoutRangeTypeCount; i++) {
    ASLayoutRangeType rangeType = (ASLayoutRangeType)i;
    id rangeKey = @(rangeType);

    // this delegate decide what happens when a node is added or removed from a range
    id<ASRangeDelegate> rangeDelegate = _rangeTypeDelegates[rangeKey];

    if ([_layoutController shouldUpdateForVisibleIndexPaths:visibleNodePaths viewportSize:viewportSize rangeType:rangeType]) {
      NSSet *indexPaths = [_layoutController indexPathsForScrolling:_scrollDirection viewportSize:viewportSize rangeType:rangeType];

      // Notify to remove indexpaths that are leftover that are not visible or included in the _layoutController calculated paths
      NSMutableSet *removedIndexPaths = _rangeIsValid ? [[_rangeTypeIndexPaths objectForKey:rangeKey] mutableCopy] : [NSMutableSet set];
      [removedIndexPaths minusSet:indexPaths];
      [removedIndexPaths minusSet:visibleNodePathsSet];
      if (removedIndexPaths.count) {
        NSArray *removedNodes = [_delegate rangeController:self nodesAtIndexPaths:[removedIndexPaths allObjects]];
        [removedNodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx, BOOL *stop) {
          [rangeDelegate node:node exitedRangeType:rangeType];
        }];
      }

      // Notify to add indexpaths that are not currently in _rangeTypeIndexPaths
      NSMutableSet *addedIndexPaths = [indexPaths mutableCopy];
      [addedIndexPaths minusSet:[_rangeTypeIndexPaths objectForKey:rangeKey]];

      // The preload range (for example) should include nodes that are visible
      if ([self shouldRemoveVisibleNodesFromRangeType:rangeType]) {
        [addedIndexPaths minusSet:visibleNodePathsSet];
      }

      if (addedIndexPaths.count) {
        NSArray *addedNodes = [_delegate rangeController:self nodesAtIndexPaths:[addedIndexPaths allObjects]];
        [addedNodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx, BOOL *stop) {
          [rangeDelegate node:node enteredRangeType:rangeType];
        }];
      }

      // set the range indexpaths so that we can remove/add on the next update pass
      [_rangeTypeIndexPaths setObject:indexPaths forKey:rangeKey];
    }
  }

  // keep track of the render range nodes to manage discarding them
  NSArray *renderNodePaths = [[_rangeTypeIndexPaths objectForKey:@(ASLayoutRangeTypeRender)] allObjects];
  _renderRangeNodes = [NSSet setWithArray:[_delegate rangeController:self nodesAtIndexPaths:renderNodePaths]];

  _rangeIsValid = YES;
  _queuedRangeUpdate = NO;
}

- (BOOL)shouldRemoveVisibleNodesFromRangeType:(ASLayoutRangeType)rangeType
{
  return rangeType != ASLayoutRangeTypePreload;
}

- (void)configureContentView:(UIView *)contentView forCellNode:(ASCellNode *)cellNode
{
  [cellNode recursivelySetDisplaySuspended:NO];

  if (cellNode.view.superview == contentView) {
    // this content view is already correctly configured
    return;
  }

  for (UIView *view in contentView.subviews) {
    ASDisplayNode *node = view.asyncdisplaykit_node;
    if (node) {
      // plunk this node back into the working range, if appropriate
      ASDisplayNodeAssert([node isKindOfClass:[ASCellNode class]], @"invalid node");
      [self discardNode:(ASCellNode *)node];
    } else {
      // if it's not a node, it's something random UITableView added to the hierarchy.  kill it.
      [view removeFromSuperview];
    }
  }

  [self moveNode:cellNode toView:contentView];
}

#pragma mark - ASDataControllerDelegete

- (void)dataControllerBeginUpdates:(ASDataController *)dataController {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_delegate rangeControllerBeginUpdates:self];
  });
}

- (void)dataControllerEndUpdates:(ASDataController *)dataController {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_delegate rangeControllerEndUpdates:self];
  });
}

- (void)dataController:(ASDataController *)dataController willInsertNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willInsertNodesAtIndexPaths:withAnimationOption:)]) {
      [_delegate rangeController:self willInsertNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didInsertNodes:(NSArray *)nodes atIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodeAssert(nodes.count == indexPaths.count, @"Invalid index path");

  NSMutableArray *nodeSizes = [NSMutableArray arrayWithCapacity:nodes.count];
  [nodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx, BOOL *stop) {
    [nodeSizes addObject:[NSValue valueWithCGSize:node.calculatedSize]];
  }];

  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController insertNodesAtIndexPaths:indexPaths withSizes:nodeSizes];
    [_delegate rangeController:self didInsertNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

- (void)dataController:(ASDataController *)dataController willDeleteNodesAtIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willDeleteNodesAtIndexPaths:withAnimationOption:)]) {
      [_delegate rangeController:self willDeleteNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didDeleteNodesAtIndexPaths:(NSArray *)indexPaths withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController deleteNodesAtIndexPaths:indexPaths];
    [_delegate rangeController:self didDeleteNodesAtIndexPaths:indexPaths withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

- (void)dataController:(ASDataController *)dataController willInsertSections:(NSArray *)sections atIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willInsertSectionsAtIndexSet:withAnimationOption:)]) {
      [_delegate rangeController:self willInsertSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didInsertSections:(NSArray *)sections atIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodeAssert(sections.count == indexSet.count, @"Invalid sections");

  NSMutableArray *sectionNodeSizes = [NSMutableArray arrayWithCapacity:sections.count];

  [sections enumerateObjectsUsingBlock:^(NSArray *nodes, NSUInteger idx, BOOL *stop) {
    NSMutableArray *nodeSizes = [NSMutableArray arrayWithCapacity:nodes.count];
    [nodes enumerateObjectsUsingBlock:^(ASCellNode *node, NSUInteger idx2, BOOL *stop2) {
      [nodeSizes addObject:[NSValue valueWithCGSize:node.calculatedSize]];
    }];
    [sectionNodeSizes addObject:nodeSizes];
  }];

  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController insertSections:sectionNodeSizes atIndexSet:indexSet];
    [_delegate rangeController:self didInsertSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

- (void)dataController:(ASDataController *)dataController willDeleteSectionsAtIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    if ([_delegate respondsToSelector:@selector(rangeController:willDeleteSectionsAtIndexSet:withAnimationOption:)]) {
      [_delegate rangeController:self willDeleteSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    }
  });
}

- (void)dataController:(ASDataController *)dataController didDeleteSectionsAtIndexSet:(NSIndexSet *)indexSet withAnimationOption:(ASDataControllerAnimationOptions)animationOption {
  ASDisplayNodePerformBlockOnMainThread(^{
    [_layoutController deleteSectionsAtIndexSet:indexSet];
    [_delegate rangeController:self didDeleteSectionsAtIndexSet:indexSet withAnimationOption:animationOption];
    _rangeIsValid = NO;
  });
}

@end
