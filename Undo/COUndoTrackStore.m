/*
    Copyright (C) 2014 Eric Wasylishen

    Date:  February 2014
    License:  MIT  (see COPYING)
 */

#import "COUndoTrackStore.h"
#import "COUndoTrack.h"
#import <EtoileFoundation/EtoileFoundation.h>
#import "FMDatabase.h"
#import "FMDatabaseAdditions.h"
#import "COCommand.h"
#import "CODateSerialization.h"

@implementation COUndoTrackSerializedCommand
@synthesize JSONData, metadata, UUID, parentUUID, trackName, timestamp, sequenceNumber;
@end

@implementation COUndoTrackState
@synthesize trackName, headCommandUUID, currentCommandUUID;
@end

/*
 
 Points to remember about concurrency:
  - The SQLite database is always in a consistent state. In-memory snapshot
    of the DB may be out of date.
 
 Algorithms
 ----------

 Performing an undo or redo on a track:
   - start a transaction
   - check that the state of the track in the DB matches an in memory snapshot
      - If in-memory snapshot is out of date, the command fails.
   - do something external that is "destructive" (i.e. applying and committing changes to the editing context)
   - update the state in the database
   - commit the transaction.
 
   Since this involves doing something destructive to another database partway
   through the transaction, we have a "point of no return", so we should use
   BEGIN EXCLUSIVE TRANSACTION (see http://sqlite.org/lang_transaction.html ).
 
 Pushing command(s) to a track:
  - start a transaction
  - check that the state of the track in the DB matches an in memory snapshot
    - If in-memory snapshot is out of date, update the snapshot and proceed
      (it doesn't matter if the in memory snapshot was out of date)
  - add the command
  - update the track state
  - commit the transaction
 
 
 Note:
 Commands are immutable, so to check the track state in memory matches what's on disk, 
 all that needs to be compared are the current/head commands.
 
 Note that there is a danger of reaching the "commit the transaction" step, 
 and having the commit fail (even though the corresponding editing context
 change, whether it's applying an undo, redo, or simply making a regular commit,
 has already been committed).
 
 This situation is not ideal... but it's not a disaster. Considering the case when the
 user was performing an undo. The undo would have been saved in the editing context,
 but the undo stack wouldbe slightly out of sync (it would not know that the undo was 
 already done.) Both databases are still in a consistent state. 
 Also, as far as I understand, this should be really rare in practice
 ( BEGIN EXCLUSIVE TRANSACTION succeeds, some writes succeed, but the COMMIT fails).
 
 */

@implementation COUndoTrackStore

+ (COUndoTrackStore *) defaultStore
{
    static COUndoTrackStore *store;
    if (store == nil)
    {
        store = [[COUndoTrackStore alloc] init];
    }
    return store;
}

- (id) init
{
    SUPERINIT;
    
    NSArray *libraryDirs = NSSearchPathForDirectoriesInDomains(NSLibraryDirectory, NSUserDomainMask, YES);

    NSString *dir = [[[libraryDirs objectAtIndex: 0]
                      stringByAppendingPathComponent: @"CoreObject"]
                        stringByAppendingPathComponent: @"Undo"];

    [[NSFileManager defaultManager] createDirectoryAtPath: dir
                              withIntermediateDirectories: YES
                                               attributes: nil
                                                    error: NULL];
	
    @autoreleasepool {
		_db = [[FMDatabase alloc] initWithPath: [dir stringByAppendingPathComponent: @"undo.sqlite"]];
		[_db setShouldCacheStatements: YES];
		[_db setLogsErrors: YES];
		assert([_db open]);
		
		// Use write-ahead-log mode
		{
			NSString *result = [_db stringForQuery: @"PRAGMA journal_mode=WAL"];
			if (![@"wal" isEqualToString: result])
			{
				NSLog(@"Enabling WAL mode failed.");
			}
		}

		[_db executeUpdate: @"PRAGMA foreign_keys = ON"];
		if (1 != [_db intForQuery: @"PRAGMA foreign_keys"])
		{
			[NSException raise: NSGenericException format: @"Your SQLite version doesn't support foreign keys"];
		}
		
		[_db executeUpdate: @"CREATE TABLE IF NOT EXISTS commands (id INTEGER PRIMARY KEY AUTOINCREMENT, "
							 "uuid BLOB NOT NULL UNIQUE, parentid INTEGER, trackname STRING NOT NULL, data BLOB NOT NULL, "
							 "metadata BLOB, timestamp INTEGER NOT NULL)"];
		
		[_db executeUpdate: @"CREATE TABLE IF NOT EXISTS tracks (trackname STRING PRIMARY KEY, "
							 "headid INTEGER NOT NULL, currentid INTEGER NOT NULL, "
							 "FOREIGN KEY(headid) REFERENCES commands(id), "
							 "FOREIGN KEY(currentid) REFERENCES commands(id))"];
	}
    return self;
}

- (void) dealloc
{
    [_db close];
}

- (BOOL) beginTransaction
{
    return [_db executeUpdate: @"BEGIN EXCLUSIVE TRANSACTION"];
}

- (BOOL) commitTransaction
{
    return [_db commit];
}

- (NSArray *) trackNames
{
	return [_db arrayForQuery: @"SELECT DISTINCT trackname FROM tracks"];
}

- (COUndoTrackState *) stateForTrackName: (NSString*)aName
{
    FMResultSet *rs = [_db executeQuery: @"SELECT track.trackname, head.uuid AS headuuid, current.uuid AS currentuuid "
										  "FROM tracks AS track "
										  "INNER JOIN commands AS head ON track.headid = head.id "
										  "INNER JOIN commands AS current ON track.currentid = current.id "
										  "WHERE track.trackname = ?", aName];
	COUndoTrackState *result = nil;
    if ([rs next])
    {
		result = [COUndoTrackState new];
		result.trackName = [rs stringForColumn: @"trackname"];
		result.headCommandUUID = [ETUUID UUIDWithData: [rs dataForColumn: @"headuuid"]];
		result.currentCommandUUID = [ETUUID UUIDWithData: [rs dataForColumn: @"currentuuid"]];
    }
    [rs close];
    return result;
}

- (void) setTrackState: (COUndoTrackState *)aState
{
	[_db executeUpdate: @"INSERT OR REPLACE INTO tracks (trackname, headid, currentid) "
						@"VALUES (?, (SELECT id FROM commands WHERE uuid = ?), (SELECT id FROM commands WHERE uuid = ?))",
						aState.trackName, [aState.headCommandUUID dataValue], [aState.currentCommandUUID dataValue]];
}

- (void) removeTrackWithName: (NSString*)aName
{
	[_db executeUpdate: @"DELETE FROM tracks WHERE trackname = ?", aName];
	[_db executeUpdate: @"DELETE FROM commands WHERE trackname = ?", aName];
}

- (NSData *) serialize: (id)json
{
	if (json != nil)
		return [NSJSONSerialization dataWithJSONObject: json options: 0 error: NULL];
	return nil;
}

- (id) deserialize: (NSData *)data
{
	if (data != nil)
		return [NSJSONSerialization JSONObjectWithData: data options: 0 error: NULL];
	return nil;
}

- (void) addCommand: (COUndoTrackSerializedCommand *)aCommand
{
	[_db executeUpdate: @"INSERT INTO commands(uuid, parentid, trackname, data, metadata, timestamp) "
						@"VALUES(?, (SELECT id FROM commands WHERE uuid = ?), ?, ?, ?, ?)",
		[aCommand.UUID dataValue],
		[aCommand.parentUUID dataValue],
		aCommand.trackName,
		[self serialize: aCommand.JSONData],
		[self serialize: aCommand.metadata],
		CODateToJavaTimestamp(aCommand.timestamp)];
	aCommand.sequenceNumber = [_db lastInsertRowId];
}

- (COUndoTrackSerializedCommand *) commandForUUID: (ETUUID *)aUUID
{
    FMResultSet *rs = [_db executeQuery: @"SELECT c.id, parent.uuid AS parentuuid, c.trackname, c.data, c.metadata, c.timestamp "
										  "FROM commands AS c "
										  "LEFT OUTER JOIN commands AS parent ON c.parentid = parent.id "
										  "WHERE c.uuid = ?", [aUUID dataValue]];
	COUndoTrackSerializedCommand *result = nil;
    if ([rs next])
    {
		result = [COUndoTrackSerializedCommand new];
		result.JSONData = [self deserialize: [rs dataForColumn: @"data"]];
		result.metadata = [self deserialize: [rs dataForColumn: @"metadata"]];
		result.UUID = aUUID;
		if ([rs dataForColumn: @"parentuuid"] != nil)
		{
			result.parentUUID = [ETUUID UUIDWithData: [rs dataForColumn: @"parentuuid"]];
		}
		result.trackName = [rs stringForColumn: @"trackname"];
		result.timestamp = CODateFromJavaTimestamp([rs numberForColumn: @"timestamp"]);
		result.sequenceNumber = [rs longForColumn: @"id"];
    }
    [rs close];
    return result;
}

- (void) removeCommandForUUID: (ETUUID *)aUUID
{
	[_db executeUpdate: @"DELETE FROM commands WHERE uuid = ?", [aUUID dataValue]];
}

@end
