/*
	Copyright (C) 2011 Eric Wasylishen, Quentin Mathe, Christopher Armstrong

	Date:  September 2011
	License:  MIT  (see COPYING)
 */

#import "COBranch.h"
#import "COBranch+Private.h"
#import "COEditingContext.h"
#import "COEditingContext+Private.h"
#import "COPersistentRoot.h"
#import "COPersistentRoot+Private.h"
#import "COSQLiteStore.h"
#import "COPersistentRootInfo.h"
#import "COObject.h"
#import "COObject+Private.h"
#import "CORevision.h"
#import "FMDatabase.h"
#import "CORevisionInfo.h"
#import "COBranchInfo.h"
#import "COObjectGraphContext.h"
#import "COObjectGraphContext+Private.h"
#import "COObjectGraphContext+GarbageCollection.h"
#import "COEditingContext+Undo.h"
#import "COLeastCommonAncestor.h"
#import "COItemGraphDiff.h"
#import "COMergeInfo.h"
#import "CORevisionCache.h"
#import "COStoreTransaction.h"

NSString * const kCOBranchLabel = @"COBranchLabel";

@implementation COBranch

@synthesize UUID = _UUID, persistentRoot = _persistentRoot, objectGraphContext = _objectGraph;
@synthesize shouldMakeEmptyCommit = _shouldMakeEmptyCommit, supportsRevert = _supportsRevert;
@synthesize mergingBranch = _mergingBranch;

+ (void) initialize
{
	if (self != [COBranch class])
		return;

	[self applyTraitFromClass: [ETCollectionTrait class]];
}

- (id)init
{
	[self doesNotRecognizeSelector: _cmd];
	return nil;
}

/**
 * Both root object and revision are lazily retrieved by the persistent root.
 * Until the loaded revision is known, it is useless to cache track nodes. 
 */
- (id)        initWithUUID: (ETUUID *)aUUID
        objectGraphContext: (COObjectGraphContext *)anObjectGraphContext
            persistentRoot: (COPersistentRoot *)aContext
          parentBranchUUID: (ETUUID *)aParentBranchUUID
parentRevisionForNewBranch: (ETUUID *)parentRevisionForNewBranch
{
	NILARG_EXCEPTION_TEST(aUUID);
	NSParameterAssert([aUUID isKindOfClass: [ETUUID class]]);
	NILARG_EXCEPTION_TEST(aContext);
	INVALIDARG_EXCEPTION_TEST(anObjectGraphContext,
		anObjectGraphContext == nil || [anObjectGraphContext branch] == nil);
							  
	if ([[aContext parentContext] store] == nil)
	{
		[NSException raise: NSInvalidArgumentException
		            format: @"Cannot load commit track for %@ which does not "
					         "have a store or editing context", aContext];
	}

	SUPERINIT;

	_supportsRevert = YES;
    _UUID =  aUUID;
        
	/* The persistent root retains us */
	_persistentRoot = aContext;
    _parentBranchUUID = aParentBranchUUID;
    
	if (anObjectGraphContext == nil)
	{
    	_objectGraph = [[COObjectGraphContext alloc] initWithBranch: self];
    }
	else
	{
		_objectGraph =  anObjectGraphContext;
		[anObjectGraphContext setBranch: self];
	}

    if ([_persistentRoot persistentRootInfo] != nil
        && parentRevisionForNewBranch == nil)
    {
        // Loading an existing branch
        
        [self updateWithBranchInfo: [self branchInfo]];
    }
    else
    {
        // Creating a new branch
        
        _currentRevisionUUID = parentRevisionForNewBranch;
		_headRevisionUUID = parentRevisionForNewBranch;
        _isCreated = NO;
        
        // If _parentRevisionID is nil, we're a new branch for a new persistent root
        // Otherwise, we're a new branch for an existing (committed) persistent root
        
        if (_currentRevisionUUID != nil)
        {
			ETUUID *parentPersistentRoot = [[_persistentRoot store]
				persistentRootUUIDForBranchUUID: _parentBranchUUID];

			// N.B., normally we could pass [[self persistentRoot] UUID] here, but our persistent root is not
			// yet committed.
            id <COItemGraph> aGraph =
				[[_persistentRoot store] itemGraphForRevisionUUID: _currentRevisionUUID
			                                       persistentRoot: parentPersistentRoot];
            [_objectGraph setItemGraph: aGraph];
			[_persistentRoot.objectGraphContext setItemGraph: aGraph];
            
            ETAssert(![_objectGraph hasChanges]);
        }
        
        _metadata = [[NSMutableDictionary alloc] init];
    }
    
	return self;	
}

- (COEditingContext *) editingContext
{
    return [_persistentRoot editingContext];
}

- (BOOL) isBranchUncommitted
{
    return _isCreated == NO;
}

- (BOOL) isBranchPersistentRootUncommitted
{
    return _currentRevisionUUID == nil && _isCreated == NO;
}

- (NSString *)displayName
{
	NSString *label = [self label];
	NSString *displayName = [[[self persistentRoot] rootObject] displayName];
	
	if (label != nil && [label isEqual: @""] == NO)
	{
		displayName = [displayName stringByAppendingFormat: @" (%@)", label];
	}
	return displayName;
}

- (BOOL)isCopy
{
    // FIXME: Implement
    return NO;
}

- (BOOL)isCurrentBranch
{
    return self == [_persistentRoot currentBranch];
}

- (BOOL)isTrunkBranch
{
	// FIXME: Implement by reading from our metadata dictionary
	return NO;
}

- (COBranchInfo *)branchInfo
{
    COPersistentRootInfo *persistentRootInfo = [[self persistentRoot] persistentRootInfo];
    COBranchInfo *branchInfo = [persistentRootInfo branchInfoForUUID: _UUID];
    return branchInfo;
}

- (NSDictionary *)metadata
{
	return [NSDictionary dictionaryWithDictionary: _metadata];
}

- (void)setMetadata: (NSDictionary *)aMetadata
{
    [_metadata setDictionary: aMetadata];
    _metadataChanged = YES;
}

- (NSString *)label
{
	return [_metadata objectForKey: kCOBranchLabel];
}

- (void)setLabel: (NSString *)aLabel
{
	[_metadata setObject: aLabel forKey: kCOBranchLabel];
    _metadataChanged = YES;
}

- (BOOL)isDeleted
{
    if ([[_persistentRoot branchesPendingUndeletion] containsObject: self])
        return NO;
    
    if ([[_persistentRoot branchesPendingDeletion] containsObject: self])
        return YES;

    if ([[_persistentRoot deletedBranches] containsObject: self])
        return YES;
    
    return NO;
}

- (void) setDeleted:(BOOL)deleted
{
    if (deleted && [self isCurrentBranch])
    {
		// TODO: Use a CoreObject exception type
		[NSException raise: NSGenericException
		            format: @"Can't delete the current branch"];
    }
    
    if (deleted)
    {
        [_persistentRoot deleteBranch: self];
    }
    else
    {
        [_persistentRoot undeleteBranch: self];
    }
}

- (CORevision *)initialRevision
{
    ETUUID *revid = [[self branchInfo] initialRevisionUUID];
    
    if (revid == nil)
		return nil;

	return [[self editingContext] revisionForRevisionUUID: revid
	                                   persistentRootUUID: [[self persistentRoot] UUID]];
}

- (CORevision *)firstRevision
{
	COBranch *branch = self;

	while ([branch parentBranch] != nil)
	{
		branch = [branch parentBranch];
	}
	return [branch initialRevision];
}

- (CORevision *)headRevision
{
    if (_headRevisionUUID != nil)
    {
        return [[self editingContext] revisionForRevisionUUID: _headRevisionUUID
										   persistentRootUUID: [[self persistentRoot] UUID]];
    }
    return nil;
}

- (void)setHeadRevision: (CORevision *)aRevision
{
	NILARG_EXCEPTION_TEST(aRevision);
	_headRevisionUUID = [aRevision UUID];
}

- (CORevision *)currentRevision
{
    if (_currentRevisionUUID != nil)
    {
        return [[self editingContext] revisionForRevisionUUID: _currentRevisionUUID
										   persistentRootUUID: [[self persistentRoot] UUID]];
    }
    return nil;
}

- (void) setCurrentRevision:(CORevision *)newCurrentRevision
{
    NILARG_EXCEPTION_TEST(newCurrentRevision);
	
	// TODO: Check and enforce self.supportsRevert
	
	if (![newCurrentRevision isEqualToOrAncestorOfRevision: self.headRevision])
	{
		_headRevisionUUID = [newCurrentRevision UUID];
	}
	
    _currentRevisionUUID = [newCurrentRevision UUID];
    [self reloadAtRevision: newCurrentRevision];
}

- (COBranch *) parentBranch
{
    return [[self editingContext] branchForUUID: _parentBranchUUID];
}

- (BOOL)hasChangesOtherThanDeletionOrUndeletion
{
    if ([self isBranchUncommitted])
    {
        return YES;
    }
    
    if (_metadataChanged)
    {
        return YES;
    }
    
    if (![[[self branchInfo] currentRevisionUUID] isEqual: _currentRevisionUUID])
    {
        return YES;
    }
    
	if (![[[self branchInfo] headRevisionUUID] isEqual: _headRevisionUUID])
    {
        return YES;
    }
	
    if (self.shouldMakeEmptyCommit)
    {
        return YES;
    }
    
	return [[self objectGraphContext] hasChanges];
}

- (BOOL)hasChanges
{
    if ([self isDeleted] != [[self branchInfo] isDeleted])
    {
        return YES;
    }
	return [self hasChangesOtherThanDeletionOrUndeletion];
}

- (void)discardAllChanges
{
    if ([self isBranchUncommitted])
    {
        [NSException raise: NSGenericException
		            format: @"Uncommitted branches do not support -discardAllChanges"];
    }
    
	if (_metadataChanged)
    {
        if ([self isBranchUncommitted])
        {
            [_metadata removeAllObjects];
        }
        else
        {
            _metadata = [NSMutableDictionary dictionaryWithDictionary:
                               [[self branchInfo] metadata]];
        }
        _metadataChanged = NO;
    }
    
    if (![[[self branchInfo] currentRevisionUUID] isEqual: _currentRevisionUUID])
    {
        [self setCurrentRevision:
            [[self editingContext] revisionForRevisionUUID: [[self branchInfo] currentRevisionUUID]
										persistentRootUUID: [[self persistentRoot] UUID]]];
    }

	if (![[[self branchInfo] headRevisionUUID] isEqual: _headRevisionUUID])
    {
        [self setHeadRevision:
			[[self editingContext] revisionForRevisionUUID: [[self branchInfo] headRevisionUUID]
			                            persistentRootUUID: [[self persistentRoot] UUID]]];
    }
	
    if ([self isDeleted] != [[self branchInfo] isDeleted])
    {
        [self setDeleted: [[self branchInfo] isDeleted]];
    }
    
    self.shouldMakeEmptyCommit = NO;
    
	[[self objectGraphContext] discardAllChanges];
}

- (COBranch *)makeBranchWithLabel: (NSString *)aLabel
{
    if ([self isBranchUncommitted])
    {
        [NSException raise: NSGenericException
		            format: @"Uncommitted branches do not support -makeBranchWithLabel:"];
    }
    
	return [self makeBranchWithLabel: aLabel atRevision: [self currentRevision]];
}

- (COBranch *)makeBranchWithLabel: (NSString *)aLabel atRevision: (CORevision *)aRev
{
    NILARG_EXCEPTION_TEST(aRev);
	INVALIDARG_EXCEPTION_TEST(aRev, [[aRev branchUUID] isEqual: _UUID]);
    
    if ([self isBranchUncommitted])
    {
        /* Explanation for this restriction: 
           we could in theory support creating an arbitrary tree of uncommitted branches, or 
		   branches on an uncommitted persistent root, and commit them all in one batch.
         
           The reason for not supporting it is it would just make the commit logic more complex, 
		   doing a graph DFS on the branches and making a commit (if needed) as it visits each branch. */
        [NSException raise: NSGenericException
		            format: @"Uncommitted branches do not support -makeBranchWithLabel:atRevision:"];
    }
    
    return [_persistentRoot makeBranchWithLabel: aLabel atRevision: aRev parentBranch: self];
}

- (COPersistentRoot *)makeCopyFromRevision: (CORevision *)aRev
{
    NILARG_EXCEPTION_TEST(aRev);
	INVALIDARG_EXCEPTION_TEST(aRev, [[aRev branchUUID] isEqual: _UUID]);

    if ([self isBranchUncommitted])
    {
        /* See -makeBranchWithLabel:atRevision: exception explanation */
        [NSException raise: NSGenericException
		            format: @"Uncommitted branches do not support -makeCopyFromRevision:"];
    }
    return [[[self persistentRoot] editingContext] insertNewPersistentRootWithRevisionUUID: [aRev UUID]
																			  parentBranch: self];
}

- (BOOL)needsReloadNodes: (NSArray *)currentLoadedNodes
{
	return NO;
}

- (CORevision *)undoRevision
{
    if ([[self initialRevision] isEqual: [self currentRevision]])
    {
        return nil;
    }
    
    CORevision *revision = [[self currentRevision] parentRevision];
    return revision;
}

- (BOOL)canUndo
{
    return self.supportsRevert && [self undoRevision] != nil;
}

- (void)undo
{
    [self setCurrentRevision: [self undoRevision]];
}

- (CORevision *)redoRevision
{
    CORevision *currentRevision = [self currentRevision];
    CORevision *revision = [self headRevision];
    
    if ([currentRevision isEqual: revision])
    {
        return nil;
    }
    
    while (revision != nil)
    {
        CORevision *revisionParent = [revision parentRevision];
        if ([revisionParent isEqual: currentRevision])
        {
            return revision;
        }
        revision = revisionParent;
    }
    return revision;
}

- (BOOL)canRedo
{
    return self.supportsRevert && [self redoRevision] != nil;
}

- (void)redo
{
    [self setCurrentRevision: [self redoRevision]];
}

- (COSQLiteStore *) store
{
    return [_persistentRoot store];
}

- (void)saveCommitWithMetadata: (NSDictionary *)metadata transaction: (COStoreTransaction *)txn
{
	if ([self hasChangesOtherThanDeletionOrUndeletion]
		&& [[self branchInfo] isDeleted]
		&& self.isDeleted)
	{
		[NSException raise: NSGenericException
					format: @"Attempted to commit changes to deleted branch %@", self];
	}
	
    ETAssert(![self isBranchPersistentRootUncommitted]);
    ETAssert(_currentRevisionUUID != nil);
    ETAssert(_headRevisionUUID != nil);
    
	if ([self isBranchUncommitted])
	{
        // N.B. - this only the case when we're adding a new branch to an existing persistent root.
        
        [txn createBranchWithUUID: _UUID
					 parentBranch: _parentBranchUUID
				  initialRevision: _currentRevisionUUID
				forPersistentRoot: [[self persistentRoot] UUID]];
        
        [[self editingContext] recordBranchCreation: self];
        
        _isCreated = YES;
    }
    else if (![[[self branchInfo] currentRevisionUUID] isEqual: _currentRevisionUUID]
	      || ![[[self branchInfo] headRevisionUUID] isEqual: _headRevisionUUID])
    {
        ETUUID *oldRevUUID = [[self branchInfo] currentRevisionUUID];
        ETAssert(oldRevUUID != nil);
		ETUUID *oldHeadRevUUID = [[self branchInfo] headRevisionUUID];
        
        // This is the case when the user does [self setCurrentRevision: ], and then commits
        
        [txn setCurrentRevision: _currentRevisionUUID
				   headRevision: _headRevisionUUID
					  forBranch: _UUID
			   ofPersistentRoot: [[self persistentRoot] UUID]];
	

        [[self editingContext] recordBranchSetCurrentRevisionUUID: _currentRevisionUUID
                                                  oldRevisionUUID: oldRevUUID
												 headRevisionUUID: _headRevisionUUID
											  oldHeadRevisionUUID: oldHeadRevUUID
														 ofBranch: self];
    }
    
    // Write metadata
    
    if (_metadataChanged)
    {
        [txn setMetadata: _metadata
			   forBranch: _UUID
		ofPersistentRoot: [[self persistentRoot] UUID]];
        
        [[self editingContext] recordBranchSetMetadata: self
                                           oldMetadata: [[self branchInfo] metadata]];
        
        _metadataChanged = NO;
    }
    
    // Write a regular commit
	
	COObjectGraphContext *modifiedItemsSource = [self modifiedItemsSource];
	COItemGraph *modifiedItems = [self modifiedItemsSnapshot];
    
    if ([[modifiedItems itemUUIDs] count] > 0 || self.shouldMakeEmptyCommit)
    {
		// Validate the graph - see [TestOrderedCompositeRelationship testCompositeCycleWithThreeObjects]
		// Not sure if this is the best approach to detecting cycles in composites but it's a first
		// draft anyway.
		[modifiedItemsSource checkForCyclesInCompositeRelationshipsFromObject: [modifiedItemsSource rootObject]];
		
        ETUUID *mergeParent = nil;
        if (self.mergingBranch != nil)
        {
            mergeParent = [[self.mergingBranch currentRevision] UUID];
            self.mergingBranch = nil;
        }
        
        ETUUID *revUUID = [ETUUID UUID];
		
		[txn writeRevisionWithModifiedItems: modifiedItems
							   revisionUUID: revUUID
								   metadata: metadata
						   parentRevisionID: _currentRevisionUUID
					  mergeParentRevisionID: mergeParent
						 persistentRootUUID: [_persistentRoot UUID]
								 branchUUID: _UUID];

        [txn setCurrentRevision: revUUID
				   headRevision: revUUID
					  forBranch: _UUID
			   ofPersistentRoot: [[self persistentRoot] UUID]];
        
        ETUUID *oldRevUUID = _currentRevisionUUID;
		ETUUID *oldHeadRevUUID = _headRevisionUUID;
        ETAssert(oldRevUUID != nil);
        ETAssert(oldHeadRevUUID != nil);
        ETAssert(revUUID != nil);
        _currentRevisionUUID = revUUID;
		_headRevisionUUID = revUUID;
        self.shouldMakeEmptyCommit = NO;
        
        [[self editingContext] recordBranchSetCurrentRevisionUUID: _currentRevisionUUID
                                                  oldRevisionUUID: oldRevUUID
												 headRevisionUUID: _currentRevisionUUID
											  oldHeadRevisionUUID: oldHeadRevUUID
                                                       ofBranch: self];
		if (modifiedItemsSource == _objectGraph)
		{
			[_objectGraph clearChangeTracking];
			if (self == [self.persistentRoot currentBranch])
			{
				[[self.persistentRoot objectGraphContext] setItemGraph: _objectGraph];
			}
		}
		else
		{
			ETAssert(modifiedItemsSource == [_persistentRoot objectGraphContext]);
			[[_persistentRoot objectGraphContext] clearChangeTracking];
			[_objectGraph setItemGraph: [_persistentRoot objectGraphContext]];
		}
    }

    // Write branch undeletion
    
    if (![self isDeleted] && [[self branchInfo] isDeleted])
    {
        [txn undeleteBranch: _UUID
		   ofPersistentRoot: [[self persistentRoot] UUID]];
		
        [[self editingContext] recordBranchUndeletion: self];
    }
}

- (void)saveDeletionWithTransaction: (COStoreTransaction *)txn
{
    if ([self isDeleted] && ![[self branchInfo] isDeleted])
    {
        [txn deleteBranch: _UUID ofPersistentRoot: [[self persistentRoot] UUID]];
        [[self editingContext] recordBranchDeletion: self];
    }    
}

- (void)didMakeInitialCommitWithRevisionUUID: (ETUUID *)aRevisionUUID transaction: (COStoreTransaction *)txn
{
    NSParameterAssert(aRevisionUUID != nil);
    
    // Write metadata
    // FIXME: Copied-n-pasted from above
    if (_metadataChanged)
    {
        [txn setMetadata: _metadata
			   forBranch: _UUID
		ofPersistentRoot: [[self persistentRoot] UUID]];
        
        [[self editingContext] recordBranchSetMetadata: self
                                           oldMetadata: [[self branchInfo] metadata]];
        
        _metadataChanged = NO;
    }
    
    ETAssert(_isCreated == NO);
    
    _currentRevisionUUID =  aRevisionUUID;
	_headRevisionUUID = aRevisionUUID;
    _isCreated = YES;
    
    [_objectGraph clearChangeTracking];
    
    ETAssert([[_objectGraph changedObjects] count] == 0);
}

- (void)reloadAtRevision: (CORevision *)revision
{
    NSParameterAssert(revision != nil);
    
    // TODO: Use optimized method on the store to get a delta for more performance
    
	id <COItemGraph> aGraph = [[self store] itemGraphForRevisionUUID: [revision UUID]
	                                                  persistentRoot: [[self persistentRoot] UUID]];
    
    [_objectGraph setItemGraph: aGraph];
	[_objectGraph removeUnreachableObjects];
	
	if (self == [self.persistentRoot currentBranch])
	{
		[[self.persistentRoot objectGraphContext] setItemGraph: aGraph];
		[[self.persistentRoot objectGraphContext] removeUnreachableObjects];
	}
}

// TODO: Remove or rewrite... The loop in the middle seems to do nothing.
- (CORevision *)revisionWithUUID: (ETUUID *)aRevisionID
{
    CORevision *oldest = [self initialRevision];
    CORevision *rev = [self currentRevision];
    do
    {
        if ([[rev UUID] isEqual: aRevisionID])
        {
            return rev;
        }
    }
    while (![rev isEqual: oldest]);
    
    return nil;
}

- (COMergeInfo *) mergeInfoForMergingBranch: (COBranch *)aBranch
{
    ETUUID *lca = [COLeastCommonAncestor commonAncestorForCommit: [[aBranch currentRevision] UUID]
													   andCommit: [[self currentRevision] UUID]
												  persistentRoot: [[self persistentRoot] UUID]
														   store: [self store]];
    id <COItemGraph> baseGraph = [[self store] itemGraphForRevisionUUID: lca
	                                                     persistentRoot: [[self persistentRoot] UUID]];
    
    return [self diffForMergingGraphWithSelf: [aBranch objectGraphContext]
                                revisionUUID: [[aBranch currentRevision] UUID]
                                   baseGraph: baseGraph
                              baseRevisionID: lca];
}

- (COMergeInfo *) mergeInfoForMergingRevision: (CORevision *)aRevision
{
    ETUUID *lca = [COLeastCommonAncestor commonAncestorForCommit: [aRevision UUID]
													   andCommit: [[self currentRevision] UUID]
												  persistentRoot: [[self persistentRoot] UUID]
														   store: [self store]];
    id <COItemGraph> baseGraph = [[self store] itemGraphForRevisionUUID: lca
	                                                     persistentRoot: [[self persistentRoot] UUID]];
    id <COItemGraph> mergeGraph = [[self store] itemGraphForRevisionUUID: [aRevision UUID]
	                                                      persistentRoot: [[self persistentRoot] UUID]];

    return [self diffForMergingGraphWithSelf: mergeGraph
                                revisionUUID: [aRevision UUID]
                                   baseGraph: baseGraph
                              baseRevisionID: lca];
}

- (COMergeInfo *) diffForMergingGraphWithSelf: (id <COItemGraph>)mergeGraph
                                 revisionUUID: (ETUUID *)mergeRevisionUUID
									baseGraph: (id <COItemGraph>)baseGraph
							   baseRevisionID: (ETUUID *)aBaseRevisionID
{
    COItemGraphDiff *mergingBranchDiff = [COItemGraphDiff diffItemTree: baseGraph
	                                                      withItemTree: mergeGraph
	                                                  sourceIdentifier: @"merged"];
    COItemGraphDiff *selfDiff = [COItemGraphDiff diffItemTree: baseGraph
	                                             withItemTree: [self objectGraphContext]
	                                         sourceIdentifier: @"self"];
    COItemGraphDiff *merged = [selfDiff itemTreeDiffByMergingWithDiff: mergingBranchDiff];

    COMergeInfo *result = [[COMergeInfo alloc] init];

    result.mergeDestinationRevision = [self currentRevision];
    result.mergeSourceRevision = [[self editingContext] revisionForRevisionUUID: mergeRevisionUUID
	                                                         persistentRootUUID: [[self persistentRoot] UUID]];
    result.baseRevision = [[self editingContext] revisionForRevisionUUID: aBaseRevisionID
	                                                  persistentRootUUID: [[self persistentRoot] UUID]];
    result.diff = merged;

    return result;
}

- (void)didUpdate
{
	[[NSNotificationCenter defaultCenter] 
		postNotificationName: ETCollectionDidUpdateNotification object: self];
}

- (void)updateRevisions
{
	CORevision *currentRev = [[self editingContext] revisionForRevisionUUID: _currentRevisionUUID
	                                                     persistentRootUUID: [[self persistentRoot] UUID]];

	if ([currentRev isEqual: [_revisions lastObject]] || _revisions == nil)
		return;

	BOOL isNewCommit = [[currentRev parentRevision] isEqual: [_revisions lastObject]];

	if (isNewCommit)
	{
		[_revisions addObject: currentRev];
	}
	else
	{
		// TODO: Optimize to reload just the new nodes
		[self reloadRevisions];
	}
	[self didUpdate];
}

- (void)updateWithBranchInfo: (COBranchInfo *)branchInfo
{
    NSParameterAssert(branchInfo != nil);
    
    _currentRevisionUUID =  [branchInfo currentRevisionUUID];
	_headRevisionUUID = [branchInfo headRevisionUUID];
    _metadata =  [NSMutableDictionary dictionaryWithDictionary:[branchInfo metadata]];
    _isCreated = YES;
    _parentBranchUUID = [branchInfo parentBranchUUID];
	
    id<COItemGraph> aGraph =
		[[_persistentRoot store] itemGraphForRevisionUUID: _currentRevisionUUID
		                                   persistentRoot: [[self persistentRoot] UUID]];
    [_objectGraph setItemGraph: aGraph];
	
	[self updateRevisions];
}

- (id)rootObject
{
    return [_objectGraph rootObject];
}

- (COObjectGraphContext *)modifiedItemsSource
{
	COObjectGraphContext *graph = nil;

	if (self == [_persistentRoot currentBranch]
		&& [[_persistentRoot objectGraphContext] hasChanges])
	{
		graph = [_persistentRoot objectGraphContext];
		
		if ([_objectGraph hasChanges])
		{
			[NSException raise: NSGenericException
						format: @"You appear to have modified both [persistentRoot objectGraphContext] and "
								"[[persistentRoot currentBranch] objectGraphContext]"];
		}
	}
	else
	{
		graph = _objectGraph;
	}

	return graph;
}

- (COItemGraph *)modifiedItemsSnapshot
{
    NSSet *objects = nil;
    COObjectGraphContext *graph = [self modifiedItemsSource];
	
    if (_currentRevisionUUID == nil)
    {
        objects = [graph loadedObjects];
    }
    else
    {
        objects = [graph changedObjects];
    }
    
    NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
    
    for (COObject *obj in objects)
    {
        COItem *item = [graph itemForUUID: [obj UUID]];

        [dict setObject: item forKey: [obj UUID]];

		for (ETUUID *itemUUID in [[obj additionalStoreItemUUIDs] objectEnumerator])
		{
			[dict setObject: [obj additionalStoreItemForUUID: itemUUID]
			         forKey: itemUUID];
		}
    }
    
    return [[COItemGraph alloc] initWithItemForUUID: dict
	                                   rootItemUUID: [graph rootItemUUID]];
}

- (NSMutableArray *)revisionsWithOptions: (COBranchRevisionReadingOptions)options
{
	NSArray *revInfos = [[self store] revisionInfosForBranchUUID: [self UUID]
	                                                     options: options];
	NSMutableArray *revs = [NSMutableArray array];
	CORevisionCache *cache =
		[CORevisionCache cacheForStoreUUID: [[[self editingContext] store] UUID]];

	for (CORevisionInfo *revInfo in revInfos)
	{
		[revs addObject: [[CORevision alloc] initWithCache: cache
		                                      revisionInfo: revInfo]];
	}
	return revs;
}

- (void)reloadRevisions
{
	_revisions = [self revisionsWithOptions: COBranchRevisionReadingParentBranches];
}

- (NSArray *)nodes
{
	if (_revisions == nil)
	{
		[self reloadRevisions];
	}
	return [_revisions copy];
}

- (id)nextNodeOnTrackFrom: (id <COTrackNode>)aNode backwards: (BOOL)back
{
	NSInteger nodeIndex = [[self nodes] indexOfObject: aNode];
	
	if (nodeIndex == NSNotFound)
	{
		[NSException raise: NSInvalidArgumentException
		            format: @"Node %@ must belong to the track %@ to retrieve the previous or next node", aNode, self];
	}
	if (back)
	{
		nodeIndex--;
	}
	else
	{
		nodeIndex++;
	}
	
	BOOL hasNoPreviousOrNextNode = (nodeIndex < 0 || nodeIndex >= [[self nodes] count]);
	
	if (hasNoPreviousOrNextNode)
	{
		return nil;
	}
	return [[self nodes] objectAtIndex: nodeIndex];
}

- (id <COTrackNode>)currentNode
{
	return [self currentRevision];
}

- (BOOL)setCurrentNode: (id <COTrackNode>)node
{
	INVALIDARG_EXCEPTION_TEST(node, [node isKindOfClass: [CORevision class]]);
	[self setCurrentRevision: (CORevision *)node];
	[self didUpdate];
	
	// TODO: Should return NO if self.supportsRevert is NO and this is a revert
	return YES;
}

- (void)undoNode: (id <COTrackNode>)aNode
{
	[self selectiveApplyFromRevision: (CORevision *)aNode
	                      toRevision: [(CORevision *)aNode parentRevision]];
}

- (void)redoNode: (id <COTrackNode>)aNode
{
	[self selectiveApplyFromRevision: [(CORevision *)aNode parentRevision]
	                      toRevision: (CORevision *)aNode];
}

- (COItemGraphDiff *)diffToSelectivelyApplyChangesFromRevision: (CORevision *)start
                                                    toRevision: (CORevision *)end
{
    COItemGraph *currentGraph = [[self store] itemGraphForRevisionUUID: [[self currentRevision] UUID]
														persistentRoot: [[self persistentRoot] UUID]];
    
    COItemGraph *oldGraph = [[self store] itemGraphForRevisionUUID: [start UUID]
	                                                persistentRoot: [[self persistentRoot] UUID]];
    COItemGraph *newGraph = [[self store] itemGraphForRevisionUUID: [end UUID]
	                                                persistentRoot: [[self persistentRoot] UUID]];
    
    COItemGraphDiff *diff1 = [COItemGraphDiff diffItemTree: oldGraph
	                                          withItemTree: newGraph
	                                      sourceIdentifier: @"diff1"];
    COItemGraphDiff *diff2 = [COItemGraphDiff diffItemTree: oldGraph
	                                          withItemTree: currentGraph
	                                      sourceIdentifier: @"diff2"];
    
    return [diff1 itemTreeDiffByMergingWithDiff: diff2];
}

- (void)selectiveApplyFromRevision: (CORevision *)start
						toRevision: (CORevision *)end
{
	COItemGraphDiff *merged = [self diffToSelectivelyApplyChangesFromRevision: start
	                                                               toRevision: end];
	COItemGraph *oldGraph = [[self store] itemGraphForRevisionUUID: [start UUID]
	                                                persistentRoot: [[self persistentRoot] UUID]];

	id <COItemGraph> result = [merged itemTreeWithDiffAppliedToItemGraph: oldGraph];

	// FIXME: Works, but an ugly API mismatch when setting object graph context contents
	NSMutableArray *items = [NSMutableArray array];

	for (ETUUID *uuid in [result itemUUIDs])
	{
		[items addObject: [result itemForUUID: uuid]];
	}
	
	// FIXME: Handle cross-persistent root relationship constraint violations,
	// if we introduce those
	[[self objectGraphContext] insertOrUpdateItems: items];
}

- (BOOL)isOrdered
{
	return YES;
}

- (id)content
{
	return [self nodes];
}

- (NSArray *)contentArray
{
	return [NSArray arrayWithArray: [self nodes]];
}

@end
