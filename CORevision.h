#import <Foundation/Foundation.h>
#import <EtoileFoundation/EtoileFoundation.h>

@class COStore;

/** 
 * @group Store
 * @abstract A revision represents a commit in the store history.
 *
 * A revision corresponds to various changes, that were committed at the same 
 * time and belong to a single root object and its inner objects. See 
 * -[COStore finishCommit]. 
 *
 * -changedObjectUUIDs and -valuesAndPropertiesForObjectUUID: can be used to 
 * retrieve the committed changes. 
 *
 * CORevision adopts the collection protocol and its content is a record 
 * collection where each CORecord represents a changed object whose properties 
 * are:
 *
 * <deflist>
 * <item>UUID</item><desc>The changed object UUID</desc>
 * <item>properties</item><desc>The properties changed in the object</desc>
 * </deflist>
 */
@interface CORevision : NSObject <ETCollection>
{
	COStore *store;
	uint64_t revisionNumber;
}

/** @taskunit Store */

/** 
 * Returns the store to which the revision and its changed objects belongs to. 
 */
- (COStore *)store;

/** @taskunit History Properties and Metadata */

/** 
 * Returns the revision number.
 *
 * This number shouldn't be used to uniquely identify the revision, unlike -UUID. 
 */
- (uint64_t)revisionNumber;
/** 
 * Returns the revision UUID. 
 */
- (ETUUID *)UUID;
/** 
 * Returns the date at which the revision was committed. 
 */
- (NSDate *)date;
/** 
 * Returns the revision type.
 *
 * e.g. merge, persistent root creation, minor edit, etc.
 * 
 * Note: This type notion is a bit vague currently. 
 */
- (NSString *)type;

/** 
 * Returns the metadata attached to the revision at commit time. 
 */
- (NSDictionary *)metadata;

/** @taskunit Changes */

/** 
 * Returns the UUIDs that correspond to the objects changed by the revision. 
 */ 
- (NSArray *)changedObjectUUIDs;
/** 
 * Returns a property list listing the changed property values per object in the 
 * revision. 
 */
- (NSDictionary *)valuesAndPropertiesForObjectUUID: (ETUUID *)objectUUID;

/** @taskunit Private */

/** 
 * <init />
 * Initializes and returns a new revision object to represent a precise revision 
 * number in the given store. 
 */
- (id)initWithStore: (COStore *)aStore revisionNumber: (uint64_t)anID;

@end