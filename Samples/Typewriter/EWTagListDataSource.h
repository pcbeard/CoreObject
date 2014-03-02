/*
	Copyright (C) 2014 Eric Wasylishen
 
	Date:  February 2014
	License:  MIT  (see COPYING)
 */

#import <Foundation/Foundation.h>

@class EWTypewriterWindowController;

@interface EWTagGroupTagPair : NSObject
@property (nonatomic, readonly) ETUUID *tagGroup;
@property (nonatomic, readonly) ETUUID *tag;
- (instancetype)initWithTagGroup: (ETUUID *)aTagGroup tag: (ETUUID*)aTag;
@end

@interface EWTagListDataSource : NSObject <NSOutlineViewDataSource, NSOutlineViewDelegate>
{
	NSTreeNode *rootTreeNode;
	NSMutableSet *oldSelection;
	EWTagGroupTagPair *nextSelection;
}

@property (nonatomic, unsafe_unretained) EWTypewriterWindowController *owner;
@property (nonatomic, strong) NSOutlineView *outlineView;
- (void)reloadData;
- (void)cacheSelection;

- (void) setNextSelection: (EWTagGroupTagPair *)aUUID;
@end