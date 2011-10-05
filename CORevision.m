#import "CORevision.h"
#import "FMDatabase.h"
#import "COStore.h"

#pragma GCC diagnostic ignored "-Wprotocol"

@implementation CORevision

+ (void) initialize
{
	if (self != [CORevision class])
		return;

	[self applyTraitFromClass: [ETCollectionTrait class]];
}

- (id)initWithStore: (COStore *)aStore revisionNumber: (uint64_t)aRevision
{
	SUPERINIT;
	ASSIGN(store, aStore);
	revisionNumber = aRevision;
	return self;
}

- (void)dealloc
{
	DESTROY(store);
	[super dealloc];
}

- (NSArray *)propertyNames
{
	return [[super propertyNames] arrayByAddingObjectsFromArray: 
		A(@"revisionNumber", @"UUID", @"date", @"type", @"metadata", @"changedObjectUUIDs")];
}

- (COStore *)store
{
	return store;
}

- (uint64_t)revisionNumber
{
	return revisionNumber;
}

- (ETUUID *)UUID
{
	return nil;
}

- (NSDate *)date
{
	return nil;
}

- (NSString *)type
{
	return nil;
}

- (NSDictionary *)metadata
{
	FMResultSet *rs = [store->db executeQuery:@"SELECT plist FROM commitMetadata WHERE revisionnumber = ?",
						[NSNumber numberWithUnsignedLongLong: revisionNumber]];
	if ([rs next])
	{
		NSData *data = [rs dataForColumnIndex: 0];
		id plist = [NSPropertyListSerialization propertyListFromData: data
													mutabilityOption: NSPropertyListImmutable
															  format: NULL
													errorDescription: NULL];
		[rs close];
		return plist;
	}
	[rs close];	
	[NSException raise: NSInternalInconsistencyException format: @"COCommit -metadata failed"];
	return nil;
}

- (NSArray *)changedObjectUUIDs
{
	NSMutableSet *result = [NSMutableSet set];
	FMResultSet *rs = [store->db executeQuery:@"SELECT objectuuid FROM commits WHERE revisionnumber = ?",
					   [NSNumber numberWithUnsignedLongLong: revisionNumber]];
	while ([rs next])
	{
		[result addObject: [store UUIDForKey: [rs longLongIntForColumnIndex: 0]]];
	}
	[rs close];
	return [result allObjects];
}

- (NSArray *)changedPropertiesForObjectUUID: (ETUUID *)objectUUID
{
	NSMutableArray *result = [NSMutableArray array];
	FMResultSet *rs = [store->db executeQuery:@"SELECT property FROM commits WHERE revisionnumber = ? AND objectuuid = ?",
					   [NSNumber numberWithUnsignedLongLong: revisionNumber],
					   [store keyForUUID: objectUUID]];

	while ([rs next])
	{
		[result addObject: [store propertyForKey: [rs longLongIntForColumnIndex: 0]]];
	}
	[rs close];

	return result;
}

- (NSString *)formattedChangedPropertiesForObjectUUID: (ETUUID *)objectUUID
{
	NSArray *changedProperties = [self changedPropertiesForObjectUUID: objectUUID];
	NSMutableString *description = [NSMutableString string];
	BOOL isList = NO;

	for (NSString *property in changedProperties)
	{
		if (isList)
		{
			[description appendString: @", "];
		}
		[description appendString: property];
		isList = YES;
	}

	return description;
}

- (NSArray *)changedObjectRecords
{
	NSMutableArray *objRecords = [NSMutableArray array];

	for (ETUUID *objectUUID in [self changedObjectUUIDs])
	{
		NSString *changedProperties = [self formattedChangedPropertiesForObjectUUID: objectUUID];
		NSNumber *revNumberObject = [NSNumber numberWithUnsignedLongLong: revisionNumber];
		CORecord *record = AUTORELEASE([[CORecord alloc] initWithDictionary: 
			D(objectUUID, @"UUID", changedProperties, @"properties", revNumberObject, @"revisionNumber")]);

		[objRecords addObject: record];
	}

	return objRecords;
}

- (NSDictionary *)valuesAndPropertiesForObjectUUID: (ETUUID *)object
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	
	FMResultSet *rs = [store->db executeQuery:@"SELECT property, value FROM commits WHERE revisionnumber = ? AND objectuuid = ?",
					   [NSNumber numberWithUnsignedLongLong: revisionNumber],
					   [store keyForUUID: object]];
	while ([rs next])
	{
		NSString *property = [store propertyForKey: [rs longLongIntForColumnIndex: 0]];
		NSData *data = [rs dataForColumnIndex: 1];
		id plist = [NSPropertyListSerialization propertyListFromData: data
													mutabilityOption: NSPropertyListImmutable
															  format: NULL
													errorDescription: NULL];
		if (plist == nil)
		{
			[NSException raise: NSInternalInconsistencyException format: @"Store contained an invalid property list"];
		}
		
		[result setObject: plist forKey: property];
	}
	[rs close];	
	return [NSDictionary dictionaryWithDictionary: result];
}

- (id)content
{
	return 	[self changedObjectRecords];
}

- (NSArray *)contentArray
{
	return [NSArray arrayWithArray: [self changedObjectRecords]];
}

@end