#import "ALApplicationList.h"

#import <ImageIO/ImageIO.h>
#import <UIKit/UIKit.h>
#import <SpringBoard/SpringBoard.h>
#import <CaptainHook/CaptainHook.h>
#import <dlfcn.h>

#import "LightMessaging/LightMessaging.h"

CHDeclareClass(SBApplicationController);
CHDeclareClass(SBIconModel);
CHDeclareClass(SBIconViewMap);

@interface SBIconViewMap : NSObject {
	SBIconModel *_model;
	// ...
}
+ (SBIconViewMap *)switcherMap;
+ (SBIconViewMap *)homescreenMap;
- (SBIconModel *)iconModel;
@end


NSString *const ALIconLoadedNotification = @"ALIconLoadedNotification";
NSString *const ALDisplayIdentifierKey = @"ALDisplayIdentifier";
NSString *const ALIconSizeKey = @"ALIconSize";

enum {
	ALMessageIdGetApplications,
	ALMessageIdIconForSize,
	ALMessageIdValueForKey,
	ALMessageIdValueForKeyPath,
	ALMessageIdGetApplicationCount
};

static LMConnection connection = {
	MACH_PORT_NULL,
	"applist.datasource"
};

@interface SBIconModel ()
- (SBApplicationIcon *)applicationIconForDisplayIdentifier:(NSString *)displayIdentifier;
@end

@interface UIImage (iOS40)
+ (UIImage *)imageWithCGImage:(CGImageRef)imageRef scale:(CGFloat)scale orientation:(int)orientation;
@end

__attribute__((visibility("hidden")))
@interface ALApplicationListImpl : ALApplicationList
@end

static ALApplicationList *sharedApplicationList;

@implementation ALApplicationList

+ (void)initialize
{
	if (self == [ALApplicationList class] && !CHClass(SBIconModel)) {
		sharedApplicationList = [[self alloc] init];
	}
}

+ (ALApplicationList *)sharedApplicationList
{
	return sharedApplicationList;
}

- (id)init
{
	if ((self = [super init])) {
		if (sharedApplicationList) {
			[self release];
			@throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Only one instance of ALApplicationList is permitted at a time! Use [ALApplicationList sharedApplicationList] instead." userInfo:nil];
		}
		NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
		cachedIcons = [[NSMutableDictionary alloc] init];
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didReceiveMemoryWarning) name:UIApplicationDidReceiveMemoryWarningNotification object:nil];
		[pool drain];
	}
	return self;
}

- (void)dealloc
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	[cachedIcons release];
	[super dealloc];
}

- (NSInteger)applicationCount
{
	LMResponseBuffer buffer;
	LMConnectionSendTwoWay(&connection, ALMessageIdGetApplicationCount, NULL, 0, &buffer);
	return LMResponseConsumeInteger(&buffer);
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<ALApplicationList: %p applicationCount=%d>", self, self.applicationCount];
}

- (void)didReceiveMemoryWarning
{
	OSSpinLockLock(&spinLock);
	[cachedIcons removeAllObjects];
	OSSpinLockUnlock(&spinLock);
}

- (NSDictionary *)applications
{
	return [self applicationsFilteredUsingPredicate:nil];
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
{
	LMResponseBuffer buffer;
	LMConnectionSendTwoWayData(&connection, ALMessageIdGetApplications, (CFDataRef)[NSKeyedArchiver archivedDataWithRootObject:predicate], &buffer);
	id result = LMResponseConsumePropertyList(&buffer);
	return [result isKindOfClass:[NSDictionary class]] ? result : nil;
}

- (id)valueForKeyPath:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (!keyPath || !displayIdentifier)
		return nil;
	LMResponseBuffer buffer;
	LMConnectionSendTwoWayPropertyList(&connection, ALMessageIdValueForKeyPath, [NSDictionary dictionaryWithObjectsAndKeys:keyPath, @"key", displayIdentifier, @"displayIdentifier", nil], &buffer);
	return LMResponseConsumePropertyList(&buffer);
}

- (id)valueForKey:(NSString *)key forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (!key || !displayIdentifier)
		return nil;
	LMResponseBuffer buffer;
	LMConnectionSendTwoWayPropertyList(&connection, ALMessageIdValueForKey, [NSDictionary dictionaryWithObjectsAndKeys:key, @"key", displayIdentifier, @"displayIdentifier", nil], &buffer);
	return LMResponseConsumePropertyList(&buffer);
}

- (void)postNotificationWithUserInfo:(NSDictionary *)userInfo
{
	[[NSNotificationCenter defaultCenter] postNotificationName:ALIconLoadedNotification object:self userInfo:userInfo];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	if (iconSize <= 0)
		return NULL;
	NSString *key = [displayIdentifier stringByAppendingFormat:@"#%f", (CGFloat)iconSize];
	OSSpinLockLock(&spinLock);
	CGImageRef result = (CGImageRef)[cachedIcons objectForKey:key];
	if (result) {
		result = CGImageRetain(result);
		OSSpinLockUnlock(&spinLock);
		return result;
	}
	OSSpinLockUnlock(&spinLock);
	LMResponseBuffer buffer;
	LMConnectionSendTwoWayPropertyList(&connection, ALMessageIdIconForSize, [NSDictionary dictionaryWithObjectsAndKeys:[NSNumber numberWithUnsignedInteger:iconSize], @"iconSize", displayIdentifier, @"displayIdentifier", nil], &buffer);
	result = [LMResponseConsumeImage(&buffer) CGImage];
	if (!result)
		return NULL;
	OSSpinLockLock(&spinLock);
	[cachedIcons setObject:(id)result forKey:key];
	OSSpinLockUnlock(&spinLock);
	NSDictionary *userInfo = [NSDictionary dictionaryWithObjectsAndKeys:
	                          [NSNumber numberWithInteger:iconSize], ALIconSizeKey,
	                          displayIdentifier, ALDisplayIdentifierKey,
	                          nil];
	if ([NSThread isMainThread])
		[self postNotificationWithUserInfo:userInfo];
	else
		[self performSelectorOnMainThread:@selector(postNotificationWithUserInfo:) withObject:userInfo waitUntilDone:YES];
	return CGImageRetain(result);
}

- (UIImage *)iconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	CGImageRef image = [self copyIconOfSize:iconSize forDisplayIdentifier:displayIdentifier];
	if (!image)
		return nil;
	UIImage *result;
	if ([UIImage respondsToSelector:@selector(imageWithCGImage:scale:orientation:)]) {
		CGFloat scale = (CGImageGetWidth(image) + CGImageGetHeight(image)) / (CGFloat)(iconSize + iconSize);
		result = [UIImage imageWithCGImage:image scale:scale orientation:0];
	} else {
		result = [UIImage imageWithCGImage:image];
	}
	CGImageRelease(image);
	return result;
}

- (BOOL)hasCachedIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	NSString *key = [displayIdentifier stringByAppendingFormat:@"#%f", (CGFloat)iconSize];
	OSSpinLockLock(&spinLock);
	id result = [cachedIcons objectForKey:key];
	OSSpinLockUnlock(&spinLock);
	return result != nil;
}

@end

@interface SBIcon ()

- (UIImage *)getIconImage:(NSInteger)sizeIndex;

@end

@implementation ALApplicationListImpl

static void processMessage(SInt32 messageId, mach_port_t replyPort, CFDataRef data)
{
	switch (messageId) {
		case ALMessageIdGetApplications: {
			NSDictionary *result;
			if (data && CFDataGetLength(data)) {
				NSPredicate *predicate = [NSKeyedUnarchiver unarchiveObjectWithData:(NSData *)data];
				result = [predicate isKindOfClass:[NSPredicate class]] ? [sharedApplicationList applicationsFilteredUsingPredicate:predicate] : [sharedApplicationList applications];
			} else {
				result = [sharedApplicationList applications];
			}
			LMSendPropertyListReply(replyPort, result);
			return;
		}
		case ALMessageIdIconForSize: {
			if (!data)
				break;
			NSDictionary *params = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if (![params isKindOfClass:[NSDictionary class]])
				break;
			id iconSize = [params objectForKey:@"iconSize"];
			if (![iconSize respondsToSelector:@selector(floatValue)])
				break;
			NSString *displayIdentifier = [params objectForKey:@"displayIdentifier"];
			if (![displayIdentifier isKindOfClass:[NSString class]])
				break;
			CGImageRef result = [sharedApplicationList copyIconOfSize:[iconSize floatValue] forDisplayIdentifier:displayIdentifier];
			if (result) {
				LMSendImageReply(replyPort, [UIImage imageWithCGImage:result]);
				CGImageRelease(result);
				return;
			}
			break;
		}
		case ALMessageIdValueForKeyPath:
		case ALMessageIdValueForKey: {
			if (!data)
				break;
			NSDictionary *params = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
			if (![params isKindOfClass:[NSDictionary class]])
				break;
			NSString *key = [params objectForKey:@"key"];
			Class stringClass = [NSString class];
			if (![key isKindOfClass:stringClass])
				break;
			NSString *displayIdentifier = [params objectForKey:@"displayIdentifier"];
			if (![displayIdentifier isKindOfClass:stringClass])
				break;
			id result = messageId == ALMessageIdValueForKeyPath ? [sharedApplicationList valueForKeyPath:key forDisplayIdentifier:displayIdentifier] : [sharedApplicationList valueForKey:key forDisplayIdentifier:displayIdentifier];
			LMSendPropertyListReply(replyPort, result);
			return;
		}
		case ALMessageIdGetApplicationCount: {
			LMSendIntegerReply(replyPort, [sharedApplicationList applicationCount]);
			return;
		}
	}
	LMSendReply(replyPort, NULL, 0);
}

static void machPortCallback(CFMachPortRef port, void *bytes, CFIndex size, void *info)
{
	LMMessage *request = bytes;
	if (size < sizeof(LMMessage)) {
		LMSendReply(request->head.msgh_remote_port, NULL, 0);
		LMResponseBufferFree(bytes);
		return;
	}
	// Send Response
	const void *data = LMMessageGetData(request);
	size_t length = LMMessageGetDataLength(request);
	mach_port_t replyPort = request->head.msgh_remote_port;
	CFDataRef cfdata = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, data ?: &data, length, kCFAllocatorNull);
	processMessage(request->head.msgh_id, replyPort, cfdata);
	if (cfdata)
		CFRelease(cfdata);
	LMResponseBufferFree(bytes);
}

#pragma GCC diagnostic ignored "-Wdeprecated-declarations"
- (id)init
{
	if ((self = [super init])) {
		mach_port_t bootstrap = MACH_PORT_NULL;
		task_get_bootstrap_port(mach_task_self(), &bootstrap);
		CFMachPortContext context = { 0, NULL, NULL, NULL, NULL };
		CFMachPortRef machPort = CFMachPortCreate(kCFAllocatorDefault, machPortCallback, &context, NULL);
		CFRunLoopSourceRef machPortSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, machPort, 0);
		CFRunLoopAddSource(CFRunLoopGetCurrent(), machPortSource, kCFRunLoopDefaultMode);
		mach_port_t port = CFMachPortGetPort(machPort);
		kern_return_t err = bootstrap_register(bootstrap, connection.serverName, port);
		if (err) {
			NSLog(@"AppList: Unable to register mach server with error %x", err);
		}
	}
	return self;
}
#pragma GCC diagnostic warning "-Wdeprecated-declarations"

- (NSDictionary *)applications
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	for (SBApplication *app in [CHSharedInstance(SBApplicationController) allApplications])
		[result setObject:[app displayName] forKey:[app displayIdentifier]];
	return result;
}

- (NSInteger)applicationCount
{
	return [[CHSharedInstance(SBApplicationController) allApplications] count];
}

- (NSDictionary *)applicationsFilteredUsingPredicate:(NSPredicate *)predicate
{
	NSMutableDictionary *result = [NSMutableDictionary dictionary];
	NSArray *apps = [CHSharedInstance(SBApplicationController) allApplications];
	if (predicate)
		apps = [apps filteredArrayUsingPredicate:predicate];
	for (SBApplication *app in apps)
		[result setObject:[app displayName] forKey:[app displayIdentifier]];
	return result;
}

- (id)valueForKeyPath:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	SBApplication *app = [CHSharedInstance(SBApplicationController) applicationWithDisplayIdentifier:displayIdentifier];
	return [app valueForKeyPath:keyPath];
}

- (id)valueForKey:(NSString *)keyPath forDisplayIdentifier:(NSString *)displayIdentifier
{
	SBApplication *app = [CHSharedInstance(SBApplicationController) applicationWithDisplayIdentifier:displayIdentifier];
	return [app valueForKey:keyPath];
}

- (CGImageRef)copyIconOfSize:(ALApplicationIconSize)iconSize forDisplayIdentifier:(NSString *)displayIdentifier
{
	SBIcon *icon;
	SBIconModel *iconModel = [CHClass(SBIconViewMap) instancesRespondToSelector:@selector(iconModel)] ? [[CHClass(SBIconViewMap) homescreenMap] iconModel] : CHSharedInstance(SBIconModel);
	if ([iconModel respondsToSelector:@selector(applicationIconForDisplayIdentifier:)])
		icon = [iconModel applicationIconForDisplayIdentifier:displayIdentifier];
	else if ([iconModel respondsToSelector:@selector(iconForDisplayIdentifier:)])
		icon = [iconModel iconForDisplayIdentifier:displayIdentifier];
	else
		return NULL;
	BOOL getIconImage = [icon respondsToSelector:@selector(getIconImage:)];
	SBApplication *app = [CHSharedInstance(SBApplicationController) applicationWithDisplayIdentifier:displayIdentifier];
	UIImage *image;
	if (iconSize <= ALApplicationIconSizeSmall) {
		image = getIconImage ? [icon getIconImage:0] : [icon smallIcon];
		if (image)
			goto finish;
		if ([app respondsToSelector:@selector(pathForSmallIcon)]) {
			image = [UIImage imageWithContentsOfFile:[app pathForSmallIcon]];
			if (image)
				goto finish;
		}
	}
	image = getIconImage ? [icon getIconImage:(kCFCoreFoundationVersionNumber >= 675.0) ? 2 : 1] : [icon icon];
	if (image)
		goto finish;
	if ([app respondsToSelector:@selector(pathForIcon)])
		image = [UIImage imageWithContentsOfFile:[app pathForIcon]];
	if (!image)
		return NULL;
finish:
	return CGImageRetain([image CGImage]);
}

@end

CHConstructor
{
	CHAutoreleasePoolForScope();
	if (CHLoadLateClass(SBIconModel)) {
		CHLoadLateClass(SBIconViewMap);
		CHLoadLateClass(SBApplicationController);
		sharedApplicationList = [[ALApplicationListImpl alloc] init];
	}
}
