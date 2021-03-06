#import "YapDatabaseViewTransaction.h"
#import "YapDatabaseViewPrivate.h"
#import "YapDatabaseViewPage.h"
#import "YapDatabaseViewPageMetadata.h"
#import "YapDatabaseViewChange.h"
#import "YapDatabaseViewChangePrivate.h"
#import "YapAbstractDatabaseExtensionPrivate.h"
#import "YapAbstractDatabasePrivate.h"
#import "YapDatabasePrivate.h"
#import "YapCache.h"
#import "YapDatabaseString.h"
#import "YapDatabaseLogging.h"

#if ! __has_feature(objc_arc)
#warning This file must be compiled with ARC. Use -fobjc-arc flag (or convert project to ARC).
#endif

/**
 * Define log level for this file: OFF, ERROR, WARN, INFO, VERBOSE
 * See YapDatabaseLogging.h for more information.
**/
#if DEBUG
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#else
  static const int ydbLogLevel = YDB_LOG_LEVEL_WARN;
#endif

/**
 * This version number is stored in the yap2 table.
 * If there is a major re-write to this class, then the version number will be incremented,
 * and the class can automatically rebuild the tables as needed.
**/
#define YAP_DATABASE_VIEW_CLASS_VERSION 3

/**
 * The view is tasked with storing ordered arrays of keys.
 * In doing so, it splits the array into "pages" of keys,
 * and stores the pages in the database.
 * This reduces disk IO, as only the contents of a single page are written for a single change.
 * And only the contents of a single page need be read to fetch a single key.
**/
#define YAP_DATABASE_VIEW_MAX_PAGE_SIZE 50

/**
 * ARCHITECTURE OVERVIEW:
 * 
 * A YapDatabaseView allows one to store a ordered array of keys.
 * Furthermore, groups are supported, which means there may be multiple ordered arrays of keys, one per group.
 * 
 * Conceptually this is a very simple concept.
 * But obviously there are memory and performance requirements that add complexity.
 *
 * The view creates two database tables:
 *
 * view_name_key:
 * - key     (string, primary key) : a key from the database table
 * - pageKey (string)              : the primary key in the page table
 * 
 * view_name_page:
 * - pageKey  (string, primary key) : a uuid
 * - data     (blob)                : an array of keys (the page)
 * - metadata (blob)                : a YapDatabaseViewPageMetadata object
 *
 * For both tables "name" is replaced by the registered name of the view.
 *
 * Thus, given a key, we can quickly identify if the key exists in the view (via the key table).
 * And if so we can use the associated pageKey to figure out the group and index of the key.
 *
 * When we open the view, we read all the metadata objects from the page table into memory.
 * We use the metadata to create the two primary data structures:
 *
 * - group_pagesMetadata_dict (NSMutableDictionary) : key(group), value(array of YapDatabaseViewPageMetadata objects)
 * - pageKey_group_dict       (NSMutableDictionary) : key(pageKey), value(group)
 *
 * Given a group, we can use the group_pages_dict to find the associated array of pages (and metadata for each page).
 * Given a pageKey, we can use the pageKey_group_dict to quickly find the associated group.
**/
@implementation YapDatabaseViewTransaction

- (id)initWithViewConnection:(YapDatabaseViewConnection *)inViewConnection
         databaseTransaction:(YapDatabaseReadTransaction *)inDatabaseTransaction
{
	if ((self = [super init]))
	{
		viewConnection = inViewConnection;
		databaseTransaction = inDatabaseTransaction;
	}
	return self;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Extension Lifecycle
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
 *
 * This method is called to create any necessary tables (if needed),
 * as well as populate the view (if needed) by enumerating over the existing rows in the database.
**/
- (BOOL)createIfNeeded
{
	int oldClassVersion = [self intValueForExtensionKey:@"classVersion"];
	int classVersion = YAP_DATABASE_VIEW_CLASS_VERSION;
	
	if (oldClassVersion != classVersion)
	{
		// First time registration
		
		[self dropTablesForOldClassVersion:oldClassVersion];
		
		if (![self createTables]) return NO;
		if (![self populateView]) return NO;
		
		[self setIntValue:classVersion forExtensionKey:@"classVersion"];
		
		int userSuppliedConfigVersion = viewConnection->view->version;
		[self setIntValue:userSuppliedConfigVersion forExtensionKey:@"version"];
	}
	else
	{
		// Check user-supplied config version.
		// We may need to re-populate the database if the groupingBlock or sortingBlock changed.
		
		int oldVersion = [self intValueForExtensionKey:@"version"];
		int newVersion = viewConnection->view->version;
		
		if (oldVersion != newVersion)
		{
			if (![self populateView]) return NO;
			
			[self setIntValue:newVersion forExtensionKey:@"version"];
		}
	}
	
	return YES;
}

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
 *
 * This method is called to prepare the transaction for use.
 *
 * Remember, an extension transaction is a very short lived object.
 * Thus it stores the majority of its state within the extension connection (the parent).
 *
 * Return YES if completed successfully, or if already prepared.
 * Return NO if some kind of error occured.
**/
- (BOOL)prepareIfNeeded
{
	if (viewConnection->group_pagesMetadata_dict && viewConnection->pageKey_group_dict)
	{
		// Already prepared
		return YES;
	}
	
	sqlite3 *db = databaseTransaction->connection->db;
	
	NSString *string = [NSString stringWithFormat:
	    @"SELECT \"pageKey\", \"group\", \"prevPageKey\", \"count\" FROM \"%@\";", [self pageTableName]];
	
	sqlite3_stmt *statement = NULL;
	
	int status = sqlite3_prepare_v2(db, [string UTF8String], -1, &statement, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ (%@): Cannot create 'enumerate_stmt': %d %s",
		            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
		return NO;
	}
	
	// Enumerate over the page rows in the database, and populate our data structure.
	// Each row gives us the following fields:
	//
	// - group
	// - pageKey
	// - prevPageKey
	//
	// From this information we need to piece together the group_pagesMetadata_dict:
	// - dict.key = group
	// - dict.value = properly ordered array of YapDatabaseViewKeyPageMetadata objects
	//
	// To piece together the proper page order we make a temporary dictionary with each link in the linked-list.
	// For example:
	//
	// pageC.prevPage = pageB  =>      B -> C
	// pageB.prevPage = pageA  =>      A -> B
	// pageA.prevPage = nil    => NSNull -> A
	//
	// After the enumeration of all rows is complete, we can simply walk the linked list from the first page.
	
	NSMutableDictionary *groupPageDict = [[NSMutableDictionary alloc] init];
	NSMutableDictionary *groupOrderDict = [[NSMutableDictionary alloc] init];
	
	unsigned int stepCount = 0;
	
	while (sqlite3_step(statement) == SQLITE_ROW)
	{
		stepCount++;
		
		const unsigned char *text0 = sqlite3_column_text(statement, 0);
		int textSize0 = sqlite3_column_bytes(statement, 0);
		
		const unsigned char *text1 = sqlite3_column_text(statement, 1);
		int textSize1 = sqlite3_column_bytes(statement, 1);
		
		const unsigned char *text2 = sqlite3_column_text(statement, 2);
		int textSize2 = sqlite3_column_bytes(statement, 2);
		
		int count = sqlite3_column_int(statement, 3);
		
		NSString *pageKey = [[NSString alloc] initWithBytes:text0 length:textSize0 encoding:NSUTF8StringEncoding];
		NSString *group   = [[NSString alloc] initWithBytes:text1 length:textSize1 encoding:NSUTF8StringEncoding];
		
		NSString *prevPageKey = nil;
		if (textSize2 > 0)
			prevPageKey = [[NSString alloc] initWithBytes:text2 length:textSize2 encoding:NSUTF8StringEncoding];
		
		if (count >= 0)
		{
			YapDatabaseViewPageMetadata *pageMetadata = [[YapDatabaseViewPageMetadata alloc] init];
			pageMetadata->pageKey = pageKey;
			pageMetadata->group = group;
			pageMetadata->prevPageKey = prevPageKey;
			pageMetadata->count = (NSUInteger)count;
			
			NSMutableDictionary *pageDict = [groupPageDict objectForKey:group];
			if (pageDict == nil)
			{
				pageDict = [[NSMutableDictionary alloc] init];
				[groupPageDict setObject:pageDict forKey:group];
			}
			
			NSMutableDictionary *orderDict = [groupOrderDict objectForKey:group];
			if (orderDict == nil)
			{
				orderDict = [[NSMutableDictionary alloc] init];
				[groupOrderDict setObject:orderDict forKey:group];
			}
			
			[pageDict setObject:pageMetadata forKey:pageKey];
			
			if (prevPageKey)
				[orderDict setObject:pageKey forKey:prevPageKey];
			else
				[orderDict setObject:pageKey forKey:[NSNull null]];
		}
		else
		{
			YDBLogWarn(@"%@ (%@): Encountered invalid count: %d", THIS_METHOD, [self registeredName], count);
		}
	}
	
	YDBLogVerbose(@"Processing %u items from %@...", stepCount, [self pageTableName]);
	
	YDBLogVerbose(@"groupPageDict: %@", groupPageDict);
	YDBLogVerbose(@"groupOrderDict: %@", groupOrderDict);
	
	__block BOOL error = ((status != SQLITE_OK) && (status != SQLITE_DONE));
	
	if (error)
	{
		YDBLogError(@"%@ (%@): Error enumerating page table: %d %s",
		            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
	}
	else
	{
		// Initialize ivars in viewConnection.
		// We try not to do this before we know the table exists.
		
		viewConnection->group_pagesMetadata_dict = [[NSMutableDictionary alloc] init];
		viewConnection->pageKey_group_dict = [[NSMutableDictionary alloc] init];
		
		// Enumerate over each group
		
		[groupOrderDict enumerateKeysAndObjectsUsingBlock:^(id _group, id _orderDict, BOOL *stop) {
			
			__unsafe_unretained NSString *group = (NSString *)_group;
			__unsafe_unretained NSMutableDictionary *orderDict = (NSMutableDictionary *)_orderDict;
			
			NSMutableDictionary *pageDict = [groupPageDict objectForKey:group];
			
			// Walk the linked-list to stitch together the pages for this section.
			//
			// NSNull -> firstPageKey
			// firstPageKey -> secondPageKey
			// ...
			// secondToLastPageKey -> lastPageKey
			//
			// And from the keys, we can get the actual pageMetadata using the pageDict.
			
			NSMutableArray *pagesForGroup = [[NSMutableArray alloc] initWithCapacity:[pageDict count]];
			[viewConnection->group_pagesMetadata_dict setObject:pagesForGroup forKey:group];
			
			NSString *pageKey = [orderDict objectForKey:[NSNull null]];
			while (pageKey)
			{
				[viewConnection->pageKey_group_dict setObject:group forKey:pageKey];
				
				YapDatabaseViewPageMetadata *pageMetadata = [pageDict objectForKey:pageKey];
				if (pageMetadata == nil)
				{
					YDBLogError(@"%@ (%@): Invalid key ordering detected in group(%@)",
					            THIS_METHOD, [self registeredName], group);
					
					error = YES;
					break;
				}
				
				[pagesForGroup addObject:pageMetadata];
				pageKey = [orderDict objectForKey:pageKey];
				
				if ([pagesForGroup count] > [orderDict count])
				{
					YDBLogError(@"%@ (%@): Circular key ordering detected in group(%@)",
					            THIS_METHOD, [self registeredName], group);
					
					error = YES;
					break;
				}
			}
			
			// Validate data for this section
			
			if (!error && ([pagesForGroup count] != [orderDict count]))
			{
				YDBLogError(@"%@ (%@): Missing key page(s) in group(%@)",
				            THIS_METHOD, [self registeredName], group);
				
				error = YES;
			}
		}];
	}
	
	// Validate data
	
	if (error)
	{
		// If there was an error opening the view, we need to reset the ivars to nil.
		// These are checked at the beginning of this method as a shortcut.
		
		viewConnection->group_pagesMetadata_dict = nil;
		viewConnection->pageKey_group_dict = nil;
	}
	else
	{
		YDBLogVerbose(@"viewConnection->group_pagesMetadata_dict: %@", viewConnection->group_pagesMetadata_dict);
		YDBLogVerbose(@"viewConnection->pageKey_group_dict: %@", viewConnection->pageKey_group_dict);
	}
	
	sqlite3_finalize(statement);
	return !error;
}

/**
 * Internal method.
 * 
 * This method is used to handle the upgrade process from earlier architectures of this class.
**/
- (void)dropTablesForOldClassVersion:(int)oldClassVersion
{
	if (oldClassVersion == 1)
	{
		// In version 2, we switched from 'view_name_key' to 'view_name_map'.
		// The old table stored key->pageKey mappings.
		// The new table stores rowid->pageKey mappings.
		//
		// So we can drop the old table.
		
		sqlite3 *db = databaseTransaction->connection->db;
		
		NSString *keyTableName = [NSString stringWithFormat:@"view_%@_key", [self registeredName]];
		
		NSString *dropKeyTable = [NSString stringWithFormat:@"DROP TABLE IF EXISTS \"%@\";", keyTableName];
		
		int status = sqlite3_exec(db, [dropKeyTable UTF8String], NULL, NULL, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@ - Failed dropping key table (%@): %d %s",
						THIS_METHOD, keyTableName, status, sqlite3_errmsg(db));
		}
	}
	
	if (oldClassVersion <= 2)
	{
		// In version 3, we changed the columns of the 'view_name_page' table.
		// The old table stored all metadata in a blob.
		// The new table stores each metadata item in its own column.
		//
		// This new layout reduces the amount of data we have to write to the table.
		
		sqlite3 *db = databaseTransaction->connection->db;
		
		NSString *dropPageTable = [NSString stringWithFormat:@"DROP TABLE IF EXISTS \"%@\";", [self pageTableName]];
		
		int status = sqlite3_exec(db, [dropPageTable UTF8String], NULL, NULL, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@ - Failed dropping old page table (%@): %d %s",
						THIS_METHOD, dropPageTable, status, sqlite3_errmsg(db));
		}
	}
}

/**
 * Internal method.
 * 
 * This method is called, if needed, to create the tables for the view.
**/
- (BOOL)createTables
{
	sqlite3 *db = databaseTransaction->connection->db;
	
	NSString *mapTableName = [self mapTableName];
	NSString *pageTableName = [self pageTableName];
	
	YDBLogVerbose(@"Creating view tables for registeredName(%@): %@, %@",
	              [self registeredName], mapTableName, pageTableName);
	
	NSString *createMapTable = [NSString stringWithFormat:
	    @"CREATE TABLE IF NOT EXISTS \"%@\""
	    @" (\"rowid\" INTEGER PRIMARY KEY,"
	    @"  \"pageKey\" CHAR NOT NULL"
	    @" );", mapTableName];
	
	NSString *createPageTable = [NSString stringWithFormat:
	    @"CREATE TABLE IF NOT EXISTS \"%@\""
	    @" (\"pageKey\" CHAR NOT NULL PRIMARY KEY,"
	    @"  \"group\" CHAR NOT NULL,"
		@"  \"prevPageKey\" CHAR,"
		@"  \"count\" INTEGER,"
		@"  \"data\" BLOB"
	    @" );", pageTableName];
	
	int status;
	
	status = sqlite3_exec(db, [createMapTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating map table (%@): %d %s",
		            THIS_METHOD, mapTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	status = sqlite3_exec(db, [createPageTable UTF8String], NULL, NULL, NULL);
	if (status != SQLITE_OK)
	{
		YDBLogError(@"%@ - Failed creating page table (%@): %d %s",
		            THIS_METHOD, pageTableName, status, sqlite3_errmsg(db));
		return NO;
	}
	
	return YES;
}

/**
 * Internal method.
 * 
 * This method is called, if needed, to populate the view.
 * It does so by enumerating the rows in the database, and invoking the usual blocks and insertion methods.
**/
- (BOOL)populateView
{
	// Remove everything from the database
	
	[self removeAllRowids];
	
	// Initialize ivars
	
	viewConnection->group_pagesMetadata_dict = [[NSMutableDictionary alloc] init];
	viewConnection->pageKey_group_dict = [[NSMutableDictionary alloc] init];
	
	// Enumerate the existing rows in the database and populate the view
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	BOOL groupingNeedsObject = view->groupingBlockType == YapDatabaseViewBlockTypeWithObject ||
	                           view->groupingBlockType == YapDatabaseViewBlockTypeWithRow;
	
	BOOL groupingNeedsMetadata = view->groupingBlockType == YapDatabaseViewBlockTypeWithMetadata ||
	                             view->groupingBlockType == YapDatabaseViewBlockTypeWithRow;
	
	BOOL sortingNeedsObject = view->sortingBlockType  == YapDatabaseViewBlockTypeWithObject ||
	                          view->sortingBlockType  == YapDatabaseViewBlockTypeWithRow;
	
	BOOL sortingNeedsMetadata = view->sortingBlockType  == YapDatabaseViewBlockTypeWithMetadata ||
	                            view->sortingBlockType  == YapDatabaseViewBlockTypeWithRow;
	
	BOOL needsObject = groupingNeedsObject || sortingNeedsObject;
	BOOL needsMetadata = groupingNeedsMetadata || sortingNeedsMetadata;
	
	NSString *(^getGroup)(NSString *key, id object, id metadata);
	getGroup = ^(NSString *key, id object, id metadata){
		
		if (view->groupingBlockType == YapDatabaseViewBlockTypeWithKey)
		{
			__unsafe_unretained YapDatabaseViewGroupingWithKeyBlock groupingBlock =
		        (YapDatabaseViewGroupingWithKeyBlock)view->groupingBlock;
			
			return groupingBlock(key);
		}
		else if (view->groupingBlockType == YapDatabaseViewBlockTypeWithObject)
		{
			__unsafe_unretained YapDatabaseViewGroupingWithObjectBlock groupingBlock =
		        (YapDatabaseViewGroupingWithObjectBlock)view->groupingBlock;
			
			return groupingBlock(key, object);
		}
		else if (view->groupingBlockType == YapDatabaseViewBlockTypeWithMetadata)
		{
			__unsafe_unretained YapDatabaseViewGroupingWithMetadataBlock groupingBlock =
		        (YapDatabaseViewGroupingWithMetadataBlock)view->groupingBlock;
			
			return groupingBlock(key, metadata);
		}
		else
		{
			__unsafe_unretained YapDatabaseViewGroupingWithRowBlock groupingBlock =
		        (YapDatabaseViewGroupingWithRowBlock)view->groupingBlock;
			
			return groupingBlock(key, object, metadata);
		}
	};
	
	int flags = (YapDatabaseViewChangedObject | YapDatabaseViewChangedMetadata);
	
	if (needsObject && needsMetadata)
	{
		if (groupingNeedsObject || groupingNeedsMetadata)
		{
			[databaseTransaction _enumerateRowsUsingBlock:
			    ^(int64_t rowid, NSString *key, id object, id metadata, BOOL *stop) {
				
				NSString *group = getGroup(key, object, metadata);
				if (group)
				{
					[self insertRowid:rowid key:key object:object metadata:metadata
					          inGroup:group withChanges:flags isNew:YES];
				}
			}];
		}
		else
		{
			// Optimization: Grouping doesn't require the object or metadata.
			// So we can skip the deserialization step for any rows not in the view.
			
			__block NSString *group = nil;
			[databaseTransaction _enumerateRowsUsingBlock:
			    ^(int64_t rowid, NSString *key, id object, id metadata, BOOL *stop) {
				
				[self insertRowid:rowid key:key object:object metadata:metadata
				          inGroup:group withChanges:flags isNew:YES];
				
			} withFilter:^BOOL(int64_t rowid, NSString *key) {
				
				group = getGroup(key, nil, nil);
				return (group != nil);
			}];
		}
	}
	else if (needsObject && !needsMetadata)
	{
		if (groupingNeedsObject)
		{
			[databaseTransaction _enumerateKeysAndObjectsUsingBlock:
			    ^(int64_t rowid, NSString *key, id object, BOOL *stop) {
				
				NSString *group = getGroup(key, object, nil);
				if (group)
				{
					[self insertRowid:rowid key:key object:object metadata:nil
					          inGroup:group withChanges:flags isNew:YES];
				}
			}];
		}
		else
		{
			// Optimization: Grouping doesn't require the object.
			// So we can skip the deserialization step for any rows not in the view.
			
			__block NSString *group = nil;
			[databaseTransaction _enumerateKeysAndObjectsUsingBlock:
			    ^(int64_t rowid, NSString *key, id object, BOOL *stop) {
				
				[self insertRowid:rowid key:key object:object metadata:nil
				          inGroup:group withChanges:flags isNew:YES];
				
			} withFilter:^BOOL(int64_t rowid, NSString *key) {
				
				group = getGroup(key, nil, nil);
				return (group != nil);
			}];
		}
	}
	else if (!needsObject && needsMetadata)
	{
		if (groupingNeedsMetadata)
		{
			[databaseTransaction _enumerateKeysAndMetadataUsingBlock:
			    ^(int64_t rowid, NSString *key, id metadata, BOOL *stop) {
				
				NSString *group = getGroup(key, nil, metadata);
				if (group)
				{
					[self insertRowid:rowid key:key object:nil metadata:metadata
					          inGroup:group withChanges:flags isNew:YES];
				}
			}];
		}
		else
		{
			// Optimization: Grouping doesn't require the metadata.
			// So we can skip the deserialization step for any rows not in the view.
			
			__block NSString *group = nil;
			[databaseTransaction _enumerateKeysAndMetadataUsingBlock:
			    ^(int64_t rowid, NSString *key, id metadata, BOOL *stop) {
				
				[self insertRowid:rowid key:key object:nil metadata:metadata
				          inGroup:group withChanges:flags isNew:YES];
				
			} withFilter:^BOOL(int64_t rowid, NSString *key) {
				
				group = getGroup(key, nil, nil);
				return (group != nil);
			}];
		}
	}
	else // if (!needsObject && !needsMetadata)
	{
		[databaseTransaction _enumerateKeysUsingBlock:^(int64_t rowid, NSString *key, BOOL *stop) {
			
			NSString *group = getGroup(key, nil, nil);
			if (group)
			{
				[self insertRowid:rowid key:key object:nil metadata:nil
				          inGroup:group withChanges:flags isNew:YES];
			}
		}];
	}
	
	return YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Accessors
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
**/
- (YapAbstractDatabaseTransaction *)databaseTransaction
{
	return databaseTransaction;
}

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
**/
- (YapAbstractDatabaseExtension *)extension
{
	return viewConnection->view;
}

/**
 * Required override method from YapAbstractDatabaseExtensionTransaction.
**/
- (YapAbstractDatabaseExtensionConnection *)extensionConnection
{
	return viewConnection;
}

- (NSString *)registeredName
{
	return [viewConnection->view registeredName];
}

- (NSString *)mapTableName
{
	return [viewConnection->view mapTableName];
}

- (NSString *)pageTableName
{
	return [viewConnection->view pageTableName];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Serialization & Deserialization
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSData *)serializePage:(YapDatabaseViewPage *)page
{
	return [page serialize];
}

- (YapDatabaseViewPage *)deserializePage:(NSData *)data
{
	YapDatabaseViewPage *page = [[YapDatabaseViewPage alloc] init];
	[page deserialize:data];
	
	return page;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Utilities
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSString *)generatePageKey
{
	NSString *key = nil;
	
	CFUUIDRef uuid = CFUUIDCreate(NULL);
	if (uuid)
	{
		key = (__bridge_transfer NSString *)CFUUIDCreateString(NULL, uuid);
		CFRelease(uuid);
	}
	
	return key;
}

/**
 * If the given rowid is in the view, returns the associated pageKey.
 *
 * This method will use the cache(s) if possible.
 * Otherwise it will lookup the value in the map table.
**/
- (NSString *)pageKeyForRowid:(int64_t)rowid
{
	NSString *pageKey = nil;
	NSNumber *rowidNumber = @(rowid);
	
	// Check dirty cache & clean cache
	
	pageKey = [viewConnection->dirtyMaps objectForKey:rowidNumber];
	if (pageKey)
	{
		if ((__bridge void *)pageKey == (__bridge void *)[NSNull null])
			return nil;
		else
			return pageKey;
	}
	
	pageKey = [viewConnection->mapCache objectForKey:rowidNumber];
	if (pageKey)
	{
		if ((__bridge void *)pageKey == (__bridge void *)[NSNull null])
			return nil;
		else
			return pageKey;
	}
	
	// Otherwise pull from the database
	
	sqlite3_stmt *statement = [viewConnection mapTable_getPageKeyForRowidStatement];
	if (statement == NULL)
		return nil;
	
	// SELECT "pageKey" FROM "mapTableName" WHERE "rowid" = ? ;
	
	sqlite3_bind_int64(statement, 1, rowid);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		const unsigned char *text = sqlite3_column_text(statement, 0);
		int textSize = sqlite3_column_bytes(statement, 0);
		
		pageKey = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@ (%@): Error executing statement: %d %s",
		            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	
	if (pageKey)
		[viewConnection->mapCache setObject:pageKey forKey:rowidNumber];
	else
		[viewConnection->mapCache setObject:[NSNull null] forKey:rowidNumber];
	
	return pageKey;
}

/**
 * This method looks up a whole bunch of pageKeys using only a few queries.
 *
 * @param input
 *     A dictionary of the form: @{
 *         @(rowid) = key, ...
 *     }
 * 
 * @return A dictionary of the form: @{
 *         pageKey = @{ @(rowid) = key, ... }
 *     }
**/
- (NSDictionary *)pageKeysForRowids:(NSArray *)rowids withKeyMappings:(NSDictionary *)keyMappings
{
	NSUInteger count = [rowids count];
	if (count == 0)
	{
		return [NSDictionary dictionary];
	}
	
	NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:count];
	
	sqlite3 *db = databaseTransaction->connection->db;
	
	// Sqlite has an upper bound on the number of host parameters that may be used in a single query.
	// We need to watch out for this in case a large array of keys is passed.
	
	NSUInteger maxHostParams = (NSUInteger) sqlite3_limit(db, SQLITE_LIMIT_VARIABLE_NUMBER, -1);
	
	NSUInteger offset = 0;
	do
	{
		NSUInteger left = count - offset;
		NSUInteger numHostParams = MIN(left, maxHostParams);
		
		// SELECT "rowid", "pageKey" FROM "mapTableName" WHERE "rowid" IN (?, ?, ...);
		
		NSUInteger capacity = 50 + (numHostParams * 3);
		NSMutableString *query = [NSMutableString stringWithCapacity:capacity];
		
		[query appendFormat:@"SELECT \"rowid\", \"pageKey\" FROM \"%@\" WHERE \"rowid\" IN (", [self mapTableName]];
		
		for (NSUInteger i = 0; i < numHostParams; i++)
		{
			if (i == 0)
				[query appendFormat:@"?"];
			else
				[query appendFormat:@", ?"];
		}
		
		[query appendString:@");"];
		
		sqlite3_stmt *statement;
		int status;
		
		status = sqlite3_prepare_v2(db, [query UTF8String], -1, &statement, NULL);
		if (status != SQLITE_OK)
		{
			YDBLogError(@"%@ (%@): Error creating statement\n"
			            @" - status(%d), errmsg: %s\n"
			            @" - query: %@",
			            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db), query);
			return nil;
		}
		
		for (NSUInteger i = 0; i < numHostParams; i++)
		{
			int64_t rowid = [[rowids objectAtIndex:(offset + i)] longLongValue];
			
			sqlite3_bind_int64(statement, (int)(i + 1), rowid);
		}
		
		while ((status = sqlite3_step(statement)) == SQLITE_ROW)
		{
			// Extract rowid & pageKey from row
			
			int64_t rowid = sqlite3_column_int64(statement, 0);
			
			const unsigned char *text = sqlite3_column_text(statement, 1);
			int textSize = sqlite3_column_bytes(statement, 1);
			
			NSString *pageKey = [[NSString alloc] initWithBytes:text length:textSize encoding:NSUTF8StringEncoding];
			
			// Add to result dictionary
			
			NSMutableDictionary *subKeyMappings = [result objectForKey:pageKey];
			if (subKeyMappings == nil)
			{
				subKeyMappings = [NSMutableDictionary dictionaryWithCapacity:1];
				[result setObject:subKeyMappings forKey:pageKey];
			}
			
			NSNumber *number = @(rowid);
			NSString *key = [keyMappings objectForKey:number];
			
			[subKeyMappings setObject:key forKey:number];
		}
		
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ (%@): Error executing statement: %d %s",
			            THIS_METHOD, [self registeredName], status, sqlite3_errmsg(db));
			return nil;
		}
		
		
		offset += numHostParams;
		
	} while (offset < count);
	
	return result;
}

/**
 * Fetches the page for the given pageKey.
 * 
 * This method will use the cache(s) if possible.
 * Otherwise it will load the data from the page table and deserialize it.
**/
- (YapDatabaseViewPage *)pageForPageKey:(NSString *)pageKey
{
	YapDatabaseViewPage *page = nil;
	
	// Check dirty cache & clean cache
	
	page = [viewConnection->dirtyPages objectForKey:pageKey];
	if (page) return page;
	
	page = [viewConnection->pageCache objectForKey:pageKey];
	if (page) return page;
	
	// Otherwise pull from the database
	
	sqlite3_stmt *statement = [viewConnection pageTable_getDataForPageKeyStatement];
	if (statement == NULL)
		return nil;
	
	// SELECT data FROM 'pageTableName' WHERE pageKey = ? ;
	
	YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
	sqlite3_bind_text(statement, 1, _pageKey.str, _pageKey.length, SQLITE_STATIC);
	
	int status = sqlite3_step(statement);
	if (status == SQLITE_ROW)
	{
		const void *blob = sqlite3_column_blob(statement, 0);
		int blobSize = sqlite3_column_bytes(statement, 0);
		
		NSData *data = [[NSData alloc] initWithBytesNoCopy:(void *)blob length:blobSize freeWhenDone:NO];
		
		page = [self deserializePage:data];
	}
	else if (status == SQLITE_ERROR)
	{
		YDBLogError(@"%@ (%@): Error executing statement: %d %s",
		            THIS_METHOD, [self registeredName],
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_clear_bindings(statement);
	sqlite3_reset(statement);
	FreeYapDatabaseString(&_pageKey);
	
	// Store in cache if found
	if (page)
		[viewConnection->pageCache setObject:page forKey:pageKey];
	
	return page;
}

- (NSString *)groupForPageKey:(NSString *)pageKey
{
	return [viewConnection->pageKey_group_dict objectForKey:pageKey];
}

- (NSUInteger)indexForRowid:(int64_t)rowid inGroup:(NSString *)group withPageKey:(NSString *)pageKey
{
	// Calculate the offset of the corresponding page within the group.
	
	NSUInteger pageOffset = 0;
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		if ([pageMetadata->pageKey isEqualToString:pageKey])
		{
			break;
		}
		
		pageOffset += pageMetadata->count;
	}
	
	// Fetch the actual page (ordered array of rowid's)
	
	YapDatabaseViewPage *page = [self pageForPageKey:pageKey];
	
	// Find the exact index of the rowid within the page
	
	NSUInteger indexWithinPage = 0;
	BOOL found = [page getIndex:&indexWithinPage ofRowid:rowid];
	
	NSAssert(found, @"Missing rowid in page");
	
	// Return the full index of the rowid within the group
	
	return pageOffset + indexWithinPage;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Logic
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * Use this method once the insertion index of a key is known.
 * 
 * Note: This method assumes the group already exists.
**/
- (void)insertRowid:(int64_t)rowid key:(NSString *)key
                               inGroup:(NSString *)group
                               atIndex:(NSUInteger)index
                   withExistingPageKey:(NSString *)existingPageKey
{
	YDBLogAutoTrace();
	
	NSParameterAssert(key != nil);
	NSParameterAssert(group != nil);
	
	// Find pageMetadata, pageKey and page
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	NSUInteger pageOffset = 0;
	NSUInteger pageIndex = 0;
	
	NSUInteger lastPageIndex = [pagesMetadataForGroup count] - 1;
	
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		// Edge case: key is being inserted at the very end
		
		if ((index < (pageOffset + pm->count)) || (pageIndex == lastPageIndex))
		{
			pageMetadata = pm;
			break;
		}
		else if (index == (pageOffset + pm->count))
		{
			// Optimization:
			// The insertion index is in-between two pages.
			// So it could go at the end of this page, or the beginning of the next page.
			//
			// We always place the key in the next page, unless:
			// - this page has room AND
			// - the next page is already full
			//
			// Related method: splitOversizedPage:
			
			NSUInteger maxPageSize = YAP_DATABASE_VIEW_MAX_PAGE_SIZE;
			
			if (pm->count < maxPageSize)
			{
				YapDatabaseViewPageMetadata *nextpm = [pagesMetadataForGroup objectAtIndex:(pageIndex+1)];
				if (nextpm->count >= maxPageSize)
				{
					pageMetadata = pm;
					break;
				}
			}
		}
		
		pageIndex++;
		pageOffset += pm->count;
	}
	
	NSAssert(pageMetadata != nil, @"Missing pageMetadata in group(%@)", group);
	
	NSString *pageKey = pageMetadata->pageKey;
	YapDatabaseViewPage *page = [self pageForPageKey:pageKey];
	
	YDBLogVerbose(@"Inserting key(%@) in group(%@) at index(%lu) with page(%@) pageOffset(%lu)",
	              key, group, (unsigned long)index, pageKey, (unsigned long)(index - pageOffset));
	
	// Update page (insert rowid)
	
	[page insertRowid:rowid atIndex:(index - pageOffset)];
	
	// Update pageMetadata (increment count)
	
	pageMetadata->count = [page count];
	
	// Mark page as dirty
	
	[viewConnection->dirtyPages setObject:page forKey:pageKey];
	[viewConnection->pageCache setObject:page forKey:pageKey];
	
	// Mark rowid for insertion (if needed - may have already been in group)
	
	if (![pageKey isEqualToString:existingPageKey])
	{
		[viewConnection->dirtyMaps setObject:pageKey forKey:@(rowid)];
		[viewConnection->mapCache setObject:pageKey forKey:@(rowid)];
	}
	
	// Add change to log
	
	[viewConnection->changes addObject:
	    [YapDatabaseViewRowChange insertKey:key inGroup:group atIndex:index]];
	
	[viewConnection->mutatedGroups addObject:group];
	
	// During a transaction we allow pages to grow in size beyond the max page size.
	// This increases efficiency, as we can allow multiple changes to be written,
	// and then only perform the "cleanup" task of splitting the oversized page into multiple pages only once.
	//
	// However, we do want to avoid allowing a single page to grow infinitely large.
	// So we use triggers to ensure pages don't get too big.
	
	NSUInteger trigger = YAP_DATABASE_VIEW_MAX_PAGE_SIZE * 32;
	NSUInteger target = YAP_DATABASE_VIEW_MAX_PAGE_SIZE * 16;
	
	if ([page count] > trigger)
	{
		[self splitOversizedPage:page withPageKey:pageKey toSize:target];
	}
}

/**
 * Use this method after it has been determined that the key should be inserted into the given group.
 * The object and metadata parameters must be properly set (if needed by the sorting block).
 * 
 * This method will use the configured sorting block to find the proper index for the key.
 * It will attempt to optimize this operation as best as possible using a variety of techniques.
**/
- (void)insertRowid:(int64_t)rowid
                key:(NSString *)key
             object:(id)object
           metadata:(id)metadata
            inGroup:(NSString *)group
        withChanges:(int)flags
              isNew:(BOOL)isGuaranteedNew
{
	YDBLogAutoTrace();
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	// Fetch the pages associated with the group.
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	// Is the key already in the group?
	// If so:
	// - its index within the group may or may not have changed.
	// - we can use its existing position as an optimization during sorting.
	
	BOOL tryExistingIndexInGroup = NO;
	NSUInteger existingIndexInGroup = NSNotFound;
	
	NSString *existingPageKey = isGuaranteedNew ? nil : [self pageKeyForRowid:rowid];
	if (existingPageKey)
	{
		// The key is already in the view.
		// Has it changed groups?
		
		NSString *existingGroup = [self groupForPageKey:existingPageKey];
		
		if ([group isEqualToString:existingGroup])
		{
			// The key is already in the group.
			//
			// Find out what its current index is.
			
			existingIndexInGroup = [self indexForRowid:rowid inGroup:group withPageKey:existingPageKey];
			
			if (view->sortingBlockType == YapDatabaseViewBlockTypeWithKey)
			{
				// Sorting is based entirely on the key, which hasn't changed.
				// Thus the position within the view hasn't changed.
				
				[viewConnection->changes addObject:
				    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:existingIndexInGroup]];
				
				return;
			}
			else
			{
				// Possible optimization:
				// Object or metadata was updated, but doesn't affect the position of the row within the view.
				tryExistingIndexInGroup = YES;
			}
		}
		else
		{
			[self removeRowid:rowid key:key withPageKey:existingPageKey inGroup:existingGroup];
			
			// Don't forget to reset the existingPageKey ivar!
			// Or else 'insertKey:inGroup:atIndex:withExistingPageKey:' will be given an invalid existingPageKey.
			existingPageKey = nil;
		}
	}
	
	// Is this a new group ?
	
	if (pagesMetadataForGroup == nil)
	{
		// First object added to group.
		
		NSString *pageKey = [self generatePageKey];
		
		YDBLogVerbose(@"Inserting key(%@) in new group(%@) with page(%@)", key, group, pageKey);
		
		// Create page
		
		YapDatabaseViewPage *page = [[YapDatabaseViewPage alloc] initWithCapacity:YAP_DATABASE_VIEW_MAX_PAGE_SIZE];
		[page addRowid:rowid];
		
		// Create pageMetadata
		
		YapDatabaseViewPageMetadata *pageMetadata = [[YapDatabaseViewPageMetadata alloc] init];
		pageMetadata->pageKey = pageKey;
		pageMetadata->prevPageKey = nil;
		pageMetadata->group = group;
		pageMetadata->count = 1;
		pageMetadata->isNew = YES;
		
		// Add page and pageMetadata to in-memory structures
		
		pagesMetadataForGroup = [[NSMutableArray alloc] initWithCapacity:1];
		[pagesMetadataForGroup addObject:pageMetadata];
		
		[viewConnection->group_pagesMetadata_dict setObject:pagesMetadataForGroup forKey:group];
		[viewConnection->pageKey_group_dict setObject:group forKey:pageKey];
		
		// Mark page as dirty
		
		[viewConnection->dirtyPages setObject:page forKey:pageKey];
		[viewConnection->pageCache setObject:page forKey:pageKey];
		
		// Mark rowid for insertion
		
		[viewConnection->dirtyMaps setObject:pageKey forKey:@(rowid)];
		[viewConnection->mapCache setObject:pageKey forKey:@(rowid)];
		
		// Add change to log
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewSectionChange insertGroup:group]];
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewRowChange insertKey:key inGroup:group atIndex:0]];
		
		[viewConnection->mutatedGroups addObject:group];
		
		return;
	}
	
	// Need to determine the location within the existing group.
	
	// Calculate how many keys are in the group.
	
	NSUInteger count = 0;
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		count += pageMetadata->count;
	}
	
	// Create a block to do a single sorting comparison between the object to be inserted,
	// and some other object within the group at a given index.
	//
	// This block will be invoked repeatedly as we calculate the insertion index.
	
	NSComparisonResult (^compare)(NSUInteger) = ^NSComparisonResult (NSUInteger index){
		
		int64_t anotherRowid = 0;
		
		NSUInteger pageOffset = 0;
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			if ((index < (pageOffset + pageMetadata->count)) && (pageMetadata->count > 0))
			{
				YapDatabaseViewPage *page = [self pageForPageKey:pageMetadata->pageKey];
				
				anotherRowid = [page rowidAtIndex:(index - pageOffset)];
				break;
			}
			else
			{
				pageOffset += pageMetadata->count;
			}
		}
			
		if (view->sortingBlockType == YapDatabaseViewBlockTypeWithKey)
		{
			__unsafe_unretained YapDatabaseViewSortingWithKeyBlock sortingBlock =
			    (YapDatabaseViewSortingWithKeyBlock)view->sortingBlock;
			
			NSString *anotherKey = nil;
			[databaseTransaction getKey:&anotherKey forRowid:anotherRowid];
			
			return sortingBlock(group, key, anotherKey);
		}
		else if (view->sortingBlockType == YapDatabaseViewBlockTypeWithObject)
		{
			__unsafe_unretained YapDatabaseViewSortingWithObjectBlock sortingBlock =
			    (YapDatabaseViewSortingWithObjectBlock)view->sortingBlock;
			
			NSString *anotherKey = nil;
			id anotherObject = nil;
			[databaseTransaction getKey:&anotherKey object:&anotherObject forRowid:anotherRowid];
			
			return sortingBlock(group, key, object, anotherKey, anotherObject);
		}
		else if (view->sortingBlockType == YapDatabaseViewBlockTypeWithMetadata)
		{
			__unsafe_unretained YapDatabaseViewSortingWithMetadataBlock sortingBlock =
			    (YapDatabaseViewSortingWithMetadataBlock)view->sortingBlock;
			
			NSString *anotherKey = nil;
			id anotherMetadata = nil;
			[databaseTransaction getKey:&anotherKey metadata:&anotherMetadata forRowid:anotherRowid];
			
			return sortingBlock(group, key, metadata, anotherKey, anotherMetadata);
		}
		else
		{
			__unsafe_unretained YapDatabaseViewSortingWithRowBlock sortingBlock =
			    (YapDatabaseViewSortingWithRowBlock)view->sortingBlock;
			
			NSString *anotherKey = nil;
			id anotherObject = nil;
			id anotherMetadata = nil;
			[databaseTransaction getKey:&anotherKey
			                     object:&anotherObject
			                   metadata:&anotherMetadata forRowid:anotherRowid];
			
			return sortingBlock(group, key, object, metadata, anotherKey, anotherObject, anotherMetadata);
		}
	};
		
	NSComparisonResult cmp;
	
	// Optimization 1:
	//
	// If the item is already in the group, check to see if its index is the same as before.
	// This handles the common case where an object is updated without changing its position within the view.
	
	if (tryExistingIndexInGroup)
	{
		// Edge case: existing key is the only key in the group
		//
		// (existingIndex == 0) && (count == 1)
		
		BOOL useExistingIndexInGroup = YES;
		
		if (existingIndexInGroup > 0)
		{
			cmp = compare(existingIndexInGroup - 1); // compare vs prev
			
			useExistingIndexInGroup = (cmp != NSOrderedAscending); // object >= prev
		}
		
		if ((existingIndexInGroup + 1) < count && useExistingIndexInGroup)
		{
			cmp = compare(existingIndexInGroup + 1); // compare vs next
			
			useExistingIndexInGroup = (cmp != NSOrderedDescending); // object <= next
		}
		
		if (useExistingIndexInGroup)
		{
			// The item doesn't change position.
			
			YDBLogVerbose(@"Updated key(%@) in group(%@) maintains current index", key, group);
			
			[viewConnection->changes addObject:
				[YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:existingIndexInGroup]];
			
			return;
		}
		else
		{
			// The key has changed position.
			// Remove it from previous position (and don't forget to decrement count).
			
			[self removeRowid:rowid key:key withPageKey:existingPageKey inGroup:group];
			count--;
			
			// Don't forget to reset the existingPageKey ivar!
			// Or else 'insertKey:inGroup:atIndex:withExistingPageKey:' will be given an invalid existingPageKey.
			existingPageKey = nil;
		}
	}
		
	// Optimization 2:
	//
	// A very common operation is to insert objects at the beginning or end of the array.
	// We attempt to notice this trend and optimize around it.
	
	if (viewConnection->lastInsertWasAtFirstIndex && (count > 1))
	{
		cmp = compare(0);
		
		if (cmp == NSOrderedAscending) // object < first
		{
			YDBLogVerbose(@"Insert key(%@) in group(%@) at beginning (optimization)",
			              key, group);
			
			[self insertRowid:rowid key:key inGroup:group atIndex:0 withExistingPageKey:existingPageKey];
			return;
		}
	}
	
	if (viewConnection->lastInsertWasAtLastIndex && (count > 1))
	{
		cmp = compare(count - 1);
		
		if (cmp != NSOrderedAscending) // object >= last
		{
			YDBLogVerbose(@"Insert key(%@) in group(%@) at end (optimization)",
			              key, group);
			
			[self insertRowid:rowid key:key inGroup:group atIndex:count withExistingPageKey:existingPageKey];
			return;
		}
	}
		
	// Otherwise:
	//
	// Binary search operation.
	//
	// This particular algorithm accounts for cases where the objects are not unique.
	// That is, if some objects are NSOrderedSame, then the algorithm returns the largest index possible
	// (within the region where elements are "equal").
	
	NSUInteger loopCount = 0;
	
	NSUInteger min = 0;
	NSUInteger max = count;
	
	while (min < max)
	{
		NSUInteger mid = (min + max) / 2;
		
		cmp = compare(mid);
		
		if (cmp == NSOrderedAscending)
			max = mid;
		else
			min = mid + 1;
		
		loopCount++;
	}
	
	YDBLogVerbose(@"Insert key(%@) in group(%@) took %lu comparisons", key, group, (unsigned long)loopCount);
	
	[self insertRowid:rowid key:key inGroup:group atIndex:min withExistingPageKey:existingPageKey];
	
	viewConnection->lastInsertWasAtFirstIndex = (min == 0);
	viewConnection->lastInsertWasAtLastIndex  = (min == count);
}

/**
 * Use this method (instead of removeKey:) when the pageKey and group are already known.
**/
- (void)removeRowid:(int64_t)rowid key:(NSString *)key withPageKey:(NSString *)pageKey inGroup:(NSString *)group
{
	YDBLogAutoTrace();
	
	NSParameterAssert(key != nil);
	NSParameterAssert(pageKey != nil);
	NSParameterAssert(group != nil);
	
	// Fetch page & pageMetadata
	
	YapDatabaseViewPage *page = [self pageForPageKey:pageKey];
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	NSUInteger pageOffset = 0;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		if ([pm->pageKey isEqualToString:pageKey])
		{
			pageMetadata = pm;
			break;
		}
		
		pageOffset += pm->count;
	}
	
	NSAssert(pageMetadata != nil, @"Missing pageMetadata in group(%@) withPageKey(%@)", group, pageKey);
	
	// Find index within page
	
	NSUInteger indexWithinPage = 0;
	BOOL found = [page getIndex:&indexWithinPage ofRowid:rowid];
	
	if (!found)
	{
		YDBLogError(@"%@ (%@): Key(%@) expected to be in page(%@), but is missing",
		            THIS_METHOD, [self registeredName], key, pageKey);
		return;
	}
	
	YDBLogVerbose(@"Removing key(%@) from page(%@) at index(%lu)", key, page, (unsigned long)indexWithinPage);
	
	// Add change to log
	
	[viewConnection->changes addObject:
	    [YapDatabaseViewRowChange deleteKey:key inGroup:group atIndex:(pageOffset + indexWithinPage)]];
	
	[viewConnection->mutatedGroups addObject:group];
	
	// Update page (by removing key from array)
	
	[page removeRowidAtIndex:indexWithinPage];
	
	// Update page metadata (by decrementing count)
	
	pageMetadata->count = [page count];
	
	// Mark page as dirty
	
	YDBLogVerbose(@"Dirty page(%@)", pageKey);
	
	[viewConnection->dirtyPages setObject:page forKey:pageKey];
	[viewConnection->pageCache setObject:page forKey:pageKey];
	
	// Mark key for deletion
	
	[viewConnection->dirtyMaps setObject:[NSNull null] forKey:@(rowid)];
	[viewConnection->mapCache removeObjectForKey:@(rowid)];
}

/**
 * Use this method when you don't know if the key exists in the view.
**/
- (void)removeRowid:(int64_t)rowid key:(NSString *)key
{
	YDBLogAutoTrace();
	
	// Find out if key is in view
	
	NSString *pageKey = [self pageKeyForRowid:rowid];
	if (pageKey)
	{
		[self removeRowid:rowid key:key withPageKey:pageKey inGroup:[self groupForPageKey:pageKey]];
	}
}

/**
 * Use this method to remove 1 or more keys from a given pageKey & group.
 * 
 * The dictionary is to be of the form:
 * @{
 *     @(rowid) = key,
 * }
**/
- (void)removeRowidsWithKeyMappings:(NSDictionary *)keyMappings pageKey:(NSString *)pageKey inGroup:(NSString *)group
{
	YDBLogAutoTrace();
	
	NSUInteger count = [keyMappings count];
	
	if (count == 0) return;
	if (count == 1)
	{
		for (NSNumber *number in keyMappings)
		{
			int64_t rowid = [number longLongValue];
			NSString *key = [keyMappings objectForKey:number];
			
			[self removeRowid:rowid key:key withPageKey:pageKey inGroup:group];
		}
		return;
	}
	
	NSParameterAssert(pageKey != nil);
	NSParameterAssert(group != nil);
	
	// Fetch page & pageMetadata
	
	YapDatabaseViewPage *page = [self pageForPageKey:pageKey];
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	NSUInteger pageOffset = 0;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		if ([pm->pageKey isEqualToString:pageKey])
		{
			pageMetadata = pm;
			break;
		}
		
		pageOffset += pm->count;
	}
	
	NSAssert(pageMetadata != nil, @"Missing pageMetadata in group(%@) withPageKey(%@)", group, pageKey);
	
	// Find matching indexes within page.
	// And add changes to log.
	// Notes:
	//
	// - We must add the changes in reverse order,
	//     just as if we were deleting them from the array one-at-a-time.
	
	NSUInteger numRemoved = 0;
	
	for (NSUInteger iPlusOne = [page count]; iPlusOne > 0; iPlusOne--)
	{
		NSUInteger i = iPlusOne - 1;
		int64_t rowid = [page rowidAtIndex:i];
		
		NSString *key = [keyMappings objectForKey:@(rowid)];
		if (key)
		{
			[page removeRowidAtIndex:i];
			numRemoved++;
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange deleteKey:key inGroup:group atIndex:(pageOffset + i)]];
		}
	}
	
	[viewConnection->mutatedGroups addObject:group];
	
	YDBLogVerbose(@"Removed %lu key(s) from page(%@)", (unsigned long)numRemoved, page);
	
	if (numRemoved != count)
	{
		YDBLogWarn(@"%@ (%@): Expected to remove %lu, but only found %lu in page(%@)",
		           THIS_METHOD, [self registeredName], (unsigned long)count, (unsigned long)numRemoved, pageKey);
	}
	
	// Update page metadata (by decrementing count)
	
	pageMetadata->count = [page count];
	
	// Mark page as dirty
	
	YDBLogVerbose(@"Dirty page(%@)", pageKey);
	
	[viewConnection->dirtyPages setObject:page forKey:pageKey];
	[viewConnection->pageCache setObject:page forKey:pageKey];
	
	// Mark rowid mappings for deletion
	
	for (NSNumber *number in keyMappings)
	{
		[viewConnection->dirtyMaps setObject:[NSNull null] forKey:number];
		[viewConnection->mapCache removeObjectForKey:number];
	}
}

- (void)removeAllRowids
{
	YDBLogAutoTrace();
	
	sqlite3_stmt *mapStatement = [viewConnection mapTable_removeAllStatement];
	sqlite3_stmt *pageStatement = [viewConnection pageTable_removeAllStatement];
	
	if (mapStatement == NULL || pageStatement == NULL)
		return;
	
	int status;
	
	// DELETE FROM "mapTableName";
	
	YDBLogVerbose(@"DELETE FROM '%@';", [self mapTableName]);
	
	status = sqlite3_step(mapStatement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ (%@): Error in mapStatement: %d %s",
		            THIS_METHOD, [self registeredName],
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	// DELETE FROM 'pageTableName';
	
	YDBLogVerbose(@"DELETE FROM '%@';", [self pageTableName]);
	
	status = sqlite3_step(pageStatement);
	if (status != SQLITE_DONE)
	{
		YDBLogError(@"%@ (%@): Error in pageStatement: %d %s",
		            THIS_METHOD, [self registeredName],
		            status, sqlite3_errmsg(databaseTransaction->connection->db));
	}
	
	sqlite3_reset(mapStatement);
	sqlite3_reset(pageStatement);
	
	for (NSString *group in viewConnection->group_pagesMetadata_dict)
	{
		[viewConnection->changes addObject:[YapDatabaseViewSectionChange resetGroup:group]];
		[viewConnection->mutatedGroups addObject:group];
	}
	
	[viewConnection->group_pagesMetadata_dict removeAllObjects];
	[viewConnection->pageKey_group_dict removeAllObjects];
	
	[viewConnection->mapCache removeAllObjects];
	[viewConnection->pageCache removeAllObjects];
	
	[viewConnection->dirtyMaps removeAllObjects];
	[viewConnection->dirtyPages removeAllObjects];
	[viewConnection->dirtyLinks removeAllObjects];
	
	viewConnection->reset = YES;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Cleanup & Commit
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)splitOversizedPage:(YapDatabaseViewPage *)page withPageKey:(NSString *)pageKey toSize:(NSUInteger)maxPageSize
{
	YDBLogAutoTrace();
	
	// Find associated pageMetadata
	
	NSString *group = [self groupForPageKey:pageKey];
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		if ([pm->pageKey isEqualToString:pageKey])
		{
			pageMetadata = pm;
			break;
		}
	}
	
	// Split the page as many times as needed to make it fit the designated maxPageSize
	
	while (pageMetadata->count > maxPageSize)
	{
		// Get the current pageIndex.
		// This may change during iterations of the while loop.
		
		NSUInteger pageIndex = [pagesMetadataForGroup indexOfObjectIdenticalTo:pageMetadata];
	
		// Check to see if there's room in the previous page
	
		if (pageIndex > 0)
		{
			YapDatabaseViewPageMetadata *prevPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex - 1)];
			
			if (prevPageMetadata->count < maxPageSize)
			{
				// Move objects from beginning of page to end of previous page
				
				YapDatabaseViewPage *prevPage = [self pageForPageKey:prevPageMetadata->pageKey];
				
				NSUInteger excessInPage = pageMetadata->count - maxPageSize;
				NSUInteger spaceInPrevPage = maxPageSize - prevPageMetadata->count;
				
				NSUInteger numToMove = MIN(excessInPage, spaceInPrevPage);
				
				NSRange pageRange = NSMakeRange(0, numToMove);                    // beginning range
				NSRange prevPageRange = NSMakeRange([prevPage count], numToMove); // end range
				
				[prevPage appendRange:pageRange ofPage:page];
				[page removeRange:pageRange];
				
				// Update counts
				
				pageMetadata->count = [page count];
				prevPageMetadata->count = [prevPage count];
				
				// Mark prevPage as dirty.
				// The page is already marked as dirty.
				
				[viewConnection->dirtyPages setObject:prevPage forKey:prevPageMetadata->pageKey];
				[viewConnection->pageCache setObject:prevPage forKey:prevPageMetadata->pageKey];
				
				// Mark rowid mappings as dirty
				
				[prevPage enumerateRowidsWithOptions:0
				                               range:prevPageRange
				                          usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
					
					NSNumber *number = @(rowid);
					
					[viewConnection->dirtyMaps setObject:prevPageMetadata->pageKey forKey:number];
					[viewConnection->mapCache setObject:prevPageMetadata->pageKey forKey:number];
				}];
				
				continue;
			}
		}
		
		// Check to see if there's room in the next page
		
		if ((pageIndex + 1) < [pagesMetadataForGroup count])
		{
			YapDatabaseViewPageMetadata *nextPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex + 1)];
			
			if (nextPageMetadata->count < maxPageSize)
			{
				// Move objects from end of page to beginning of next page
				
				YapDatabaseViewPage *nextPage = [self pageForPageKey:nextPageMetadata->pageKey];
				
				NSUInteger excessInPage = pageMetadata->count - maxPageSize;
				NSUInteger spaceInNextPage = maxPageSize - nextPageMetadata->count;
				
				NSUInteger numToMove = MIN(excessInPage, spaceInNextPage);
				
				NSRange pageRange = NSMakeRange([page count] - numToMove, numToMove); // end range
				NSRange nextPageRange = NSMakeRange(0, numToMove);                    // beginning range
				
				[nextPage prependRange:pageRange ofPage:page];
				[page removeRange:pageRange];
				
				// Update counts
				
				pageMetadata->count = [page count];
				nextPageMetadata->count = [nextPage count];
				
				// Mark nextPage as dirty.
				// The page is already marked as dirty.
				
				[viewConnection->dirtyPages setObject:nextPage forKey:nextPageMetadata->pageKey];
				[viewConnection->pageCache setObject:nextPage forKey:nextPageMetadata->pageKey];
				
				// Mark rowid mappings as dirty
				
				[nextPage enumerateRowidsWithOptions:0
				                               range:nextPageRange
				                          usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
					
					NSNumber *number = @(rowid);
					
					[viewConnection->dirtyMaps setObject:nextPageMetadata->pageKey forKey:number];
					[viewConnection->mapCache setObject:nextPageMetadata->pageKey forKey:number];
				}];
				
				continue;
			}
		}
	
		// Create new page and pageMetadata.
		// Insert into array.
		
		NSUInteger excessInPage = pageMetadata->count - maxPageSize;
		NSUInteger numToMove = MIN(excessInPage, maxPageSize);
		
		NSString *newPageKey = [self generatePageKey];
		YapDatabaseViewPage *newPage = [[YapDatabaseViewPage alloc] initWithCapacity:numToMove];
		
		// Create new pageMetadata
		
		YapDatabaseViewPageMetadata *newPageMetadata = [[YapDatabaseViewPageMetadata alloc] init];
		newPageMetadata->pageKey = newPageKey;
		newPageMetadata->prevPageKey = pageMetadata->pageKey;
		newPageMetadata->group = pageMetadata->group;
		newPageMetadata->isNew = YES;
		
		// Insert new pageMetadata into array
		
		[pagesMetadataForGroup insertObject:newPageMetadata atIndex:(pageIndex + 1)];
		
		[viewConnection->pageKey_group_dict setObject:newPageMetadata->group
		                                       forKey:newPageMetadata->pageKey];
	
		// Update linked-list (if needed)
		
		if ((pageIndex + 2) < [pagesMetadataForGroup count])
		{
			YapDatabaseViewPageMetadata *nextPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex + 2)];
			nextPageMetadata->prevPageKey = newPageKey;
			
			[viewConnection->dirtyLinks setObject:nextPageMetadata forKey:nextPageMetadata->pageKey];
		}
		
		// Move objects from end of page to beginning of new page
		
		NSRange pageRange = NSMakeRange([page count] - numToMove, numToMove); // end range
		
		[newPage appendRange:pageRange ofPage:page];
		[page removeRange:pageRange];
		
		// Update counts
	
		pageMetadata->count = [page count];
		newPageMetadata->count = [newPage count];
		
		// Mark newPage as dirty.
		// The page is already marked as dirty.
		
		[viewConnection->dirtyPages setObject:newPage forKey:newPageKey];
		[viewConnection->pageCache setObject:newPage forKey:newPageKey];
		
		// Mark rowid mappings as dirty
		
		[newPage enumerateRowidsUsingBlock:^(int64_t rowid, NSUInteger idx, BOOL *stop) {
			
			NSNumber *number = @(rowid);
			
			[viewConnection->dirtyMaps setObject:newPageKey forKey:number];
			[viewConnection->mapCache setObject:newPageKey forKey:number];
		}];
			
	} // end while (pageMetadata->count > maxPageSize)
}

- (void)dropEmptyPage:(YapDatabaseViewPage *)page withPageKey:(NSString *)pageKey
{
	YDBLogAutoTrace();
	
	// Find associated pageMetadata
	
	NSString *group = [self groupForPageKey:pageKey];
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	YapDatabaseViewPageMetadata *pageMetadata = nil;
	NSUInteger pageIndex = 0;
	
	for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
	{
		if ([pm->pageKey isEqualToString:pageKey])
		{
			pageMetadata = pm;
			break;
		}
		
		pageIndex++;
	}
	
	NSAssert(pageMetadata != nil, @"Missing pageMetadata in group(%@)", group);
	
	// Update linked list (if needed)
	
	if ((pageIndex + 1) < [pagesMetadataForGroup count])
	{
		YapDatabaseViewPageMetadata *nextPageMetadata = [pagesMetadataForGroup objectAtIndex:(pageIndex + 1)];
		nextPageMetadata->prevPageKey = pageMetadata->prevPageKey;
		
		[viewConnection->dirtyLinks setObject:nextPageMetadata forKey:nextPageMetadata->pageKey];
	}
	
	// Drop page
	
	[pagesMetadataForGroup removeObjectAtIndex:pageIndex];
	[viewConnection->pageKey_group_dict removeObjectForKey:pageMetadata->pageKey];
	
	// Mark page as dropped
	
	[viewConnection->dirtyPages setObject:[NSNull null] forKey:pageMetadata->pageKey];
	[viewConnection->pageCache removeObjectForKey:pageMetadata->pageKey];
	
	[viewConnection->dirtyLinks removeObjectForKey:pageMetadata->pageKey];
	
	// Maybe drop group
	
	if ([pagesMetadataForGroup count] == 0)
	{
		YDBLogVerbose(@"Dropping empty group(%@)", pageMetadata->group);
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewSectionChange deleteGroup:pageMetadata->group]];
		
		[viewConnection->group_pagesMetadata_dict removeObjectForKey:pageMetadata->group];
	}
}

/**
 * This method is only called if within a readwrite transaction.
 * 
 * Extensions may implement it to perform any "cleanup" before the changeset is requested.
 * Remember, the changeset is requested before the commitTransaction method is invoked.
**/
- (void)preCommitReadWriteTransaction
{
	YDBLogAutoTrace();
	
	// During the readwrite transaction we do nothing to enforce the pageSize restriction.
	// Multiple modifications during a transaction make it non worthwhile.
	//
	// Instead we wait til the transaction has completed
	// and then we can perform all such cleanup in a single step.
		
	NSUInteger maxPageSize = YAP_DATABASE_VIEW_MAX_PAGE_SIZE;
	
	// Get all the dirty pageMetadata objects.
	// We snapshot the items so we can make modifications as we enumerate.
	
	NSArray *pageKeys = [viewConnection->dirtyPages allKeys];
	
	// Step 1 is to "expand" the oversized pages.
	//
	// This means either splitting them in 2,
	// or allowing items to spill over into a neighboring page (that has room).
	
	for (NSString *pageKey in pageKeys)
	{
		YapDatabaseViewPage *page = [viewConnection->dirtyPages objectForKey:pageKey];
		
		if ([page count] > maxPageSize)
		{
			[self splitOversizedPage:page withPageKey:pageKey toSize:maxPageSize];
		}
	}
	
	// Step 2 is to "collapse" undersized pages.
	//
	// For now, this simply means dropping empty pages.
	// In the future we may also combine neighboring pages if they're small enough.
	//
	// Note: We do this after "expansion" to allow undersized pages to first accomodate overflow.
	
	for (NSString *pageKey in pageKeys)
	{
		YapDatabaseViewPage *page = [viewConnection->dirtyPages objectForKey:pageKey];
		
		if ([page count] == 0)
		{
			[self dropEmptyPage:page withPageKey:pageKey];
		}
	}
}

- (void)commitTransaction
{
	YDBLogAutoTrace();
	
	// During the transaction we stored all changes in the "dirty" dictionaries.
	// This allows the view to make multiple changes to a page, yet only write it once.
	
	YDBLogVerbose(@"viewConnection->dirtyPages: %@", viewConnection->dirtyPages);
	YDBLogVerbose(@"viewConnection->dirtyLinks: %@", viewConnection->dirtyLinks);
	YDBLogVerbose(@"viewConnection->dirtyMaps: %@", viewConnection->dirtyMaps);
	
	// Write dirty pages to table (along with associated dirty metadata)
	
	[viewConnection->dirtyPages enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		__unsafe_unretained NSString *pageKey = (NSString *)key;
		__unsafe_unretained YapDatabaseViewPage *page = (YapDatabaseViewPage *)obj;
		
		BOOL needsInsert = NO;
		BOOL hasDirtyLink = NO;
		
		YapDatabaseViewPageMetadata *pageMetadata = nil;
		
		pageMetadata = [viewConnection->dirtyLinks objectForKey:pageKey];
		if (pageMetadata)
		{
			hasDirtyLink = YES;
		}
		else
		{
			NSString *group = [self groupForPageKey:pageKey];
			NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
			
			for (YapDatabaseViewPageMetadata *pm in pagesMetadataForGroup)
			{
				if ([pm->pageKey isEqualToString:pageKey])
				{
					pageMetadata = pm;
					break;
				}
			}
		}
		
		if (pageMetadata && pageMetadata->isNew)
		{
			needsInsert = YES;
			pageMetadata->isNew = NO; // Clear flag
		}
		
		if ((id)page == (id)[NSNull null])
		{
			sqlite3_stmt *statement = [viewConnection pageTable_removeForPageKeyStatement];
			if (statement == NULL) {
				*stop = YES;
				return;//from block
			}
			
			// DELETE FROM "pageTableName" WHERE "pageKey" = ?;
			
			YDBLogVerbose(@"DELETE FROM '%@' WHERE 'pageKey' = ?;\n"
			              @" - pageKey: %@", [self pageTableName], pageKey);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 1, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[1a]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_pageKey);
		}
		else if (needsInsert)
		{
			sqlite3_stmt *statement = [viewConnection pageTable_insertForPageKeyStatement];
			if (statement == NULL) {
				*stop = YES;
				return;//from block
			}
			
			// INSERT INTO "pageTableName" ("pageKey", "group", "prevPageKey", "count", "data") VALUES (?, ?, ?, ?, ?);
			
			YDBLogVerbose(@"INSERT INTO '%@' ('pageKey', 'group', 'prevPageKey', 'count', 'data') VALUES (?,?,?,?,?);\n"
			              @" - pageKey   : %@\n"
			              @" - group     : %@\n"
			              @" - prePageKey: %@\n"
			              @" - count     : %d", [self pageTableName], pageKey,
			              pageMetadata->group, pageMetadata->prevPageKey, (int)pageMetadata->count);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 1, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			YapDatabaseString _group; MakeYapDatabaseString(&_group, pageMetadata->group);
			sqlite3_bind_text(statement, 2, _group.str, _group.length, SQLITE_STATIC);
			
			YapDatabaseString _prevPageKey; MakeYapDatabaseString(&_prevPageKey, pageMetadata->prevPageKey);
			if (pageMetadata->prevPageKey) {
				sqlite3_bind_text(statement, 3, _prevPageKey.str, _prevPageKey.length, SQLITE_STATIC);
			}
			
			sqlite3_bind_int(statement, 4, (int)(pageMetadata->count));
			
			__attribute__((objc_precise_lifetime)) NSData *rawData = [self serializePage:page];
			sqlite3_bind_blob(statement, 5, rawData.bytes, (int)rawData.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[1b]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_prevPageKey);
			FreeYapDatabaseString(&_group);
			FreeYapDatabaseString(&_pageKey);
		}
		else if (hasDirtyLink)
		{
			sqlite3_stmt *statement = [viewConnection pageTable_updateAllForPageKeyStatement];
			if (statement == NULL) {
				*stop = YES;
				return;//from block
			}
			
			// UPDATE "pageTableName" SET "prevPageKey" = ?, "count" = ?, "data" = ? WHERE "pageKey" = ?;
			
			YDBLogVerbose(@"UPDATE '%@' SET 'prevPageKey' = ?, 'count' = ?, 'data' = ? WHERE 'pageKey' = ?;\n"
			              @" - pageKey    : %@\n"
			              @" - prevPageKey: %@\n"
			              @" - count      : %d", [self pageTableName], pageKey,
			              pageMetadata->prevPageKey, (int)pageMetadata->count);
			
			YapDatabaseString _prevPageKey; MakeYapDatabaseString(&_prevPageKey, pageMetadata->prevPageKey);
			if (pageMetadata->prevPageKey) {
				sqlite3_bind_text(statement, 1, _prevPageKey.str, _prevPageKey.length, SQLITE_STATIC);
			}
			
			sqlite3_bind_int(statement, 2, (int)(pageMetadata->count));
			
			__attribute__((objc_precise_lifetime)) NSData *rawData = [self serializePage:page];
			sqlite3_bind_blob(statement, 3, rawData.bytes, (int)rawData.length, SQLITE_STATIC);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 4, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[1c]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_prevPageKey);
			FreeYapDatabaseString(&_pageKey);
		}
		else
		{
			sqlite3_stmt *statement = [viewConnection pageTable_updatePageForPageKeyStatement];
			if (statement == NULL) {
				*stop = YES;
				return;//from block
			}
			
			// UPDATE "pageTableName" SET "count" = ?, "data" = ? WHERE "pageKey" = ?;
			
			YDBLogVerbose(@"UPDATE '%@' SET 'count' = ?, 'data' = ? WHERE 'pageKey' = ?;\n"
			              @" - pageKey: %@\n"
			              @" - count  : %d", [self pageTableName], pageKey, (int)(pageMetadata->count));
			
			sqlite3_bind_int(statement, 1, (int)[page count]);
			
			__attribute__((objc_precise_lifetime)) NSData *rawData = [self serializePage:page];
			sqlite3_bind_blob(statement, 2, rawData.bytes, (int)rawData.length, SQLITE_STATIC);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 3, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[1d]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_pageKey);
		}
	}];
	
	// Write dirty prevPageKey values to table (those not also associated with dirty pages).
	// This happens when only the prevPageKey pointer is changed.
	
	[viewConnection->dirtyLinks enumerateKeysAndObjectsUsingBlock:^(id key, id obj, BOOL *stop) {
		
		NSString *pageKey = (NSString *)key;
		YapDatabaseViewPageMetadata *pageMetadata = (YapDatabaseViewPageMetadata *)obj;
		
		if ([viewConnection->dirtyPages objectForKey:pageKey])
		{
			// Both the page and metadata were dirty, so we wrote them both to disk at the same time.
			// No need to write the metadata again.
			
			return;//continue;
		}
		
		sqlite3_stmt *statement = [viewConnection pageTable_updateLinkForPageKeyStatement];
		if (statement == NULL) {
			*stop = YES;
			return;//from block
		}
			
		// UPDATE "pageTableName" SET "prevPageKey" = ? WHERE "pageKey" = ?;
		
		YDBLogVerbose(@"UPDATE '%@' SET 'prevPageKey' = ? WHERE 'pageKey' = ?;\n"
		              @" - pageKey    : %@\n"
		              @" - prevPageKey: %@", [self pageTableName], pageKey, pageMetadata->prevPageKey);
		
		YapDatabaseString _prevPageKey; MakeYapDatabaseString(&_prevPageKey, pageMetadata->prevPageKey);
		if (pageMetadata->prevPageKey) {
			sqlite3_bind_text(statement, 1, _prevPageKey.str, _prevPageKey.length, SQLITE_STATIC);
		}
		
		YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
		sqlite3_bind_text(statement, 2, _pageKey.str, _pageKey.length, SQLITE_STATIC);
		
		int status = sqlite3_step(statement);
		if (status != SQLITE_DONE)
		{
			YDBLogError(@"%@ (%@): Error executing statement[2]: %d %s",
			            THIS_METHOD, [self registeredName],
			            status, sqlite3_errmsg(databaseTransaction->connection->db));
		}
		
		sqlite3_clear_bindings(statement);
		sqlite3_reset(statement);
		FreeYapDatabaseString(&_prevPageKey);
		FreeYapDatabaseString(&_pageKey);
	}];
	
	// Update the dirty rowid -> pageKey mappings.
	
	[viewConnection->dirtyMaps enumerateKeysAndObjectsUsingBlock:^(id rowidObj, id obj, BOOL *stop) {
		
		int64_t rowid = [(NSNumber *)rowidObj longLongValue];
		__unsafe_unretained NSString *pageKey = (NSString *)obj;
		
		if ((id)pageKey == (id)[NSNull null])
		{
			sqlite3_stmt *statement = [viewConnection mapTable_removeForRowidStatement];
			if (statement == NULL)
			{
				*stop = YES;
				return;//continue;
			}
			
			// DELETE FROM "mapTableName" WHERE "rowid" = ?;
			
			YDBLogVerbose(@"DELETE FROM '%@' WHERE 'rowid' = ?;\n"
			              @" - rowid : %lld", [self mapTableName], (long long)rowid);
			
			sqlite3_bind_int64(statement, 1, rowid);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[3a]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
		}
		else
		{
			sqlite3_stmt *statement = [viewConnection mapTable_setPageKeyForRowidStatement];
			if (statement == NULL)
			{
				*stop = YES;
				return;//continue;
			}
			
			// INSERT OR REPLACE INTO "mapTableName" ("rowid", "pageKey") VALUES (?, ?);
			
			YDBLogVerbose(@"INSERT OR REPLACE INTO '%@' ('rowid', 'pageKey') VALUES (?, ?);\n"
			              @" - rowid  : %lld\n"
			              @" - pageKey: %@", [self mapTableName], (long long)rowid, pageKey);
			
			sqlite3_bind_int64(statement, 1, rowid);
			
			YapDatabaseString _pageKey; MakeYapDatabaseString(&_pageKey, pageKey);
			sqlite3_bind_text(statement, 2, _pageKey.str, _pageKey.length, SQLITE_STATIC);
			
			int status = sqlite3_step(statement);
			if (status != SQLITE_DONE)
			{
				YDBLogError(@"%@ (%@): Error executing statement[3b]: %d %s",
				            THIS_METHOD, [self registeredName],
				            status, sqlite3_errmsg(databaseTransaction->connection->db));
			}
			
			sqlite3_clear_bindings(statement);
			sqlite3_reset(statement);
			FreeYapDatabaseString(&_pageKey);
		}
	}];
	
	[viewConnection postCommitCleanup];
	
	// An extensionTransaction is only valid within the scope of its encompassing databaseTransaction.
	// I imagine this may occasionally be misunderstood, and developers may attempt to store the extension in an ivar,
	// and then use it outside the context of the database transaction block.
	// Thus, this code is here as a safety net to ensure that such accidental misuse doesn't do any damage.
	
	viewConnection = nil;      // Do not remove !
	databaseTransaction = nil; // Do not remove !
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark YapAbstractDatabaseExtensionTransaction_KeyValue
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleInsertObject:(id)object forKey:(NSString *)key withMetadata:(id)metadata rowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	// Invoke the grouping block to find out if the object should be included in the view.
	
	NSString *group;
	
	if (view->groupingBlockType == YapDatabaseViewBlockTypeWithKey)
	{
		__unsafe_unretained YapDatabaseViewGroupingWithKeyBlock groupingBlock =
		    (YapDatabaseViewGroupingWithKeyBlock)view->groupingBlock;
		
		group = groupingBlock(key);
	}
	else if (view->groupingBlockType == YapDatabaseViewBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseViewGroupingWithObjectBlock groupingBlock =
		    (YapDatabaseViewGroupingWithObjectBlock)view->groupingBlock;
		
		group = groupingBlock(key, object);
	}
	else if (view->groupingBlockType == YapDatabaseViewBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseViewGroupingWithMetadataBlock groupingBlock =
		    (YapDatabaseViewGroupingWithMetadataBlock)view->groupingBlock;
		
		group = groupingBlock(key, metadata);
	}
	else
	{
		__unsafe_unretained YapDatabaseViewGroupingWithRowBlock groupingBlock =
		    (YapDatabaseViewGroupingWithRowBlock)view->groupingBlock;
		
		group = groupingBlock(key, object, metadata);
	}
	
	if (group == nil)
	{
		// This was an insert operation, so we know the key wasn't already in the view.
	}
	else
	{
		// Add key to view.
		// This was an insert operation, so we know the key wasn't already in the view.
		
		int flags = (YapDatabaseViewChangedObject | YapDatabaseViewChangedMetadata);
		
		[self insertRowid:rowid key:key object:object metadata:metadata inGroup:group withChanges:flags isNew:YES];
	}
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleUpdateObject:(id)object forKey:(NSString *)key withMetadata:(id)metadata rowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	// Invoke the grouping block to find out if the object should be included in the view.
	
	NSString *group;
	
	if (view->groupingBlockType == YapDatabaseViewBlockTypeWithKey)
	{
		__unsafe_unretained YapDatabaseViewGroupingWithKeyBlock groupingBlock =
		    (YapDatabaseViewGroupingWithKeyBlock)view->groupingBlock;
		
		group = groupingBlock(key);
	}
	else if (view->groupingBlockType == YapDatabaseViewBlockTypeWithObject)
	{
		__unsafe_unretained YapDatabaseViewGroupingWithObjectBlock groupingBlock =
		    (YapDatabaseViewGroupingWithObjectBlock)view->groupingBlock;
		
		group = groupingBlock(key, object);
	}
	else if (view->groupingBlockType == YapDatabaseViewBlockTypeWithMetadata)
	{
		__unsafe_unretained YapDatabaseViewGroupingWithMetadataBlock groupingBlock =
		    (YapDatabaseViewGroupingWithMetadataBlock)view->groupingBlock;
		
		group = groupingBlock(key, metadata);
	}
	else
	{
		__unsafe_unretained YapDatabaseViewGroupingWithRowBlock groupingBlock =
		    (YapDatabaseViewGroupingWithRowBlock)view->groupingBlock;
		
		group = groupingBlock(key, object, metadata);
	}
	
	if (group == nil)
	{
		// Remove key from view (if needed).
		// This was an update operation, so the key may have previously been in the view.
		
		[self removeRowid:rowid key:key];
	}
	else
	{
		// Add key to view (or update position).
		// This was an update operation, so the key may have previously been in the view.
		
		int flags = (YapDatabaseViewChangedObject | YapDatabaseViewChangedMetadata);
		
		[self insertRowid:rowid key:key object:object metadata:metadata inGroup:group withChanges:flags isNew:NO];
	}
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleUpdateMetadata:(id)metadata forKey:(NSString *)key withRowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	// Invoke the grouping block to find out if the object should be included in the view.
	
	id object = nil;
	NSString *group = nil;
	
	if (view->groupingBlockType == YapDatabaseViewBlockTypeWithKey ||
	    view->groupingBlockType == YapDatabaseViewBlockTypeWithObject)
	{
		// Grouping is based on the key or object.
		// Neither have changed, and thus the group hasn't changed.
		
		NSString *pageKey = [self pageKeyForRowid:rowid];
		group = [self groupForPageKey:pageKey];
		
		if (group == nil)
		{
			// Nothing to do.
			// The key wasn't previously in the view, and still isn't in the view.
			return;
		}
		
		if (view->sortingBlockType == YapDatabaseViewBlockTypeWithKey ||
		    view->sortingBlockType == YapDatabaseViewBlockTypeWithObject)
		{
			// Nothing has moved because the group hasn't changed and
			// nothing has changed that relates to sorting.
			
			int flags = YapDatabaseViewChangedMetadata;
			NSUInteger existingIndex = [self indexForRowid:rowid inGroup:group withPageKey:pageKey];
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:existingIndex]];
		}
		else
		{
			// Sorting is based on the metadata, which has changed.
			// So the sort order may possibly have changed.
			
			// From previous if statement (above) we know:
			// sortingBlockType is metadata or objectAndMetadata
			
			if (view->sortingBlockType == YapDatabaseViewBlockTypeWithRow)
			{
				// Need the object for the sorting block
				object = [databaseTransaction objectForKey:key];
			}
			
			int flags = YapDatabaseViewChangedMetadata;
			
			[self insertRowid:rowid key:key object:object metadata:metadata inGroup:group withChanges:flags isNew:NO];
		}
	}
	else
	{
		// Grouping is based on metadata or objectAndMetadata.
		// Invoke groupingBlock to see what the new group is.
		
		if (view->groupingBlockType == YapDatabaseViewBlockTypeWithMetadata)
		{
			__unsafe_unretained YapDatabaseViewGroupingWithMetadataBlock groupingBlock =
		        (YapDatabaseViewGroupingWithMetadataBlock)view->groupingBlock;
			
			group = groupingBlock(key, metadata);
		}
		else
		{
			__unsafe_unretained YapDatabaseViewGroupingWithRowBlock groupingBlock =
		        (YapDatabaseViewGroupingWithRowBlock)view->groupingBlock;
			
			object = [databaseTransaction objectForKey:key];
			group = groupingBlock(key, object, metadata);
		}
		
		if (group == nil)
		{
			// The key is not included in the view.
			// Remove key from view (if needed).
			
			[self removeRowid:rowid key:key];
		}
		else
		{
			if (view->sortingBlockType == YapDatabaseViewBlockTypeWithKey ||
			    view->sortingBlockType == YapDatabaseViewBlockTypeWithObject)
			{
				// Sorting is based on the key or object, neither of which has changed.
				// So if the group hasn't changed, then the sort order hasn't changed.
				
				NSString *existingPageKey = [self pageKeyForRowid:rowid];
				NSString *existingGroup = [self groupForPageKey:existingPageKey];
				
				if ([group isEqualToString:existingGroup])
				{
					// Nothing left to do.
					// The group didn't change, and the sort order cannot change (because the object didn't change).
					
					int flags = YapDatabaseViewChangedMetadata;
					NSUInteger existingIndex = [self indexForRowid:rowid inGroup:group withPageKey:existingPageKey];
					
					[viewConnection->changes addObject:
					    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:existingIndex]];
					
					return;
				}
			}
			
			if (object == nil && (view->sortingBlockType == YapDatabaseViewBlockTypeWithObject ||
			                      view->sortingBlockType == YapDatabaseViewBlockTypeWithRow    ))
			{
				// Need the object for the sorting block
				object = [databaseTransaction objectForKey:key];
			}
			
			int flags = YapDatabaseViewChangedMetadata;
			
			[self insertRowid:rowid key:key object:object metadata:metadata inGroup:group withChanges:flags isNew:NO];
		}
	}
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleTouchObjectForKey:(NSString *)key withRowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	// Almost the same as touchRowForKey:
	
	NSString *pageKey = [self pageKeyForRowid:rowid];
	if (pageKey)
	{
		NSString *group = [self groupForPageKey:pageKey];
		NSUInteger index = [self indexForRowid:rowid inGroup:group withPageKey:pageKey];
		
		int flags = (YapDatabaseViewChangedObject | YapDatabaseViewChangedMetadata);
		
		[viewConnection->changes addObject:
		    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:index]];
	}
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleTouchMetadataForKey:(NSString *)key withRowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	// Almost the same as touchMetadataForKey:
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	if (view->groupingBlockType == YapDatabaseViewBlockTypeWithMetadata ||
	    view->groupingBlockType == YapDatabaseViewBlockTypeWithRow      ||
	    view->sortingBlockType  == YapDatabaseViewBlockTypeWithMetadata ||
	    view->sortingBlockType  == YapDatabaseViewBlockTypeWithRow       )
	{
		NSString *pageKey = [self pageKeyForRowid:rowid];
		if (pageKey)
		{
			NSString *group = [self groupForPageKey:pageKey];
			NSUInteger index = [self indexForRowid:rowid inGroup:group withPageKey:pageKey];
			
			int flags = YapDatabaseViewChangedMetadata;
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:index]];
		}
	}
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveObjectForKey:(NSString *)key withRowid:(int64_t)rowid
{
	YDBLogAutoTrace();
	
	[self removeRowid:rowid key:key];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveObjectsForKeys:(NSArray *)keys withRowids:(NSArray *)rowids;
{
	YDBLogAutoTrace();
	
	NSUInteger count = [keys count];
	NSMutableDictionary *keyMappings = [NSMutableDictionary dictionaryWithCapacity:count];
	
	for (NSUInteger i = 0; i < count; i++)
	{
		NSNumber *rowid = [rowids objectAtIndex:i];
		NSString *key = [keys objectAtIndex:i];
		
		[keyMappings setObject:key forKey:rowid];
	}
	
	NSDictionary *output = [self pageKeysForRowids:rowids withKeyMappings:keyMappings];
	
	// output.key = pageKey
	// output.value = NSDictionary with keyMappings for page
	
	[output enumerateKeysAndObjectsUsingBlock:^(id pageKeyObj, id dictObj, BOOL *stop) {
		
		__unsafe_unretained NSString *pageKey = (NSString *)pageKeyObj;
		__unsafe_unretained NSDictionary *keyMappingsForPage = (NSDictionary *)dictObj;
		
		[self removeRowidsWithKeyMappings:keyMappingsForPage pageKey:pageKey inGroup:[self groupForPageKey:pageKey]];
	}];
}

/**
 * YapDatabase extension hook.
 * This method is invoked by a YapDatabaseReadWriteTransaction as a post-operation-hook.
**/
- (void)handleRemoveAllObjects
{
	YDBLogAutoTrace();
	
	[self removeAllRowids];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Public API - Groups
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSUInteger)numberOfGroups
{
	return [viewConnection->group_pagesMetadata_dict count];
}

- (NSArray *)allGroups
{
	return [viewConnection->group_pagesMetadata_dict allKeys];
}

- (NSUInteger)numberOfKeysInGroup:(NSString *)group
{
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	NSUInteger count = 0;
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		count += pageMetadata->count;
	}
	
	return count;
}

- (NSUInteger)numberOfKeysInAllGroups
{
	NSUInteger count = 0;
	
	for (NSMutableArray *pagesMetadataForGroup in [viewConnection->group_pagesMetadata_dict objectEnumerator])
	{
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			count += pageMetadata->count;
		}
	}
	
	return count;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Public API - Fetching
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSString *)keyAtIndex:(NSUInteger)index inGroup:(NSString *)group
{
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	NSUInteger pageOffset = 0;
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		if ((index < (pageOffset + pageMetadata->count)) && (pageMetadata->count > 0))
		{
			YapDatabaseViewPage *page = [self pageForPageKey:pageMetadata->pageKey];
			
			int64_t rowid = [page rowidAtIndex:(index - pageOffset)];
			
			NSString *key = nil;
			[databaseTransaction getKey:&key forRowid:rowid];
			
			return key;
		}
		else
		{
			pageOffset += pageMetadata->count;
		}
	}
	
	return nil;
}

- (NSString *)firstKeyInGroup:(NSString *)group
{
	return [self keyAtIndex:0 inGroup:group];
}

- (NSString *)lastKeyInGroup:(NSString *)group
{
	// We can actually do something a little faster than this:
	//
	// NSUInteger count = [self numberOfKeysInGroup:group];
	// if (count > 0)
	//     return [self keyAtIndex:(count-1) inGroup:group];
	// else
	//     return nil;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];

	__block NSString *lastKey = nil;
	
	[pagesMetadataForGroup enumerateObjectsWithOptions:NSEnumerationReverse
	                                        usingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
		
		__unsafe_unretained YapDatabaseViewPageMetadata *pageMetadata = (YapDatabaseViewPageMetadata *)obj;
		
		if (pageMetadata->count > 0)
		{
			YapDatabaseViewPage *lastPage = [self pageForPageKey:pageMetadata->pageKey];
			
			int64_t rowid = [lastPage rowidAtIndex:(pageMetadata->count - 1)];
			
			[databaseTransaction getKey:&lastKey forRowid:rowid];
			*stop = YES;
		}
	}];
	
	return lastKey;
}

- (NSString *)groupForKey:(NSString *)key
{
	key = [key copy]; // mutable string protection (public method)
	
	int64_t rowid;
	if ([databaseTransaction getRowid:&rowid forKey:key])
	{
		return [self groupForPageKey:[self pageKeyForRowid:rowid]];
	}
	
	return nil;
}

- (BOOL)getGroup:(NSString **)groupPtr index:(NSUInteger *)indexPtr forKey:(NSString *)key
{
	key = [key copy]; // mutable string protection (public method)
	
	BOOL found = NO;
	NSString *group = nil;
	NSUInteger index = 0;
	
	int64_t rowid = 0;
	if ([databaseTransaction getRowid:&rowid forKey:key])
	{
		// Query the database to see if the given rowid is in the view.
		// If it is, the query will return the corresponding pageKey for it.
		
		NSString *pageKey = [self pageKeyForRowid:rowid];
		if (pageKey)
		{
			// Now that we have the pageKey, fetch the corresponding group.
			// This is done using an in-memory cache.
			
			group = [self groupForPageKey:pageKey];
			
			// Calculate the offset of the corresponding page within the group.
			
			NSUInteger pageOffset = 0;
			NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
			
			for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
			{
				if ([pageMetadata->pageKey isEqualToString:pageKey])
				{
					break;
				}
				
				pageOffset += pageMetadata->count;
			}
			
			// Fetch the actual page (ordered array of rowids)
			
			YapDatabaseViewPage *page = [self pageForPageKey:pageKey];
			
			// And find the exact index of the key within the page
			
			NSUInteger indexWithinPage = 0;
			if ([page getIndex:&indexWithinPage ofRowid:rowid])
			{
				index = pageOffset + indexWithinPage;
				found = YES;
			}
		}
	}
	
	if (groupPtr) *groupPtr = group;
	if (indexPtr) *indexPtr = index;
	
	return found;
}

- (NSArray *)keysInRange:(NSRange)range group:(NSString *)group
{
	NSMutableArray *result = [NSMutableArray arrayWithCapacity:range.length];

	[self enumerateKeysInGroup:group
	               withOptions:0
	                     range:range
	                usingBlock:^(NSString *key, NSUInteger index, BOOL *stop) {
		
		[result addObject:key];
	}];

	return result;
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Public API - Finding
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * See header file for extensive documentation for this method.
**/
- (NSRange)findRangeInGroup:(NSString *)group usingBlock:(id)block blockType:(YapDatabaseViewBlockType)blockType
{
	BOOL invalidBlockType = blockType != YapDatabaseViewBlockTypeWithKey      &&
	                        blockType != YapDatabaseViewBlockTypeWithObject   &&
	                        blockType != YapDatabaseViewBlockTypeWithMetadata &&
	                        blockType != YapDatabaseViewBlockTypeWithRow;
	
	if (group == nil || block == NULL || invalidBlockType)
	{
		return NSMakeRange(NSNotFound, 0);
	}
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	NSUInteger count = 0;
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		count += pageMetadata->count;
	}
	
	if (count == 0)
	{
		return NSMakeRange(NSNotFound, 0);
	}
	
	NSComparisonResult (^compare)(NSUInteger) = ^NSComparisonResult (NSUInteger index){
		
		int64_t rowid = 0;
		
		NSUInteger pageOffset = 0;
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			if ((index < (pageOffset + pageMetadata->count)) && (pageMetadata->count > 0))
			{
				YapDatabaseViewPage *page = [self pageForPageKey:pageMetadata->pageKey];
				
				rowid = [page rowidAtIndex:(index - pageOffset)];
				break;
			}
			else
			{
				pageOffset += pageMetadata->count;
			}
		}
		
		if (blockType == YapDatabaseViewBlockTypeWithKey)
		{
			__unsafe_unretained YapDatabaseViewFindWithKeyBlock findBlock =
			    (YapDatabaseViewFindWithKeyBlock)block;
			
			NSString *key = nil;
			[databaseTransaction getKey:&key forRowid:rowid];
			
			return findBlock(key);
		}
		else if (blockType == YapDatabaseViewBlockTypeWithObject)
		{
			__unsafe_unretained YapDatabaseViewFindWithObjectBlock findBlock =
			    (YapDatabaseViewFindWithObjectBlock)block;
			
			NSString *key = nil;
			id object = nil;
			[databaseTransaction getKey:&key object:&object forRowid:rowid];
			
			return findBlock(key, object);
		}
		else if (blockType == YapDatabaseViewBlockTypeWithMetadata)
		{
			__unsafe_unretained YapDatabaseViewFindWithMetadataBlock findBlock =
			    (YapDatabaseViewFindWithMetadataBlock)block;
			
			NSString *key = nil;
			id metadata = nil;
			[databaseTransaction getKey:&key metadata:&metadata forRowid:rowid];
			
			return findBlock(key, metadata);
		}
		else
		{
			__unsafe_unretained YapDatabaseViewFindWithRowBlock findBlock =
			    (YapDatabaseViewFindWithRowBlock)block;
			
			NSString *key = nil;
			id object = nil;
			id metadata = nil;
			[databaseTransaction getKey:&key object:&object metadata:&metadata forRowid:rowid];
			
			return findBlock(key, object, metadata);
		}
	};
	
	NSUInteger loopCount = 0;
	
	// Find first match (first to return NSOrderedSame)
	
	NSUInteger mMin = 0;
	NSUInteger mMax = count;
	NSUInteger mMid;
	
	BOOL found = NO;
	
	while (mMin < mMax && !found)
	{
		mMid = (mMin + mMax) / 2;
		
		NSComparisonResult cmp = compare(mMid);
		
		if (cmp == NSOrderedDescending)      // Descending => value is greater than desired range
			mMax = mMid;
		else if (cmp == NSOrderedAscending)  // Ascending => value is less than desired range
			mMin = mMid + 1;
		else
			found = YES;
		
		loopCount++;
	}
	
	if (!found)
	{
		return NSMakeRange(NSNotFound, 0);
	}
	
	// Find start of range
	
	NSUInteger sMin = mMin;
	NSUInteger sMax = mMid;
	NSUInteger sMid;
	
	while (sMin < sMax)
	{
		sMid = (sMin + sMax) / 2;
		
		NSComparisonResult cmp = compare(sMid);
		
		if (cmp == NSOrderedAscending) // Ascending => value is less than desired range
			sMin = sMid + 1;
		else
			sMax = sMid;
		
		loopCount++;
	}
	
	// Find end of range
	
	NSUInteger eMin = mMid;
	NSUInteger eMax = mMax;
	NSUInteger eMid;
	
	while (eMin < eMax)
	{
		eMid = (eMin + eMax) / 2;
		
		NSComparisonResult cmp = compare(eMid);
		
		if (cmp == NSOrderedDescending) // Descending => value is greater than desired range
			eMax = eMid;
		else
			eMin = eMid + 1;
		
		loopCount++;
	}
	
	YDBLogVerbose(@"Find range in group(%@) took %lu comparisons", group, (unsigned long)loopCount);
	
	return NSMakeRange(sMin, (eMax - sMin));
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Public API - Enumerating
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)enumerateKeysInGroup:(NSString *)group
                  usingBlock:(void (^)(NSString *key, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		[databaseTransaction getKey:&key forRowid:rowid];
		
		block(key, index, stop);
	}];
}

- (void)enumerateKeysInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)options
                  usingBlock:(void (^)(NSString *key, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group withOptions:options usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		[databaseTransaction getKey:&key forRowid:rowid];
		
		block(key, index, stop);
	}];
}

- (void)enumerateKeysInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)options
                       range:(NSRange)range
                  usingBlock:(void (^)(NSString *key, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group
	                 withOptions:options
	                       range:range
	                  usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		[databaseTransaction getKey:&key forRowid:rowid];
		
		block(key, index, stop);
	}];
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Private API
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (void)enumerateRowidsInGroup:(NSString *)group
                    usingBlock:(void (^)(int64_t rowid, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[viewConnection->mutatedGroups removeObject:group]; // mutation during enumeration protection
	
	__block BOOL stop = NO;
	
	NSUInteger pageOffset = 0;
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
	{
		YapDatabaseViewPage *page = [self pageForPageKey:pageMetadata->pageKey];
		
		__block NSUInteger index = pageOffset;
		[page enumerateRowidsUsingBlock:^(int64_t rowid, NSUInteger idx, BOOL *innerStop) {
			
			block(rowid, index, &stop);
			
			index++;
			if (stop || [viewConnection->mutatedGroups containsObject:group]) *innerStop = YES;
		}];
		
		if (stop || [viewConnection->mutatedGroups containsObject:group]) break;
		
		pageOffset += pageMetadata->count;
	}
	
	if (!stop && [viewConnection->mutatedGroups containsObject:group])
	{
		@throw [self mutationDuringEnumerationException:group];
	}
}

- (void)enumerateRowidsInGroup:(NSString *)group
                   withOptions:(NSEnumerationOptions)inOptions
                    usingBlock:(void (^)(int64_t rowid, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	NSEnumerationOptions options = (inOptions & NSEnumerationReverse); // We only support NSEnumerationReverse
	BOOL forwardEnumeration = (options != NSEnumerationReverse);
	
	[viewConnection->mutatedGroups removeObject:group]; // mutation during enumeration protection
	
	__block BOOL stop = NO;
	__block NSUInteger index;
	
	if (forwardEnumeration)
		index = 0;
	else
		index = [self numberOfKeysInGroup:group] - 1;
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	[pagesMetadataForGroup enumerateObjectsWithOptions:options
	                                        usingBlock:^(id pageMetadataObj, NSUInteger outerIdx, BOOL *outerStop){
		
		__unsafe_unretained YapDatabaseViewPageMetadata *pageMetadata =
		    (YapDatabaseViewPageMetadata *)pageMetadataObj;
		
		YapDatabaseViewPage *page = [self pageForPageKey:pageMetadata->pageKey];
		
		[page enumerateRowidsWithOptions:options usingBlock:^(int64_t rowid, NSUInteger innerIdx, BOOL *innerStop){
			
			block(rowid, index, &stop);
			
			if (forwardEnumeration)
				index++;
			else
				index--;
			
			if (stop || [viewConnection->mutatedGroups containsObject:group]) *innerStop = YES;
		}];
		
		if (stop || [viewConnection->mutatedGroups containsObject:group]) *outerStop = YES;
	}];
	
	if (!stop && [viewConnection->mutatedGroups containsObject:group])
	{
		@throw [self mutationDuringEnumerationException:group];
	}
}

- (void)enumerateRowidsInGroup:(NSString *)group
                   withOptions:(NSEnumerationOptions)inOptions
                         range:(NSRange)range
                    usingBlock:(void (^)(int64_t rowid, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	NSEnumerationOptions options = (inOptions & NSEnumerationReverse); // We only support NSEnumerationReverse
	
	NSMutableArray *pagesMetadataForGroup = [viewConnection->group_pagesMetadata_dict objectForKey:group];
	
	// Helper block to fetch the pageOffset for some page.
	
	NSUInteger (^pageOffsetForPageMetadata)(YapDatabaseViewPageMetadata *inPageMetadata);
	pageOffsetForPageMetadata = ^ NSUInteger (YapDatabaseViewPageMetadata *inPageMetadata){
		
		NSUInteger pageOffset = 0;
		
		for (YapDatabaseViewPageMetadata *pageMetadata in pagesMetadataForGroup)
		{
			if (pageMetadata == inPageMetadata)
				return pageOffset;
			else
				pageOffset += pageMetadata->count;
		}
		
		return pageOffset;
	};
	
	[viewConnection->mutatedGroups removeObject:group]; // mutation during enumeration protection
	
	__block BOOL stop = NO;
	__block BOOL startedRange = NO;
	__block NSUInteger keysLeft = range.length;
	
	[pagesMetadataForGroup enumerateObjectsWithOptions:options
	                                        usingBlock:^(id pageMetadataObj, NSUInteger pageIndex, BOOL *outerStop){
	
		__unsafe_unretained YapDatabaseViewPageMetadata *pageMetadata =
		    (YapDatabaseViewPageMetadata *)pageMetadataObj;
		
		NSUInteger pageOffset = pageOffsetForPageMetadata(pageMetadata);
		NSRange pageRange = NSMakeRange(pageOffset, pageMetadata->count);
		NSRange keysRange = NSIntersectionRange(pageRange, range);
		
		if (keysRange.length > 0)
		{
			startedRange = YES;
			YapDatabaseViewPage *page = [self pageForPageKey:pageMetadata->pageKey];
			
			// Enumerate the subset
			
			NSRange subsetRange = NSMakeRange(keysRange.location-pageOffset, keysRange.length);
			
			[page enumerateRowidsWithOptions:options
			                           range:subsetRange
			                      usingBlock:^(int64_t rowid, NSUInteger idx, BOOL *innerStop){
				
				block(rowid, pageOffset+idx, &stop);
				
				if (stop || [viewConnection->mutatedGroups containsObject:group]) *innerStop = YES;
			}];
			
			keysLeft -= keysRange.length;
			
			if (stop || [viewConnection->mutatedGroups containsObject:group]) *outerStop = YES;
		}
		else if (startedRange)
		{
			// We've completed the range
			*outerStop = YES;
		}
		
	}];
	
	if (!stop && [viewConnection->mutatedGroups containsObject:group])
	{
		@throw [self mutationDuringEnumerationException:group];
	}
	
	if (!stop && keysLeft > 0)
	{
		YDBLogWarn(@"%@: Range out of bounds: range(%lu, %lu) >= numberOfKeys(%lu) in group %@", THIS_METHOD,
		    (unsigned long)range.location, (unsigned long)range.length,
		    (unsigned long)[self numberOfKeysInGroup:group], group);
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Touch
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

/**
 * "Touching" a object allows you to mark an item in the view as "updated",
 * even if the object itself wasn't directly updated.
 *
 * This is most often useful when a view is being used by a tableView,
 * but the tableView cells are also dependent upon another object in the database.
 *
 * For example:
 * 
 *   You have a view which includes the departments in the company, sorted by name.
 *   But as part of the cell that's displayed for the department,
 *   you also display the number of employees in the department.
 *   The employee count comes from elsewhere.
 *   That is, the employee count isn't a property of the department object itself.
 *   Perhaps you get the count from another view,
 *   or perhaps the count is simply the number of keys in a particular collection.
 *   Either way, when you add or remove an employee, you want to ensure that the view marks the
 *   affected department as updated so that the corresponding cell will properly redraw itself.
 *
 * So the idea is to mark certain items as updated so that the changeset
 * for the view will properly reflect a change to the corresponding index.
 *
 * "Touching" an item has very minimal overhead.
 * It doesn't cause the groupingBlock or sortingBlock to be invoked,
 * and it doesn't cause any writes to the database.
 *
 * You can touch
 * - just the object
 * - just the metadata
 * - or both object and metadata (the row)
 * 
 * If you mark just the object as changed,
 * and neither the groupingBlock nor sortingBlock depend upon the object,
 * then the view doesn't reflect any change.
 * 
 * If you mark just the metadata as changed,
 * and neither the groupingBlock nor sortingBlock depend upon the metadata,
 * then the view doesn't relect any change.
 * 
 * In all other cases, the view will properly reflect a corresponding change in the notification that's posted.
**/

- (void)touchRowForKey:(NSString *)key
{
	if (!databaseTransaction->isReadWriteTransaction) return;
	
	int64_t rowid = 0;
	if ([databaseTransaction getRowid:&rowid forKey:key])
	{
		NSString *pageKey = [self pageKeyForRowid:rowid];
		if (pageKey)
		{
			NSString *group = [self groupForPageKey:pageKey];
			NSUInteger index = [self indexForRowid:rowid inGroup:group withPageKey:pageKey];
			
			key = [key copy]; // mutable string protection
			int flags = (YapDatabaseViewChangedObject | YapDatabaseViewChangedMetadata);
			
			[viewConnection->changes addObject:
			    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:index]];
		}
	}
}

- (void)touchObjectForKey:(NSString *)key
{
	if (!databaseTransaction->isReadWriteTransaction) return;
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	if (view->groupingBlockType == YapDatabaseViewBlockTypeWithObject ||
	    view->groupingBlockType == YapDatabaseViewBlockTypeWithRow    ||
	    view->sortingBlockType  == YapDatabaseViewBlockTypeWithObject ||
	    view->sortingBlockType  == YapDatabaseViewBlockTypeWithRow     )
	{
		int64_t rowid = 0;
		if ([databaseTransaction getRowid:&rowid forKey:key])
		{
			NSString *pageKey = [self pageKeyForRowid:rowid];
			if (pageKey)
			{
				NSString *group = [self groupForPageKey:pageKey];
				NSUInteger index = [self indexForRowid:rowid inGroup:group withPageKey:pageKey];
				
				key = [key copy]; // mutable string protection
				int flags = YapDatabaseViewChangedObject;
				
				[viewConnection->changes addObject:
				    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:index]];
			}
		}
	}
}

- (void)touchMetadataForKey:(NSString *)key
{
	if (!databaseTransaction->isReadWriteTransaction) return;
	
	__unsafe_unretained YapDatabaseView *view = viewConnection->view;
	
	if (view->groupingBlockType == YapDatabaseViewBlockTypeWithMetadata ||
	    view->groupingBlockType == YapDatabaseViewBlockTypeWithRow      ||
	    view->sortingBlockType  == YapDatabaseViewBlockTypeWithMetadata ||
	    view->sortingBlockType  == YapDatabaseViewBlockTypeWithRow       )
	{
		int64_t rowid = 0;
		if ([databaseTransaction getRowid:&rowid forKey:key])
		{
			NSString *pageKey = [self pageKeyForRowid:rowid];
			if (pageKey)
			{
				NSString *group = [self groupForPageKey:pageKey];
				NSUInteger index = [self indexForRowid:rowid inGroup:group withPageKey:pageKey];
				
				key = [key copy]; // mutable string protection
				int flags = YapDatabaseViewChangedMetadata;
				
				[viewConnection->changes addObject:
				    [YapDatabaseViewRowChange updateKey:key changes:flags inGroup:group atIndex:index]];
			}
		}
	}
}

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark Exceptions
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

- (NSException *)mutationDuringEnumerationException:(NSString *)group
{
	NSString *reason = [NSString stringWithFormat:
	    @"View <RegisteredName=%@, Group=%@> was mutated while being enumerated.", [self registeredName], group];
	
	NSDictionary *userInfo = @{ NSLocalizedRecoverySuggestionErrorKey:
	    @"If you modify the database during enumeration you must either"
		@" (A) ensure you don't mutate the group you're enumerating OR"
		@" (B) set the 'stop' parameter of the enumeration block to YES (*stop = YES;). "
		@"If you're enumerating in order to remove items from the database,"
		@" and you're enumerating in order (forwards or backwards)"
		@" then you may also consider looping and using firstKeyInGroup / lastKeyInGroup."};
	
	return [NSException exceptionWithName:@"YapDatabaseException" reason:reason userInfo:userInfo];
}

@end

////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////
#pragma mark -
////////////////////////////////////////////////////////////////////////////////////////////////////////////////////////

@implementation YapDatabaseViewTransaction (Convenience)

- (id)objectAtIndex:(NSUInteger)index inGroup:(NSString *)group
{
	// We could use either:
	// - keyAtIndex:inGroup: + objectForKey: OR
	// - rowidAtIndex: + getKey:object:forRowid:
	//
	// The first option is likely faster most of the time,
	// as objectForKey: allows us to hit our internal cache without querying sqlite.
	
	return [databaseTransaction objectForKey:[self keyAtIndex:index inGroup:group]];
}

- (id)firstObjectInGroup:(NSString *)group
{
	return [databaseTransaction objectForKey:[self firstKeyInGroup:group]];
}

- (id)lastObjectInGroup:(NSString *)group
{
	return [databaseTransaction objectForKey:[self lastKeyInGroup:group]];
}

- (void)enumerateKeysAndMetadataInGroup:(NSString *)group
                             usingBlock:(void (^)(NSString *key, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id metadata = nil;
		[databaseTransaction getKey:&key metadata:&metadata forRowid:rowid];
		
		block(key, metadata, index, stop);
	}];
}

- (void)enumerateKeysAndMetadataInGroup:(NSString *)group
                            withOptions:(NSEnumerationOptions)options
                             usingBlock:(void (^)(NSString *key, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group withOptions:options usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id metadata = nil;
		[databaseTransaction getKey:&key metadata:&metadata forRowid:rowid];
		
		block(key, metadata, index, stop);
	}];
}

- (void)enumerateKeysAndMetadataInGroup:(NSString *)group
                            withOptions:(NSEnumerationOptions)options
                                  range:(NSRange)range
                             usingBlock:(void (^)(NSString *key, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group
	                 withOptions:options
	                       range:range
	                  usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id metadata = nil;
		[databaseTransaction getKey:&key metadata:&metadata forRowid:rowid];
						
		block(key, metadata, index, stop);
	}];
}

- (void)enumerateKeysAndObjectsInGroup:(NSString *)group
                            usingBlock:
                                 (void (^)(NSString *key, id object, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id object = nil;
		[databaseTransaction getKey:&key object:&object forRowid:rowid];
		
		block(key, object, index, stop);
	}];
}

- (void)enumerateKeysAndObjectsInGroup:(NSString *)group
                           withOptions:(NSEnumerationOptions)options
                            usingBlock:
                                 (void (^)(NSString *key, id object, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group withOptions:options usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id object = nil;
		[databaseTransaction getKey:&key object:&object forRowid:rowid];
		
		block(key, object, index, stop);
	}];
}

- (void)enumerateKeysAndObjectsInGroup:(NSString *)group
                           withOptions:(NSEnumerationOptions)options
                                 range:(NSRange)range
                            usingBlock:
                                 (void (^)(NSString *key, id object, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group
	                 withOptions:options
	                       range:range
	                  usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id object = nil;
		[databaseTransaction getKey:&key object:&object forRowid:rowid];
		
		block(key, object, index, stop);
	}];
}

- (void)enumerateRowsInGroup:(NSString *)group
                  usingBlock:(void (^)(NSString *key, id object, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id object = nil;
		id metadata = nil;
		[databaseTransaction getKey:&key object:&object metadata:&metadata forRowid:rowid];
		
		block(key, object, metadata, index, stop);
	}];
}

- (void)enumerateRowsInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)options
                  usingBlock:(void (^)(NSString *key, id object, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group withOptions:options usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id object = nil;
		id metadata = nil;
		[databaseTransaction getKey:&key object:&object metadata:&metadata forRowid:rowid];
		
		block(key, object, metadata, index, stop);
	}];
}

- (void)enumerateRowsInGroup:(NSString *)group
                 withOptions:(NSEnumerationOptions)options
                       range:(NSRange)range
                  usingBlock:(void (^)(NSString *key, id object, id metadata, NSUInteger index, BOOL *stop))block
{
	if (block == NULL) return;
	
	[self enumerateRowidsInGroup:group
	                 withOptions:options
	                       range:range
	                  usingBlock:^(int64_t rowid, NSUInteger index, BOOL *stop) {
		
		NSString *key = nil;
		id object = nil;
		id metadata = nil;
		[databaseTransaction getKey:&key object:&object metadata:&metadata forRowid:rowid];
		
		block(key, object, metadata, index, stop);
	}];
}

@end
