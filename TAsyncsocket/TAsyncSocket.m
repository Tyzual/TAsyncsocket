//
//  TAsyncSocket.m
//  TA-SDK
//
//  Created by tyzual on 11/09/2017.
//  Copyright © 2017 TyzuaL. All rights reserved.
//

#import "TAsyncSocket.h"


const NSInteger ERROR_CODE_SOCKET_ISCONNECTING = 1;
const NSInteger ERROR_CODE_SOCKET_ISCONNECTED = 2;
const NSInteger ERROR_CODE_SOCKET_CREATE = 3;
const NSInteger ERROR_CODE_SOCKET_DISCONNECT = 4;
const NSInteger ERROR_CODE_SOCKET_STREAM = 5;


static NSString *const TAsyncSocketName = @"TASyncSocket";

@interface TAsyncSocketWritePacket : NSObject

@property (nonatomic, strong) NSData *data;
@property (nonatomic, strong) NSNumber *tag;

@end

@implementation TAsyncSocketWritePacket
@end


@interface TAsyncSocketReadPacket : NSObject

@property (nonatomic, strong) NSMutableData *buffer;
@property (nonatomic, strong) NSNumber *offset;
@property (nonatomic, strong) NSNumber *length;
@property (nonatomic, strong) NSNumber *tag;

@end

@implementation TAsyncSocketReadPacket
@end

@interface TAsyncSocket () <NSStreamDelegate>

@property (nonatomic, weak) NSObject<TAsyncSocketDelegate> *delegate;

@property (nonatomic, strong) dispatch_queue_t taskQueue;
@property (nonatomic, strong) dispatch_queue_t delegateQueue;
@property (nonatomic, strong) NSThread *streamThread;

@property (nonatomic, assign) BOOL isConnecting;
@property (nonatomic, strong) NSInputStream *readStream;
@property (nonatomic, assign) BOOL readStreamOpened;
@property (nonatomic, strong) NSOutputStream *writeStream;
@property (nonatomic, assign) BOOL writeStreamOpened;

@property (nonatomic, strong) NSMutableArray<TAsyncSocketWritePacket *> *writePackets;
@property (nonatomic, strong) NSMutableArray<TAsyncSocketReadPacket *> *readPackets;

@property (nonatomic, assign) uint32_t writeCount;

@property (nonatomic, strong) NSMutableData *buffer;


@end

@implementation TAsyncSocket

- (instancetype _Nullable)initWithDelegate:(NSObject<TAsyncSocketDelegate> *_Nonnull)delegate
{
	return [self initWithDelegate:delegate delegateQueue:NULL];
}

- (instancetype _Nullable)initWithDelegate:(NSObject<TAsyncSocketDelegate> *_Nonnull)delegate delegateQueue:(dispatch_queue_t _Nullable)dq
{
	if (delegate == nil)
		return nil;

	if ((self = [super init]) != nil)
	{
		self.delegate = delegate;
		self.taskQueue = dispatch_queue_create("MTAStream", DISPATCH_QUEUE_SERIAL);
		if (dq != NULL)
		{
			self.delegateQueue = dq;
		}
		else
		{
			self.delegateQueue = dispatch_get_main_queue();
		}
		_isConnected = NO;
		self.isConnecting = NO;
		self.readStreamOpened = NO;
		self.writeStreamOpened = NO;
		self.writeCount = 0;
		self.writePackets = [[NSMutableArray<TAsyncSocketWritePacket *> alloc] init];
		self.readPackets = [[NSMutableArray<TAsyncSocketReadPacket *> alloc] init];
		self.buffer = [[NSMutableData alloc] init];
		self.streamThread = [[NSThread alloc] initWithTarget:self
													selector:@selector(startStreamThread)
													  object:nil];
		[self.streamThread start];
	}
	return self;
}

- (void)dealloc
{
	self.delegate = nil;
	self.taskQueue = nil;
	self.delegateQueue = nil;
	if ([NSThread currentThread] == self.streamThread)
	{
		self.readStream.delegate = nil;
		self.writeStream.delegate = nil;
		[self.readStream close];
		[self.writeStream close];
		[self.readStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		[self.writeStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		self.readStream = nil;
		self.writeStream = nil;
	}
	else
	{
		[self syncInStreamThread:^{
			@autoreleasepool
			{
				self.readStream.delegate = nil;
				self.writeStream.delegate = nil;
				[self.readStream close];
				[self.writeStream close];
				[self.readStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
				[self.writeStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
				self.readStream = nil;
				self.writeStream = nil;
			}
		}];
	}
}

- (BOOL)connectToHost:(NSString *_Nonnull)host onPort:(uint16_t)port error:(NSError *_Nullable __autoreleasing *_Nullable)errPtr
{
	@synchronized(self)
	{
		if (self.isConnecting)
		{
			if (errPtr)
				*errPtr = [self makeError:@"socket is connecting" withErroCode:ERROR_CODE_SOCKET_ISCONNECTING];

			return NO;
		}
		self.isConnecting = YES;

		if (self.isConnected)
		{
			if (errPtr)
				*errPtr = [self makeError:@"socket is connected" withErroCode:ERROR_CODE_SOCKET_ISCONNECTED];

			return NO;
		}

		[self asyncInStreamThread:^{
			@autoreleasepool
			{
				_host = [host copy];
				_port = port;
				CFStringRef cfHost = (__bridge CFStringRef)host;
				CFReadStreamRef cfReadStream;
				CFWriteStreamRef cfWriteStream;
				CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, cfHost, port, &cfReadStream, &cfWriteStream);
				CFRelease(cfHost);
				if (cfReadStream == NULL || cfWriteStream == NULL)
				{
					if (cfReadStream != NULL)
						CFReadStreamClose(cfReadStream);
					if (cfWriteStream != NULL)
						CFWriteStreamClose(cfWriteStream);

					[self asyncInDelegateQueue:^{
						if (self.delegate)
						{
							NSObject<TAsyncSocketDelegate> *strongDelegate = self.delegate;
							if ([strongDelegate respondsToSelector:@selector(socketDidDisconnect:withError:)])
							{
								[strongDelegate socketDidDisconnect:self withError:[self makeError:@"cannot create Stream" withErroCode:ERROR_CODE_SOCKET_CREATE]];
							}
						}
					}];
					return;
				}
				self.readStream = (__bridge NSInputStream *)cfReadStream;
				self.writeStream = (__bridge NSOutputStream *)cfWriteStream;
				[self.readStream setDelegate:self];
				[self.writeStream setDelegate:self];
				[self.readStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
				[self.writeStream scheduleInRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
				[self.readStream open];
				[self.writeStream open];

				CFRelease(cfReadStream);
				CFRelease(cfWriteStream);
			}
		}];
		return YES;
	}
}

- (void)writeData:(NSData *_Nonnull)data
			  tag:(long)tag
{
	if (!data || !data.length)
		return;

	[self asyncInTaskQueue:^{
		TAsyncSocketWritePacket *packet = [[TAsyncSocketWritePacket alloc] init];
		packet.data = [data copy];
		packet.tag = [[NSNumber alloc] initWithLong:tag];

		[self.writePackets addObject:packet];
		[self checkWrite];
	}];
}

- (void)checkWrite
{
	[self asyncInStreamThread:^{
		if (!self.isConnected)
			return;

		if (self.writeCount == 0)
			return;

		if (self.writePackets.count > 0)
		{
			TAsyncSocketWritePacket *packet = [self.writePackets objectAtIndex:0];
			[self.writePackets removeObjectAtIndex:0];
			[self.writeStream write:packet.data.bytes maxLength:packet.data.length];
			NSNumber *tag = packet.tag;
			--self.writeCount;

			[self asyncInDelegateQueue:^{
				if (self.delegate)
				{
					NSObject<TAsyncSocketDelegate> *strongDelegate = self.delegate;
					if ([strongDelegate respondsToSelector:@selector(socket:didWriteDataWithTag:)])
					{
						[strongDelegate socket:self didWriteDataWithTag:tag.longValue];
					}
				}
			}];
		}
	}];
}

- (void)checkRead
{
	[self asyncInTaskQueue:^{
		if (self.buffer.length == 0)
		{
			return;
		}

		if (self.readPackets.count > 0)
		{
			TAsyncSocketReadPacket *readPacket = [self.readPackets objectAtIndex:0];
			if (readPacket.buffer && readPacket.buffer.length > self.buffer.length)
			{
				return;
			}

			if (readPacket.length && readPacket.length.unsignedIntegerValue > self.buffer.length)
			{
				return;
			}

			[self.readPackets removeObjectAtIndex:0];
			NSData *data = nil;
			if (readPacket.buffer && readPacket.offset)
			{
				NSUInteger len = readPacket.length.unsignedIntegerValue;
				if (readPacket.offset.unsignedIntegerValue + readPacket.length.unsignedIntegerValue > readPacket.buffer.length)
				{
					len = readPacket.buffer.length - readPacket.offset.unsignedIntegerValue;
				}
				[readPacket.buffer replaceBytesInRange:NSMakeRange(readPacket.offset.unsignedIntegerValue, len) withBytes:self.buffer.bytes length:readPacket.length.unsignedIntegerValue];
				data = [[NSData alloc] initWithBytesNoCopy:(void *)readPacket.buffer.bytes + readPacket.offset.unsignedIntegerValue length:readPacket.length.unsignedIntegerValue freeWhenDone:NO];
			}
			else
			{
				readPacket.buffer = [[NSMutableData alloc] initWithBytes:self.buffer.bytes length:readPacket.length.unsignedIntegerValue];
				data = readPacket.buffer;
			}
			[self.buffer replaceBytesInRange:NSMakeRange(0, readPacket.length.unsignedIntegerValue) withBytes:NULL length:0];
			NSNumber *tag = readPacket.tag;
			[self asyncInDelegateQueue:^{
				NSObject<TAsyncSocketDelegate> *strongDelegate = self.delegate;
				if ([strongDelegate respondsToSelector:@selector(socket:didReadData:withTag:)])
				{
					[strongDelegate socket:self didReadData:data withTag:tag.longValue];
				}
			}];
		}
	}];
}

- (void)readDataToLength:(NSUInteger)length
					 tag:(long)tag
{
	if (length == 0)
		return;

	[self asyncInTaskQueue:^{
		TAsyncSocketReadPacket *readPacket = [[TAsyncSocketReadPacket alloc] init];
		readPacket.length = [[NSNumber alloc] initWithUnsignedInteger:length];
		readPacket.tag = [[NSNumber alloc] initWithLong:tag];
		[self.readPackets addObject:readPacket];
		[self checkRead];
	}];
}

- (void)readDataToLength:(NSUInteger)length
				  buffer:(NSMutableData *_Nullable)buffer
			bufferOffset:(NSUInteger)offset
					 tag:(long)tag
{
	if (length == 0)
		return;
	if (buffer && offset > buffer.length)
		return;

	[self asyncInTaskQueue:^{
		TAsyncSocketReadPacket *readPacket = [[TAsyncSocketReadPacket alloc] init];
		readPacket.tag = [[NSNumber alloc] initWithLong:tag];
		readPacket.length = [[NSNumber alloc] initWithUnsignedInteger:length];
		if (buffer)
		{
			readPacket.buffer = buffer;
			readPacket.offset = [[NSNumber alloc] initWithUnsignedInteger:offset];
		}
		[self.readPackets addObject:readPacket];
		[self checkRead];
	}];
}

- (void)disconnect
{
	[self syncInStreamThread:^{
		@autoreleasepool
		{
			[self disconnect:@"user disconnect" code:ERROR_CODE_SOCKET_DISCONNECT];
		}
	}];
}

- (void)disconnect:(NSString *)errorMsg code:(NSInteger)code
{
	if (self.readStream)
	{
		self.readStream.delegate = nil;
		[self.readStream close];
		[self.readStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		self.readStream = nil;
	}

	if (self.writeStream)
	{
		self.writeStream.delegate = nil;
		[self.writeStream close];
		[self.writeStream removeFromRunLoop:[NSRunLoop currentRunLoop] forMode:NSDefaultRunLoopMode];
		self.writeStream = nil;
	}

	self.readStreamOpened = NO;
	self.writeStreamOpened = NO;

	_isConnected = NO;
	_isConnecting = NO;

	[self.readPackets removeAllObjects];
	[self.writePackets removeAllObjects];

	self.writeCount = 0;

	[self.buffer replaceBytesInRange:NSMakeRange(0, self.buffer.length) withBytes:NULL length:0];

	[self asyncInDelegateQueue:^{
		if (self.delegate)
		{
			NSObject<TAsyncSocketDelegate> *strongDelegate = self.delegate;
			if ([strongDelegate respondsToSelector:@selector(socketDidDisconnect:withError:)])
			{
				[strongDelegate socketDidDisconnect:self withError:[self makeError:errorMsg withErroCode:code]];
			}
		}
	}];
}

- (NSData *)pollReadStream
{
	if (!self.readStream)
		return nil;

	static const uint32_t BUFFER_SIZE = 32;
	static uint8_t tmpBuffer[BUFFER_SIZE] = {0};
	static NSInteger byteRead = 0;
	byteRead = [self.readStream read:tmpBuffer maxLength:BUFFER_SIZE];
	if (byteRead > 0)
	{
		return [[NSData alloc] initWithBytes:tmpBuffer length:byteRead];
	}
	return nil;
}


#pragma mark - NSStreamDelegate
- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode
{
	switch (eventCode)
	{
		case NSStreamEventOpenCompleted:
		{
			if (aStream == self.writeStream)
			{
				self.writeStreamOpened = YES;
			}
			if (aStream == self.readStream)
			{
				self.readStreamOpened = YES;
			}
			if (self.readStreamOpened && self.writeStreamOpened)
			{
				_isConnected = YES;
				_isConnecting = NO;
				[self checkRead];
				[self checkWrite];
				[self asyncInDelegateQueue:^{
					if (self.delegate)
					{
						NSObject<TAsyncSocketDelegate> *strongDelegate = self.delegate;
						if ([strongDelegate respondsToSelector:@selector(socket:didConnectToHost:port:)])
						{
							[strongDelegate socket:self didConnectToHost:self.host port:self.port];
						}
					}
				}];
			}
		}
		break;
		case NSStreamEventHasBytesAvailable:
		{
			NSData *data = [self pollReadStream];
			[self asyncInTaskQueue:^{
				[self.buffer appendData:data];
				[self checkRead];
			}];
		}
		break;
		case NSStreamEventHasSpaceAvailable:
		{
			[self asyncInTaskQueue:^{
				++self.writeCount;
				[self checkWrite];
			}];
		}
		break;
		case NSStreamEventErrorOccurred:
		{
			[self disconnect:@"stream error" code:ERROR_CODE_SOCKET_STREAM];
		}
		break;
		case NSStreamEventEndEncountered:
		{
			[self disconnect:@"server close" code:ERROR_CODE_SOCKET_STREAM];
		}
		break;
		default:
		{
		}
		break;
	}
}


#pragma mark - HelperFunctions
- (void)asyncInTaskQueue:(void (^)(void))block
{
	if (!block)
		return;

	dispatch_async(self.taskQueue, ^{
		@autoreleasepool
		{
			block();
		}
	});
}

- (void)callBlock:(void (^)(void))block
{
	@autoreleasepool
	{
		if (block)
		{
			block();
		}
	}
}

- (void)asyncInStreamThread:(void (^)(void))block
{
	if (!block)
		return;

	[self performSelector:@selector(callBlock:) onThread:self.streamThread withObject:block waitUntilDone:NO];
}

- (void)syncInStreamThread:(void (^)(void))block
{
	if (!block)
		return;

	[self performSelector:@selector(callBlock:) onThread:self.streamThread withObject:block waitUntilDone:YES];
}

- (void)asyncInDelegateQueue:(void (^)(void))block
{
	if (!block)
		return;

	dispatch_async(self.delegateQueue, ^{
		@autoreleasepool
		{
			block();
		}
	});
}

- (NSError *)makeError:(NSString *)errorMsg withErroCode:(NSInteger)code
{
	NSDictionary *userInfo = errorMsg ? [[NSDictionary alloc] initWithObjectsAndKeys:errorMsg, NSLocalizedDescriptionKey, nil] : nil;
	return [[NSError alloc] initWithDomain:NSCocoaErrorDomain code:code userInfo:userInfo];
}

- (void)startStreamThread
{
	@autoreleasepool
	{
		[[NSThread currentThread] setName:TAsyncSocketName];

		[NSTimer scheduledTimerWithTimeInterval:[[NSDate distantFuture] timeIntervalSinceNow]
										 target:self
									   selector:@selector(ignore:)
									   userInfo:nil
										repeats:YES];

		NSThread *currentThread = [NSThread currentThread];
		NSRunLoop *currentRunLoop = [NSRunLoop currentRunLoop];

		BOOL isCancelled = [currentThread isCancelled];

		while (!isCancelled && [currentRunLoop runMode:NSDefaultRunLoopMode beforeDate:[NSDate distantFuture]])
		{
			isCancelled = [currentThread isCancelled];
		}
	}
}

- (void)ignore:(id)obj
{
}

@end
