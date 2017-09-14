//
//  TAsyncSocket.h
//  TA-SDK
//
//  Created by tyzual on 11/09/2017.
//  Copyright © 2017 TyzuaL. All rights reserved.
//

#import <Foundation/Foundation.h>

#define VERSION 0.1

const extern NSInteger ERROR_CODE_SOCKET_ISCONNECTING;
const extern NSInteger ERROR_CODE_SOCKET_ISCONNECTED;
const extern NSInteger ERROR_CODE_SOCKET_CREATE;
const extern NSInteger ERROR_CODE_SOCKET_DISCONNECT;
const extern NSInteger ERROR_CODE_SOCKET_STREAM;

@protocol TAsyncSocketDelegate;

@interface TAsyncSocket : NSObject

@property (nonatomic, readonly, assign) BOOL isConnected;
@property (nonatomic, readonly, strong) NSString *_Nullable host;
@property (nonatomic, readonly, assign) uint16_t port;

- (instancetype _Nullable)initWithDelegate:(NSObject<TAsyncSocketDelegate> *_Nonnull)delegate;
- (instancetype _Nullable)initWithDelegate:(NSObject<TAsyncSocketDelegate> *_Nonnull)delegate delegateQueue:(dispatch_queue_t _Nullable)dq;

/**
 * Connects to the given host and port.
 * 
**/
- (BOOL)connectToHost:(NSString *_Nonnull)host onPort:(uint16_t)port error:(NSError *_Nullable __autoreleasing *_Nullable)errPtr;

/**
 * Writes data to the socket, and calls the delegate when finished.
 * 
 * If you pass in nil or zero-length data, this method does nothing and the delegate will not be called.
 * If the timeout value is negative, the write operation will not use a timeout.
 * 
 * Thread-Safety Note:
 * If the given data parameter is mutable (NSMutableData) then you MUST NOT alter the data while
 * the socket is writing it. In other words, it's not safe to alter the data until after the delegate method
 * socket:didWriteDataWithTag: is invoked signifying that this particular write operation has completed.
 * This is due to the fact that MTAGCDAsyncSocket does NOT copy the data. It simply retains it.
 * This is for performance reasons. Often times, if NSMutableData is passed, it is because
 * a request/response was built up in memory. Copying this data adds an unwanted/unneeded overhead.
 * If you need to write data from an immutable buffer, and you need to alter the buffer before the socket
 * completes writing the bytes (which is NOT immediately after this method returns, but rather at a later time
 * when the delegate method notifies you), then you should first copy the bytes, and pass the copy to this method.
**/
- (void)writeData:(NSData *_Nonnull)data
			  tag:(long)tag;

/**
 * Reads the given number of bytes.
 * 
 * If the length is 0, this method does nothing and the delegate is not called.
**/
- (void)readDataToLength:(NSUInteger)length tag:(long)tag;

/**
 * Reads the given number of bytes.
 * The bytes will be appended to the given byte buffer starting at the given offset.
 * The given buffer will automatically be increased in size if needed.
 * 
 * If the timeout value is negative, the read operation will not use a timeout.
 * If the buffer if nil, a buffer will automatically be created for you.
 * 
 * If the length is 0, this method does nothing and the delegate is not called.
 * If the bufferOffset is greater than the length of the given buffer,
 * the method will do nothing, and the delegate will not be called.
 * 
 * If you pass a buffer, you must not alter it in any way while AsyncSocket is using it.
 * After completion, the data returned in socket:didReadData:withTag: will be a subset of the given buffer.
 * That is, it will reference the bytes that were appended to the given buffer via
 * the method [NSData dataWithBytesNoCopy:length:freeWhenDone:NO].
**/
- (void)readDataToLength:(NSUInteger)length
				  buffer:(NSMutableData *_Nullable)buffer
			bufferOffset:(NSUInteger)offset
					 tag:(long)tag;

/**
 * Disconnects immediately (synchronously). Any pending reads or writes are dropped.
 * 
 * If the socket is not already disconnected, an invocation to the socketDidDisconnect:withError: delegate method
 * will be queued onto the delegateQueue asynchronously (behind any previously queued delegate methods).
 * In other words, the disconnected delegate method will be invoked sometime shortly after this method returns.
 * 
 * Please note the recommended way of releasing a MTAGCDAsyncSocket instance (e.g. in a dealloc method)
 * [asyncSocket setDelegate:nil];
 * [asyncSocket disconnect];
 * [asyncSocket release];
 * 
 * If you plan on disconnecting the socket, and then immediately asking it to connect again,
 * you'll likely want to do so like this:
 * [asyncSocket setDelegate:nil];
 * [asyncSocket disconnect];
 * [asyncSocket setDelegate:self];
 * [asyncSocket connect...];
**/
- (void)disconnect;
@end


#pragma mark - 回调
@protocol TAsyncSocketDelegate <NSObject>
- (void)socket:(TAsyncSocket *_Nonnull)sock didConnectToHost:(NSString *_Nonnull)host port:(uint16_t)port;

- (void)socket:(TAsyncSocket *_Nonnull)sock didWriteDataWithTag:(long)tag;

- (void)socket:(TAsyncSocket *_Nonnull)sock didReadData:(NSData *_Nonnull)data withTag:(long)tag;

- (void)socketDidDisconnect:(TAsyncSocket *_Nonnull)sock withError:(NSError *_Nullable)err;
@end
