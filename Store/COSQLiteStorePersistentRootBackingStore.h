/**
    Copyright (C) 2012 Eric Wasylishen

    Date:  November 2012
    License:  MIT  (see COPYING)
 */

#import <Foundation/Foundation.h>
#import <CoreObject/COItemGraph.h>

@class FMDatabase;
@class COItemGraph;
@class CORevisionInfo;
@class COSQLiteStore;

/**
 * Database connection for manipulating a persistent root backing store.
 *
 * Not a public class, only intended to be used by COSQLiteStore.
 */
@interface COSQLiteStorePersistentRootBackingStore : NSObject
{
    COSQLiteStore *__weak _store; // weak reference
    ETUUID *_uuid;
    FMDatabase *db_;
    BOOL _shareDB;
	
	/**
	 * Can be cached after being read for the first time, since it can never change
	 */
	ETUUID *_rootObjectUUID;
}

/**
 * @param
 *      aPath the pathn of a directory where the backing store
 *      should be opened or created.
 */
- (id)initWithPersistentRootUUID: (ETUUID*)aUUID
                           store: (COSQLiteStore *)store
                      useStoreDB: (BOOL)share
                           error: (NSError **)error;

- (BOOL)close;

- (CORevisionInfo *) revisionInfoForRevisionUUID: (ETUUID *)aToken;

- (ETUUID *) UUID;
- (ETUUID *) rootUUID;
- (BOOL) hasRevid: (int64_t)revid;

- (COItemGraph *) itemGraphForRevid: (int64_t)revid;

- (COItemGraph *) itemGraphForRevid: (int64_t)revid restrictToItemUUIDs: (NSSet *)itemSet;

/**
 * baseRevid must be < finalRevid.
 * returns nil if baseRevid or finalRevid are not valid revisions.
 */
- (COItemGraph *) partialItemGraphFromRevid: (int64_t)baseRevid toRevid: (int64_t)finalRevid;

- (COItemGraph *) partialItemGraphFromRevid: (int64_t)baseRevid
                                    toRevid: (int64_t)revid
                        restrictToItemUUIDs: (NSSet *)itemSet;

- (BOOL) writeItemGraph: (COItemGraph *)anItemTree
		   revisionUUID: (ETUUID *)aRevisionUUID
		   withMetadata: (NSDictionary *)metadata
			 withParent: (int64_t)aParent
		withMergeParent: (int64_t)aMergeParent
			 branchUUID: (ETUUID *)aBranchUUID
	 persistentrootUUID: (ETUUID *)aPersistentRootUUID
				  error: (NSError **)error;

- (NSIndexSet *) revidsFromRevid: (int64_t)baseRevid toRevid: (int64_t)finalRevid;

/**
 * Unconditionally deletes the specified revisions
 */
- (BOOL) deleteRevids: (NSIndexSet *)revids;

- (NSIndexSet *) revidsUsedRange;

- (int64_t) revidForUUID: (ETUUID *)aUUID;

- (ETUUID *) revisionUUIDForRevid: (int64_t)aRevid;

- (NSArray *)revisionInfosForBranchUUID: (ETUUID *)aBranchUUID
                       headRevisionUUID: (ETUUID *)aHeadRevUUID
                                options: (NSUInteger)options;

- (NSArray *)revisionInfos;

- (uint64_t) fileSize;

- (void) clearBackingStore;

@end
