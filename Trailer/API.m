
@interface API ()
{
	NSOperationQueue *requestQueue;
	NSDateFormatter *dateFormatter;
    NSString *cacheDirectory;
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	NSInteger networkIndicationCount;
#endif
}
@end

@implementation API

#ifdef __MAC_OS_X_VERSION_MIN_REQUIRED
	#define CACHE_MEMORY 1024*1024*4
	#define CACHE_DISK 1024*1024*128
#else
	#define CACHE_MEMORY 1024*1024*2
	#define CACHE_DISK 1024*1024*8
#endif

- (id)init
{
    self = [super init];
    if (self) {

		NSURLCache *cache = [[NSURLCache alloc] initWithMemoryCapacity:CACHE_MEMORY
														  diskCapacity:CACHE_DISK
															  diskPath:nil];
		[NSURLCache setSharedURLCache:cache];

		dateFormatter = [[NSDateFormatter alloc] init];
		dateFormatter.dateFormat = @"YYYY-MM-DDTHH:MM:SSZ";

		requestQueue = [[NSOperationQueue alloc] init];
		requestQueue.maxConcurrentOperationCount = 8;

		self.reachability = [Reachability reachabilityWithHostName:API_SERVER];
		[self.reachability startNotifier];

        NSFileManager *fileManager = [NSFileManager defaultManager];
        NSURL *appSupportURL = [[fileManager URLsForDirectory:NSCachesDirectory inDomains:NSUserDomainMask] lastObject];
        appSupportURL = [appSupportURL URLByAppendingPathComponent:@"com.housetrip.Trailer"];
        cacheDirectory = appSupportURL.path;

        if([fileManager fileExistsAtPath:cacheDirectory])
            [self clearImageCache];
        else
            [fileManager createDirectoryAtPath:cacheDirectory withIntermediateDirectories:YES attributes:nil error:nil];
	}
    return self;
}

-(void)error:(NSString*)errorString
{
	DLog(@"Failed to fetch %@",errorString);
}

- (void)updateLimitFromServer
{
	[self getRateLimitAndCallback:^(long long remaining, long long limit, long long reset) {
		self.requestsRemaining = remaining;
		self.requestsLimit = limit;
		if(reset>=0)
		{
			[[NSNotificationCenter defaultCenter] postNotificationName:RATE_UPDATE_NOTIFICATION
																object:nil
															  userInfo:nil];
		}
	}];
}

-(void)fetchCommentsForCurrentPullRequestsToMoc:(NSManagedObjectContext *)moc andCallback:(void (^)(BOOL))callback
{
	NSMutableArray *prs1 = [[DataItem newOrUpdatedItemsOfType:@"PullRequest" inMoc:moc] mutableCopy];
	for(PullRequest *r in prs1)
	{
		NSArray *comments = [PRComment commentsForPullRequestUrl:r.url inMoc:moc];
		for(PRComment *c in comments) c.postSyncAction = @(kPostSyncDelete);
	}

	NSInteger totalOperations = 2;
	__block NSInteger succeded = 0;
	__block NSInteger failed = 0;

	typedef void (^completionBlockType)(BOOL);

	completionBlockType completionCallback = ^(BOOL success){
		if(success) succeded++; else failed++;
		if(succeded+failed==totalOperations)
		{
			[DataItem nukeDeletedItemsOfType:@"PRComment" inMoc:moc];
			if(callback) callback(failed==0);
		}
	};

	[self _fetchCommentsForPullRequestIssues:YES toMoc:moc andCallback:completionCallback];

	[self _fetchCommentsForPullRequestIssues:NO toMoc:moc andCallback:completionCallback];
}

-(void)_fetchCommentsForPullRequestIssues:(BOOL)issues toMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSArray *prs = [DataItem newOrUpdatedItemsOfType:@"PullRequest" inMoc:moc];
	if(!prs.count)
	{
		if(callback) callback(YES);
		return;
	}

	NSInteger total = prs.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;

	for(PullRequest *p in prs)
	{
		NSString *link;
		if(issues)
			link = p.issueCommentLink;
		else
			link = p.reviewCommentLink;

		[self getPagedDataInPath:link
				startingFromPage:1
						  params:nil
				 perPageCallback:^(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 PRComment *c = [PRComment commentWithInfo:info moc:moc];
						 if(!c.pullRequestUrl) c.pullRequestUrl = p.url;

						 // check if we're assigned to a just created pull request, in which case we want to "fast forward" its latest comment dates to our own if we're newer
						 if(p.postSyncAction.integerValue == kPostSyncNoteNew)
						 {
							 NSDate *commentCreation = c.createdAt;
							 if(!p.latestReadCommentDate || [p.latestReadCommentDate compare:commentCreation]==NSOrderedAscending)
								 p.latestReadCommentDate = commentCreation;
						 }
					 }
				 } finalCallback:^(BOOL success, NSInteger resultCode) {
					 if(success) succeeded++; else failed++;
					 if(succeeded+failed==total)
					 {
						 callback(failed==0);
					 }
				 }];
	}
}

-(void)fetchRepositoriesAndCallback:(void(^)(BOOL success))callback
{
	[self syncUserDetailsAndCallback:^(BOOL success) {
		if(success)
		{
			NSManagedObjectContext *syncContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSMainQueueConcurrencyType];
			syncContext.parentContext = [AppDelegate shared].dataManager.managedObjectContext;
			syncContext.undoManager = nil;

			NSArray *items = [PullRequest itemsOfType:@"Repo" surviving:YES inMoc:syncContext];
			for(DataItem *i in items) i.postSyncAction = @(kPostSyncDelete);

			items = [PullRequest itemsOfType:@"Org" surviving:YES inMoc:syncContext];
			for(DataItem *i in items) i.postSyncAction = @(kPostSyncDelete);

			[self syncOrgsToMoc:syncContext andCallback:^(BOOL success) {
				if(!success)
				{
					[self error:@"orgs"];
					callback(NO);
				}
				else
				{
					NSArray *orgs = [Org allItemsOfType:@"Org" inMoc:syncContext];
					__block NSInteger count=orgs.count;
					__block BOOL ok = YES;
					for(Org *r in orgs)
					{
						[self syncReposForOrg:r.login toMoc:syncContext andCallback:^(BOOL success) {
							count--;
							if(ok) ok = success;
							if(count==0)
							{
								[self syncReposForUserToMoc:syncContext andCallback:^(BOOL success) {
									if(ok) ok = success;
									if(callback)
									{
										if(ok)
										{
											[DataItem nukeDeletedItemsOfType:@"Repo" inMoc:syncContext];
											[DataItem nukeDeletedItemsOfType:@"Org" inMoc:syncContext];
										}
										else
										{
											DLog(@"%@",[NSError errorWithDomain:@"YOUR_ERROR_DOMAIN"
																		   code:101
																	   userInfo:@{NSLocalizedDescriptionKey:@"Error while fetching data from GitHub"}]);
										}
										if(ok && syncContext.hasChanges) [syncContext save:nil];
										callback(ok);
									}
								}];
							}
						}];
					}
				}
			}];
		}
		else if(callback) callback(NO);
	}];
}

-(void)detectMergedPullRequestsInMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	NSArray *pullRequests = [PullRequest allItemsOfType:@"PullRequest" inMoc:moc];
	NSMutableArray *prsToCheck = [NSMutableArray array];
	for(PullRequest *r in pullRequests)
	{
		Repo *parent = [Repo itemOfType:@"Repo" serverId:r.repoId moc:moc];
		if(r.postSyncAction.integerValue==kPostSyncDelete &&
		   parent.active.boolValue && (parent.postSyncAction.integerValue!=kPostSyncDelete) &&
		   ([Settings shared].showCommentsEverywhere || r.isMine || r.commentedByMe) &&
		   (r.condition.integerValue == kPullRequestConditionOpen))
		{
			[prsToCheck addObject:r]; // check closed status
		}
	}
	[self _detectMergedPullRequests:prsToCheck andCallback:callback];
}

-(void)_detectMergedPullRequests:(NSMutableArray *)prsToCheck andCallback:(void(^)(BOOL success))callback
{
	if(prsToCheck.count==0)
	{
		callback(YES);
		return;
	}
	PullRequest *r = [prsToCheck objectAtIndex:0];
	[prsToCheck removeObjectAtIndex:0];

	DLog(@"Checking closed PR to see if it was merged: %@",r.title);

	Repo *parent = [Repo itemOfType:@"Repo" serverId:r.repoId moc:r.managedObjectContext];

	[self get:[NSString stringWithFormat:@"/repos/%@/pulls/%@",parent.fullName,r.number]
   parameters:nil
	  success:^(NSHTTPURLResponse *response, id data) {

		  NSDictionary *mergeInfo = [data ofk:@"merged_by"];
		  if(mergeInfo)
		  {
			  DLog(@"detected merged PR: %@",r.title);
			  NSString *mergeUserId = [[mergeInfo  ofk:@"id"] stringValue];
			  DLog(@"merged by user id: %@, our id is: %@",mergeUserId,[Settings shared].localUserId);
			  BOOL mergedByMyself = [mergeUserId isEqualToString:[Settings shared].localUserId];
			  if(!([Settings shared].dontKeepMyPrs && mergedByMyself)) // someone else merged
			  {
				  DLog(@"announcing merged PR: %@",r.title);
				  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this
				  r.condition = @kPullRequestConditionMerged;
				  [[AppDelegate shared] postNotificationOfType:kPrMerged forItem:r];
			  }
			  else
			  {
				  DLog(@"will not announce merged PR: %@",r.title);
			  }
		  }
		  else
		  {
			  DLog(@"detected closed PR: %@",r.title);
			  if([Settings shared].alsoKeepClosedPrs)
			  {
				  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this
				  r.condition = @kPullRequestConditionClosed;
				  [[AppDelegate shared] postNotificationOfType:kPrClosed forItem:r];
			  }
		  }
		  [self _detectMergedPullRequests:prsToCheck andCallback:callback];

	  } failure:^(NSHTTPURLResponse *response, NSError *error) {
		  r.postSyncAction = @(kPostSyncDoNothing); // don't delete this, we couldn't check, play it safe
		  [self _detectMergedPullRequests:prsToCheck andCallback:callback];
	  }];
}

-(void)fetchPullRequestsForActiveReposAndCallback:(void(^)(BOOL success))callback
{
	[self syncUserDetailsAndCallback:^(BOOL success) {
		if(success)
		{
			NSManagedObjectContext *syncContext = [[NSManagedObjectContext alloc] initWithConcurrencyType:NSConfinementConcurrencyType];
			syncContext.parentContext = [AppDelegate shared].dataManager.managedObjectContext;
			syncContext.undoManager = nil;

			NSArray *prs = [PullRequest itemsOfType:@"PullRequest" surviving:YES inMoc:syncContext];
			for(PullRequest *r in prs)
				if(r.condition.integerValue == kPullRequestConditionOpen)
					r.postSyncAction = @(kPostSyncDelete);
			NSMutableArray *activeRepos = [[Repo activeReposInMoc:syncContext] mutableCopy];
			[self _fetchPullRequestsForRepos:activeRepos toMoc:syncContext andCallback:^(BOOL success) {
				if(success)
				{
					[self fetchCommentsForCurrentPullRequestsToMoc:syncContext andCallback:^(BOOL success) {
						if(success)
						{
							[self detectMergedPullRequestsInMoc:syncContext andCallback:^(BOOL success) {
								if(success)
								{
									[DataItem nukeDeletedItemsOfType:@"Repo" inMoc:syncContext];
									[DataItem nukeDeletedItemsOfType:@"PullRequest" inMoc:syncContext];

									NSArray *surviving = [PullRequest itemsOfType:@"PullRequest" surviving:YES inMoc:syncContext];
									for(PullRequest *r in surviving) [r postProcess];

									if(success && syncContext.hasChanges)
									{
										[syncContext save:nil];
									}
									if(callback) callback(success);
								}
							}];
						}
					}];
				}
				else if(callback) callback(NO);
			}];
		}
		else if(callback) callback(NO);
	}];
}

-(void)_fetchPullRequestsForRepos:(NSMutableArray *)repos toMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	if(!repos.count)
	{
		if(callback) callback(YES);
		return;
	}
	NSInteger total = repos.count;
	__block NSInteger succeeded = 0;
	__block NSInteger failed = 0;
	for(Repo *r in repos)
	{
		[self getPagedDataInPath:[NSString stringWithFormat:@"/repos/%@/pulls",r.fullName]
				startingFromPage:1
						  params:nil
				 perPageCallback:^(id data, BOOL lastPage) {
					 for(NSDictionary *info in data)
					 {
						 [PullRequest pullRequestWithInfo:info moc:moc];
					 }
				 } finalCallback:^(BOOL success, NSInteger resultCode) {
					 if(success)
					 {
						 succeeded++;
					 }
					 else
					 {
						 if(resultCode==404) // 404 is an acceptable answer, it means the repo is gone
						 {
							 succeeded++;
							 r.postSyncAction = @(kPostSyncDelete);
						 }
						 else
						 {
							 failed++;
						 }
					 }
					 if(succeeded+failed==total)
					 {
						 callback(failed==0);
					 }
				 }];
	}
}

-(void)syncReposForUserToMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	[self getPagedDataInPath:@"/user/repos"
			startingFromPage:1
					  params:nil
			 perPageCallback:^(id data, BOOL lastPage) {
				 for(NSDictionary *info in data)
				 {
					 [Repo repoWithInfo:info moc:moc];
				 }
			 } finalCallback:^(BOOL success, NSInteger resultCode) {
				 if(callback) callback(success);
			 }];
}

-(void)syncReposForOrg:(NSString*)orgLogin toMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	[self getPagedDataInPath:[NSString stringWithFormat:@"/orgs/%@/repos",orgLogin]
			startingFromPage:1
					  params:nil
			 perPageCallback:^(id data, BOOL lastPage) {
				 for(NSDictionary *info in data)
				 {
					 [Repo repoWithInfo:info moc:moc];
				 }
			 } finalCallback:^(BOOL success, NSInteger resultCode) {
				 if(callback) callback(success);
			 }];
}

-(void)syncOrgsToMoc:(NSManagedObjectContext *)moc andCallback:(void(^)(BOOL success))callback
{
	[self getPagedDataInPath:@"/user/orgs"
			startingFromPage:1
					  params:nil
			 perPageCallback:^(id data, BOOL lastPage) {
				 for(NSDictionary *info in data) [Org orgWithInfo:info moc:moc];
			 } finalCallback:^(BOOL success, NSInteger resultCode) {
				 if(callback) callback(success);
			 }];
}

-(void)syncUserDetailsAndCallback:(void (^)(BOOL))callback
{
	[self getDataInPath:@"/user"
				 params:nil
			andCallback:^(id data, BOOL lastPage, NSInteger resultCode) {
				if(data)
				{
					[Settings shared].localUser = [data ofk:@"login"];
					[Settings shared].localUserId = [data ofk:@"id"];
					[[NSUserDefaults standardUserDefaults] synchronize];
					if(callback) callback(YES);
				}
				else if(callback) callback(NO);
			}];
}

-(void)getPagedDataInPath:(NSString*)path
		 startingFromPage:(NSInteger)page
				   params:(NSDictionary*)params
		  perPageCallback:(void(^)(id data, BOOL lastPage))pageCallback
			finalCallback:(void(^)(BOOL success, NSInteger resultCode))finalCallback
{
	NSMutableDictionary *mparams;
	if(params) mparams = [params mutableCopy];
	else mparams = [NSMutableDictionary dictionaryWithCapacity:2];
	mparams[@"page"] = @(page);
	mparams[@"per_page"] = @100;
	[self getDataInPath:path
				 params:mparams
			andCallback:^(id data, BOOL lastPage, NSInteger resultCode) {
				if(data)
				{
					if(pageCallback)
					{
						pageCallback(data,lastPage);
					}

					if(lastPage)
					{
						finalCallback(YES, resultCode);
					}
					else
					{
						[self getPagedDataInPath:path
								startingFromPage:page+1
										  params:params
								 perPageCallback:pageCallback
								   finalCallback:finalCallback];
					}
				}
				else
				{
					finalCallback(NO, resultCode);
				}
			}];
}

-(void)getDataInPath:(NSString*)path params:(NSDictionary*)params andCallback:(void(^)(id data, BOOL lastPage, NSInteger resultCode))callback
{
	[self get:path
   parameters:params
	  success:^(NSHTTPURLResponse *response, id data) {
		  self.requestsRemaining = [[response allHeaderFields][@"X-RateLimit-Remaining"] floatValue];
		  self.requestsLimit = [[response allHeaderFields][@"X-RateLimit-Limit"] floatValue];
		  float epochSeconds = [[response allHeaderFields][@"X-RateLimit-Reset"] floatValue];
		  NSDate *date = [NSDate dateWithTimeIntervalSince1970:epochSeconds];
		  NSDateFormatter *formatter = [[NSDateFormatter alloc] init];
		  formatter.dateStyle = NSDateFormatterMediumStyle;
		  formatter.timeStyle = NSDateFormatterMediumStyle;
		  self.resetDate = [formatter stringFromDate:date];
		  [[NSNotificationCenter defaultCenter] postNotificationName:RATE_UPDATE_NOTIFICATION
															  object:nil
															userInfo:nil];
		  if(callback) callback(data, [API lastPage:response], response.statusCode);
	  } failure:^(NSHTTPURLResponse *response, NSError *error) {
		  DLog(@"Failure: %@",error);
		  if(callback) callback(nil, NO, response.statusCode);
	  }];
}

-(void)getRateLimitAndCallback:(void (^)(long long, long long, long long))callback
{
	[self get:@"/rate_limit"
	  parameters:nil
		 success:^(NSHTTPURLResponse *response, id data) {
			 long long requestsRemaining = [[response allHeaderFields][@"X-RateLimit-Remaining"] longLongValue];
			 long long requestLimit = [[response allHeaderFields][@"X-RateLimit-Limit"] longLongValue];
			 long long epochSeconds = [[response allHeaderFields][@"X-RateLimit-Reset"] longLongValue];
			 if(callback) callback(requestsRemaining,requestLimit,epochSeconds);
		 } failure:^(NSHTTPURLResponse *response, NSError *error) {
			 if(callback) callback(-1, -1, -1);
		 }];
}

+(BOOL)lastPage:(NSHTTPURLResponse*)response
{
	NSString *linkHeader = [[response allHeaderFields] ofk:@"Link"];
	if(!linkHeader) return YES;
	return ([linkHeader rangeOfString:@"rel=\"next\""].location==NSNotFound);
}

-(NSOperation *)get:(NSString *)path
		 parameters:(NSDictionary *)params
			success:(void(^)(NSHTTPURLResponse *response, id data))successCallback
			failure:(void(^)(NSHTTPURLResponse *response, NSError *error))failureCallback
{
	[self networkIndicationStart];

	NSString *authToken = [Settings shared].authToken;
	NSBlockOperation *o = [NSBlockOperation blockOperationWithBlock:^{

		NSString *expandedPath;
		if([path rangeOfString:@"/"].location==0) expandedPath = [[@"https://" stringByAppendingString:API_SERVER] stringByAppendingString:path];
		else expandedPath = path;

		if(params.count)
		{
			expandedPath = [expandedPath stringByAppendingString:@"?"];
			NSMutableArray *pairs = [NSMutableArray arrayWithCapacity:params.count];
			for(NSString *key in params)
			{
				[pairs addObject:[NSString stringWithFormat:@"%@=%@", key, params[key]]];
			}
			expandedPath = [expandedPath stringByAppendingString:[pairs componentsJoinedByString:@"&"]];
		}

		NSMutableURLRequest *r = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:expandedPath]
															  cachePolicy:NSURLRequestUseProtocolCachePolicy
														  timeoutInterval:NETWORK_TIMEOUT];
		[r setValue:@"Trailer" forHTTPHeaderField:@"User-Agent"];
		[r setValue:@"application/x-www-form-urlencoded" forHTTPHeaderField:@"Content-Type"];
		if(authToken) [r setValue:[@"token " stringByAppendingString:authToken] forHTTPHeaderField:@"Authorization"];

		NSError *error;
		NSHTTPURLResponse *response;
		NSData *data = [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:&error];
		if(!error && response.statusCode>299)
		{
			error = [NSError errorWithDomain:@"Error response received" code:response.statusCode userInfo:nil];
		}
		if(error)
		{
			DLog(@"GET %@ - FAILED: %@",expandedPath,error);
			if(failureCallback)
			{
				dispatch_async(dispatch_get_main_queue(), ^{
					failureCallback(response, error);
				});
			}
		}
		else
		{
			DLog(@"GET %@ - RESULT: %ld",expandedPath,(long)response.statusCode);
			if(successCallback)
			{
				id parsedData = nil;
				if(data.length) parsedData = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
				dispatch_async(dispatch_get_main_queue(), ^{
					successCallback(response,parsedData);
				});
			}
		}

		[self networkIndicationEnd];
	}];
	o.queuePriority = NSOperationQueuePriorityVeryHigh;
	[requestQueue addOperation:o];
	return o;
}

// warning: now calls back on thread!!
- (NSOperation *)getImage:(NSString *)path
				  success:(void(^)(NSHTTPURLResponse *response, NSData *imageData))successCallback
				  failure:(void(^)(NSHTTPURLResponse *response, NSError *error))failureCallback
{
	double delayInSeconds = 0.5;
	dispatch_time_t popTime = dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delayInSeconds * NSEC_PER_SEC));
	dispatch_after(popTime, dispatch_get_main_queue(), ^(void){
		[self networkIndicationStart];
	});

	NSBlockOperation *o = [NSBlockOperation blockOperationWithBlock:^{

		NSMutableURLRequest *r = [[NSMutableURLRequest alloc] initWithURL:[NSURL URLWithString:path]
															  cachePolicy:NSURLRequestReturnCacheDataElseLoad
														  timeoutInterval:NETWORK_TIMEOUT];
		[r setValue:@"Trailer" forHTTPHeaderField:@"User-Agent"];

		NSError *error;
		NSHTTPURLResponse *response;
		NSData *data = [NSURLConnection sendSynchronousRequest:r returningResponse:&response error:&error];
		if(!error && response.statusCode>299)
		{
			error = [NSError errorWithDomain:@"Error response received" code:response.statusCode userInfo:nil];
		}
		if(error)
		{
			DLog(@"GET IMAGE %@ - FAILED: %@",path,error);
			if(failureCallback)
			{
                failureCallback(response, error);
			}
		}
		else
		{
			DLog(@"GET IMAGE %@ - RESULT: %ld",path,(long)response.statusCode);
			if(successCallback)
			{
				if(data.length)
				{
                    successCallback(response, data);
				}
				else
				{
                    failureCallback(response, error);
				}
			}
		}

		[self networkIndicationEnd];
	}];
	o.queuePriority = NSOperationQueuePriorityVeryLow;
	[requestQueue addOperation:o];
	return o;
}

- (void)networkIndicationStart
{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	dispatch_async(dispatch_get_main_queue(), ^{
		if(++networkIndicationCount==1)
			[UIApplication sharedApplication].networkActivityIndicatorVisible = YES;
	});
#endif
}

- (void)networkIndicationEnd
{
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
	dispatch_async(dispatch_get_main_queue(), ^{
		if(--networkIndicationCount==0)
			[UIApplication sharedApplication].networkActivityIndicatorVisible = NO;
	});
#endif
}

- (void)clearImageCache
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:nil];
    for(NSString *f in files)
    {
        if([f rangeOfString:@"imgcache-"].location==0)
        {
            NSString *path = [cacheDirectory stringByAppendingPathComponent:f];
            [fileManager removeItemAtPath:path error:nil];
        }
    }
}

- (void)expireOldImageCacheEntries
{
    NSFileManager *fileManager = [NSFileManager defaultManager];
    NSArray *files = [fileManager contentsOfDirectoryAtPath:cacheDirectory error:nil];
    for(NSString *f in files)
    {
        NSDate *now = [NSDate date];
        if([f rangeOfString:@"imgcache-"].location==0)
        {
            NSString *path = [cacheDirectory stringByAppendingPathComponent:f];
            NSError *error;
            NSDictionary *attributes = [fileManager attributesOfItemAtPath:path error:&error];
            NSDate *date = attributes[NSFileCreationDate];
            if([now timeIntervalSinceDate:date]>(3600.0*24))
                [fileManager removeItemAtPath:path error:nil];
        }
    }
}

- (BOOL)haveCachedImage:(NSString *)path
                forSize:(CGSize)imageSize
     tryLoadAndCallback:(void (^)(id image))callbackOrNil
{
    // mix image path, size, and app version into one md5
	NSString *currentAppVersion = [[[NSBundle mainBundle] infoDictionary] objectForKey:@"CFBundleShortVersionString"];
    NSString *imageKey = [[NSString stringWithFormat:@"%@ %f %f %@",
                           path,
                           imageSize.width,
                           imageSize.height,
                           currentAppVersion] md5hash];
    NSString *imagePath = [cacheDirectory stringByAppendingPathComponent:[@"imgcache-" stringByAppendingString:imageKey]];

    NSFileManager *fileManager = [NSFileManager defaultManager];
    if([fileManager fileExistsAtPath:imagePath])
    {
        id ret;
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
        ret = [UIImage imageWithContentsOfFile:imagePath];
#else
        ret = [[NSImage alloc] initWithContentsOfFile:imagePath];
#endif
        if(ret)
        {
            if(callbackOrNil) callbackOrNil(ret);
            return YES;
        }
        else
        {
            [fileManager removeItemAtPath:imagePath error:nil];
        }
    }

    if(callbackOrNil)
    {
        [self getImage:path
               success:^(NSHTTPURLResponse *response, NSData *imageData) {
                   id image = nil;
                   if(imageData)
                   {
#ifdef __IPHONE_OS_VERSION_MIN_REQUIRED
                       image = [[UIImage imageWithData:imageData] scaleToFillPixelSize:imageSize];
                       [UIImagePNGRepresentation(image) writeToFile:imagePath atomically:YES];
#else
                       image = [[[NSImage alloc] initWithData:imageData] scaleToFillSize:imageSize];
                       [[image TIFFRepresentation] writeToFile:imagePath atomically:YES];
#endif
                   }
                   dispatch_async(dispatch_get_main_queue(), ^{
                       callbackOrNil(image);
                   });
               } failure:^(NSHTTPURLResponse *response, NSError *error) {
                   dispatch_async(dispatch_get_main_queue(), ^{
                       callbackOrNil(nil);
                   });
               }];
    }

    return NO;
}

@end
