
@interface PRCell ()
{
	UILabel *unreadCount, *readCount;
    NSString *failedToLoadImage;
}
@end

static NSDateFormatter *itemDateFormatter;
static NSNumberFormatter *itemCountFormatter;

@implementation PRCell

- (void)awakeFromNib
{
	[super awakeFromNib];
	self.textLabel.numberOfLines = 0;
	self.detailTextLabel.textColor = [UIColor grayColor];

	unreadCount = [[UILabel alloc] initWithFrame:CGRectZero];
	unreadCount.textColor = [UIColor whiteColor];
	unreadCount.textAlignment = NSTextAlignmentCenter;
	unreadCount.layer.cornerRadius = 9.0;
	unreadCount.font = [UIFont boldSystemFontOfSize:12.0];
    unreadCount.hidden = YES;
	[self.contentView addSubview:unreadCount];

	readCount = [[UILabel alloc] initWithFrame:CGRectZero];
	readCount.textColor = [UIColor darkGrayColor];
	readCount.textAlignment = NSTextAlignmentCenter;
	readCount.layer.cornerRadius = 9.0;
	readCount.font = [UIFont systemFontOfSize:12.0];
    readCount.hidden = YES;
	[self.contentView addSubview:readCount];

	static dispatch_once_t onceToken;
	dispatch_once(&onceToken, ^{
		itemDateFormatter = [[NSDateFormatter alloc] init];
		itemDateFormatter.dateStyle = NSDateFormatterShortStyle;
		itemDateFormatter.timeStyle = NSDateFormatterShortStyle;

		itemCountFormatter = [[NSNumberFormatter alloc] init];
		itemCountFormatter.numberStyle = NSNumberFormatterDecimalStyle;
	});

    [[NSNotificationCenter defaultCenter] addObserver:self
											 selector:@selector(networkStateChanged)
												 name:kReachabilityChangedNotification
											   object:nil];
}

- (void)networkStateChanged
{
    if(!failedToLoadImage) return;
    if([[AppDelegate shared].api.reachability currentReachabilityStatus]!=NotReachable)
	{
        [self loadImageAtPath:failedToLoadImage];
	}
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

- (void)setPullRequest:(PullRequest *)pullRequest
{
	NSInteger _commentsNew=0;
	NSInteger _commentsTotal = pullRequest.totalComments.integerValue;
	if([Settings shared].showCommentsEverywhere || pullRequest.isMine || pullRequest.commentedByMe)
	{
		_commentsNew = pullRequest.unreadComments.integerValue;
	}

	NSString *_dates;
	if([Settings shared].showCreatedInsteadOfUpdated)
		_dates = [itemDateFormatter stringFromDate:pullRequest.createdAt];
	else
		_dates = [itemDateFormatter stringFromDate:pullRequest.updatedAt];

	if(pullRequest.userLogin.length)
		_dates = [NSString stringWithFormat:@"%@ - %@",pullRequest.userLogin,_dates];

	readCount.text = [itemCountFormatter stringFromNumber:@(_commentsTotal)];
	CGSize size = [readCount sizeThatFits:CGSizeMake(200, 14.0)];
	readCount.frame = CGRectMake(0, 0, size.width+10.0, 17.0);
	readCount.hidden = (_commentsTotal==0);

	unreadCount.hidden = _commentsNew==0;
	unreadCount.text = [itemCountFormatter stringFromNumber:@(_commentsNew)];
	size = [unreadCount sizeThatFits:CGSizeMake(200, 18.0)];
	unreadCount.frame = CGRectMake(0, 0, size.width+10.0, 17.0);

	self.textLabel.text = pullRequest.title;
	self.detailTextLabel.text = _dates;

	NSString *imagePath = pullRequest.userAvatarUrl;
	if(imagePath)
        [self loadImageAtPath:imagePath];
    else
        failedToLoadImage = nil;
}

- (void)loadImageAtPath:(NSString *)imagePath
{
    if(![[AppDelegate shared].api haveCachedImage:imagePath
                                          forSize:CGSizeMake(40, 40)
                               tryLoadAndCallback:^(id image) {
                                   if(image)
                                   {
                                       self.imageView.image = image;
                                       failedToLoadImage = nil;
                                   }
                                   else
                                   {
                                       self.imageView.image = [UIImage imageNamed:@"avatarPlaceHolder"];
                                       failedToLoadImage = imagePath;
                                   }
                               }])
    {
        self.imageView.image = [UIImage imageNamed:@"avatarPlaceHolder"];
        failedToLoadImage = nil;
    }
}

- (void)layoutSubviews
{
	[super layoutSubviews];

	CGPoint topLeft = CGPointMake(self.imageView.frame.origin.x, self.imageView.frame.origin.y);
	unreadCount.center = topLeft;
	[self.contentView bringSubviewToFront:unreadCount];

	CGPoint bottomRight = CGPointMake(topLeft.x+self.imageView.frame.size.width, topLeft.y+self.imageView.frame.size.height);
	readCount.center = bottomRight;
	[self.contentView bringSubviewToFront:readCount];
}

- (void)setSelected:(BOOL)selected animated:(BOOL)animated
{
	[super setSelected:selected animated:animated];

	unreadCount.backgroundColor = [UIColor redColor];
	readCount.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
}

- (void)setHighlighted:(BOOL)highlighted animated:(BOOL)animated
{
    [super setHighlighted:highlighted animated:animated];

	unreadCount.backgroundColor = [UIColor redColor];
	readCount.backgroundColor = [UIColor colorWithWhite:0.9 alpha:1.0];
}

@end
