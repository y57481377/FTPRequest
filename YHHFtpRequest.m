//
//  YHHFtpRequest.m
//  Ftp
//
//  Created by Yang on 2018/3/20.
//  Copyright © 2018年 com.locationTest. All rights reserved.
//

#import "YHHFtpRequest.h"
#ifdef DEBUG
#define NSLog(format, ...) printf("class: <%s:(%d) > method: %s \n%s\n", [[[NSString stringWithUTF8String:__FILE__] lastPathComponent] UTF8String], __LINE__, __PRETTY_FUNCTION__, [[NSString stringWithFormat:(format), ##__VA_ARGS__] UTF8String] )

#else

#define NSLog(format, ...)

#endif

typedef NS_ENUM(NSInteger, SendMessage) {
    SendConnect,            // 创建数据socket并连接到指定服务器
    SendNone,
    SendUser,               // 发送用户名
    SendPASS,               // 发送密码
    SendCWD,                // 指定工作目录
    SendPWD,                // 当前工作目录
    SendCDUP,               // 返回上级目录
    SendType,               // 传输的数据类型
    SendSize,               // 获取文件大小
    
    SendPASV,               // 被动模式
    SendPORT,               // 主动模式
    
    /**    文件操作   */
    SendMKD,                // 创建目录
    SendRMD,                // 删除目录(FileZilla需要客户端遍历删除目录里面的内容)
    SendDELE,               // 文件删除
    SendRNFR,               // 旧路径重命名     (RNFR + old path)指定要命名的文件路径
    SendRNTO,               // 新路径完成命名   (RNTO + new path)发送新的命名文件路径
    SendMLSD,               // 获得目录下的文件信息
    SendREST,               // 设置偏移量(断点续传)
    SendRETR,               // 下载
    SendSTOR,               // 上传
    SendAPPE,               // 续传
    
    SendABOR,               // 中断数据连接
    SendQUIT                // 退出Ftp服务器。
};

typedef NS_ENUM(NSInteger, OperateType) {
    OperateCreateD,
    OperateDeleteD,
    OperateDelete,
    OperateRename,
    OperateList,
    OperateDownload,
    OperateDownloadResume,
    OperateUpload,
    OperateUploadResume
};

// 数据端口每次读取数据的最大字节数。 数值与progress调用频率相关，数值太小CPU占用率较高
#define BYTES 20000

#define OPERATIONS                  @[OPERATION_CREATE_D, OPERATION_DELETE_D, OPERATION_DELETE, OPERATION_RENAME, OPERATION_LIST, OPERATION_DOWNLOAD, OPERATION_DOWNLOAD_RESUME, OPERATION_UPLOAD, OPERATION_UPLOAD_RESUME]

#define OPERATION_LOGIN             @[@(SendUser), @(SendPASS)]
#define OPERATION_CREATE_D          @[@(SendCWD),  @(SendMKD)]      //创建目录
#define OPERATION_DELETE_D          @[@(SendCWD),  @(SendRMD)]      //删除目录
#define OPERATION_DELETE            @[@(SendCWD),  @(SendDELE)]
#define OPERATION_RENAME            @[@(SendRNFR), @(SendRNTO)]
#define OPERATION_LIST              @[@(SendCWD),  @(SendType), @(SendPASV), @(SendMLSD)]
#define OPERATION_DOWNLOAD          @[@(SendCWD),  @(SendType), @(SendSize), @(SendPASV), @(SendRETR)]
#define OPERATION_DOWNLOAD_RESUME   @[@(SendCWD),  @(SendType), @(SendSize), @(SendPASV), @(SendREST), @(SendRETR)]
#define OPERATION_UPLOAD            @[@(SendCWD),  @(SendType), @(SendPASV), @(SendSTOR)]
#define OPERATION_UPLOAD_RESUME     @[@(SendCWD),  @(SendType), @(SendSize), @(SendPASV), @(SendAPPE)]

@interface YHHFtpRequest() <NSStreamDelegate>

@property (nonatomic, assign) CFSocketRef socket;                  // commandSocket
@property (nonatomic, assign) CFReadStreamRef read;                // command read
@property (nonatomic, assign) CFWriteStreamRef write;              // command write
@property (nonatomic, strong) NSThread *comThread;                 // 开一个线程接收command消息
@property (nonatomic, assign) CFRunLoopRef comLoop;

@property (nonatomic, strong) NSOutputStream *output;              // dataSocket output
@property (nonatomic, strong) NSInputStream *input;                // dataSocket input
//@property (nonatomic, strong) NSFileHandle *handle;                // dataSocket input
@property (nonatomic, strong) NSThread *dataThread;                // 开一个线程接收data
@property (nonatomic, assign) CFRunLoopRef dataLoop;

@property (nonatomic, strong) NSMutableData *listData;             // list Buffer
@property CFDataRef address;
@end

//static YHHFtpRequest *selfClass = nil;
static NSDictionary <NSNumber *, NSNumber *> *ftp_RightCodes = nil;
static NSTimeInterval ftp_timeout = 30.0;

@implementation YHHFtpRequest {
    BOOL _isLogin;
    BOOL _isType;           // 是否已经设置了传输 TYPE 类型
    BOOL _failure;          // 是否获得了正确的响应
    BOOL _pasue;
    OperateType _ctype;     // 当前任务操作
    SendMessage _csmsg;     // 当前发送的消息类型
    
    NSString *_diskPath;
    NSString *_fileName;
    NSString *_newName;
    NSString *_host;
    UInt32 _port;
    NSString *_dataHost;
    UInt32 _dataPort;
    
    UInt64 _fsize;
    UInt64 _tsize;
    
    uint8_t buffer[BYTES];  // dataSocket buffer
    dispatch_semaphore_t _semaphore;
    dispatch_queue_t _squeue;
    void(^_progressBlock)(Float32 percent, NSUInteger finishSize);
    void(^_completeBlock)(id respond, NSError *error);
}

+ (void)initialize {
    if (!ftp_RightCodes) {
        // SendConnect 登陆有时候会返回空字符串，220，0都可认为是正确返回
        // SendSize    续传时文件可能不存在返回550， 所以213，550都可能是正确响应
        ftp_RightCodes = @{@(SendConnect):@(220000), @(SendNone)  :@(200),       @(SendUser)   :@(331),
                           @(SendPASS)  :@(230),     @(SendCWD)    :@(250),      @(SendPWD)    :@(257),
                           @(SendCDUP)  :@(0),       @(SendType)   :@(200),      @(SendSize)   :@(213550),
                           
                           @(SendPASV)  :@(227),     @(SendPORT)   :@(200),
                           
                           @(SendMKD)   :@(257),    @(SendRMD)    :@(250),      @(SendDELE) :@(250),
                           @(SendRNFR)  :@(350),    @(SendRNTO)   :@(250),      @(SendMLSD) :@(150),
                           @(SendREST)  :@(350),    @(SendRETR)   :@(150),      @(SendSTOR) :@(150),
                           @(SendAPPE)  :@(150),
                           
                           @(SendQUIT)  :@(221451), @(SendABOR)   :@(225226)
                           };
    }
}

- (instancetype)init {
    if (self = [super init]) {
//        selfClass = self;
        _squeue = dispatch_queue_create(@"ftp.command.queue".UTF8String, NULL);
        _comThread = [[NSThread alloc] initWithBlock:^{
            _comThread.name = @"YHHFtpRequest.command";
            _comLoop = CFRunLoopGetCurrent();
            CFRunLoopRun();
        }];
        _dataThread = [[NSThread alloc] initWithBlock:^{
            _dataThread.name = @"YHHFtpRequest.data";
            _dataLoop = CFRunLoopGetCurrent();
            CFRunLoopRun();
        }];
    }
    return self;
}

// 需要发送的消息。
- (void)send:(SendMessage)smsg  {
    NSString *str = nil;
    switch (smsg) {
        case SendConnect:
            break;
            
        case SendNone:
            str = @"NOOP";
            break;
            
        case SendUser:
            str = [@"USER " stringByAppendingString:_ftpUser];
            break;
            
        case SendPASS:
            str = [@"PASS " stringByAppendingString:_ftpPassword];
            break;
            
        case SendCWD:
            str = [@"CWD " stringByAppendingString:_diskPath];
            break;
            
        case SendPWD:
            str = @"PWD";
            break;
            
        case SendCDUP:
            str = @"CDUP";
            break;
            
        case SendType:
            str = @"TYPE I";
            break;
            
        case SendSize:
            str = [@"SIZE " stringByAppendingString:_fileName];
            break;
            
        case SendPASV:
            str = @"PASV";
            break;
            
        case SendPORT:
            str = [@"PORT " stringByAppendingString:[NSString stringWithFormat:@"%@:%u", _dataHost, _dataPort]];
            break;
            
        case SendMKD:
            str = [@"MKD " stringByAppendingString:[_diskPath stringByAppendingPathComponent:_fileName]];
            break;
            
        case SendRMD:
            str = [@"RMD " stringByAppendingString:_fileName];
            break;
            
        case SendDELE:
            str = [@"DELE " stringByAppendingString:_fileName];
            break;
            
        case SendRNFR:
            str = [@"RNFR " stringByAppendingString:[_diskPath stringByAppendingPathComponent:_fileName]];
            break;
            
        case SendRNTO:
            str = [@"RNTO " stringByAppendingString:[_diskPath stringByAppendingPathComponent:_newName]];
            break;
            
        case SendMLSD:
            str = [@"MLSD " stringByAppendingString:_fileName];
//            str = @"MLSD";
            break;
            
        case SendRETR:
            str = [@"RETR " stringByAppendingString:_fileName];
            break;
            
        case SendREST:
            str = [@"REST " stringByAppendingFormat:@"%llu", _fsize];
            break;
            
        case SendSTOR:
            str = [@"STOR " stringByAppendingString:_fileName];
            break;
            
        case SendAPPE:
            str = [@"APPE " stringByAppendingString:_fileName];
            break;
        case SendABOR:
            str = @"ABOR";
            break;
        case SendQUIT:
            str = @"QUIT";
            break;
    }
    NSLog(@"%@", str);
    NSString *sendStr = [str stringByAppendingString:@"\r\n"];
    const char *data = [sendStr UTF8String];
    _csmsg = smsg;
    CFWriteStreamWrite(_write, (const UInt8 *)data, strlen(data));
}

#pragma mark --- Ftp operation.
- (BOOL)login {
    _isLogin = NO;
    NSArray *operations = OPERATION_LOGIN;
    if (!_semaphore) {
        _semaphore = dispatch_semaphore_create(0);
    }
    
    // 这里创建的CFSocket添加到了runloop,所以直接加在在主线程。
//    dispatch_async(dispatch_get_main_queue(), ^{
//        _csmsg = SendConnect;
//        [self setupCommandSocket];
//    });
    _csmsg = SendConnect;
    [self performSelector:@selector(setupCommandSocket) onThread:_comThread withObject:nil waitUntilDone:NO];
    if (!_comThread.isExecuting) {
        [_comThread start];
    }
    // 等待commandSocket连接到服务器，接收欢迎消息
    NSLog(@"等待");
    long res = dispatch_semaphore_wait(_semaphore, dispatch_time(DISPATCH_TIME_NOW, 200*NSEC_PER_SEC));
    // 如果由dispatch_semaphore_signal激发 res==0
    if (res != 0 || _failure) {
        _failure = NO;
        _csmsg = -1;
        NSLog(@"connect error");
        return NO;
    }
    
    // 登陆操作
    for (int i = 0; i < operations.count; i++) {
        SendMessage sendm = [operations[i] integerValue];
        [self send:sendm];
        
        NSLog(@"等待");
        long res = dispatch_semaphore_wait(_semaphore, dispatch_time(DISPATCH_TIME_NOW, ftp_timeout*NSEC_PER_SEC));
        // 如果由dispatch_semaphore_signal激发 res==0
        if (res != 0) {
            NSLog(@"error");
            _csmsg = -1;
            NSError *err = [NSError errorWithDomain:@"operation timeout" code:600 userInfo:nil];
            _completeBlock?_completeBlock(nil, err):nil;
            return _isLogin = NO;
        }
        if (_failure) {
            _csmsg = -1;
            _failure = NO;
            return _isLogin = NO;
        }
    }
    //    return _isLogin;
    return _isLogin = YES;
}

- (void)download:(BOOL)resume progress:(void (^)(Float32, NSUInteger))progress complete:(void (^)(id, NSError *))complete {
    _progressBlock = progress;
    _completeBlock = complete;
    if (resume) {
        _fsize = [[NSFileManager defaultManager] attributesOfItemAtPath:_localPath error:nil].fileSize;
        NSLog(@"offset：%llu,  localP: %@",_fsize, _localPath);
        [self operate:OperateDownloadResume];
    }else {
        [self operate:OperateDownload];
    }
}

- (void)upload:(BOOL)resume progress:(void (^)(Float32, NSUInteger))progress complete:(void (^)(id, NSError *))complete {
    _progressBlock = progress;
    _completeBlock = complete;
    _tsize = [[NSFileManager defaultManager] attributesOfItemAtPath:_localPath error:nil].fileSize;
    (resume ? [self operate:OperateUploadResume] : [self operate:OperateUpload]);
}

- (void)list:(void (^)(id, NSError *))complete {
    _completeBlock = complete;
    [self operate:OperateList];
}

- (void)createDirctory:(NSString *)name complete:(void (^)(id, NSError *))complete {
    _fileName = name;
    _completeBlock = complete;
    [self operate:OperateCreateD];
}

- (void)deleteDirctory:(NSString *)name complete:(void (^)(id, NSError *))complete {
    _fileName = name;
    _completeBlock = complete;
    [self operate:OperateDeleteD];
}

- (void)deleteFile:(NSString *)name complete:(void (^)(id, NSError *))complete {
    _fileName = name;
    _completeBlock = complete;
    [self operate:OperateDelete];
}

- (void)rename:(NSString *)newName complete:(void (^)(id, NSError *))complete {
    _newName = newName;
    _completeBlock = complete;
    [self operate:OperateRename];
}


- (void)operate:(OperateType)operate {
    _ctype = operate;
    dispatch_async(_squeue, ^{
        [self yhh_operate:operate];
    });
}

- (void)yhh_operate:(OperateType)operate {
    NSArray *operations = OPERATIONS[operate];
    
    if (!_isLogin)
        [self login];
    
    // 如果登录失败，不继续执行下面的命令
    if (!_isLogin)
        return;
    
    for (int i = 0; i < operations.count; i++) {
        SendMessage sendm = [operations[i] integerValue];
        // 设置过Type就跳过
        if (sendm==SendType && _isType==YES) {
            continue;
        }
        if (_pasue) {
            _pasue = NO;
            return;
        }
        // 发送操作
        [self send:sendm];
        // 等待响应
        NSLog(@"等待");
        if ((sendm==SendAPPE || sendm==SendSTOR || sendm==SendRETR)) {
            [self performSelector:@selector(setupDataSocket) onThread:_dataThread withObject:nil waitUntilDone:NO];
            if (!_dataThread.isExecuting) {
                [_dataThread start];
            }
        }
        long res = dispatch_semaphore_wait(_semaphore, dispatch_time(DISPATCH_TIME_NOW, ftp_timeout*NSEC_PER_SEC));
        
        if (res != 0) {
            // error
            _csmsg = -1;
            NSError *err = [NSError errorWithDomain:@"operation timeout" code:600 userInfo:nil];
            _completeBlock?_completeBlock(nil, err):nil;
            break;
        }
        if (_failure) {
            _csmsg = -1;
            _failure = NO;
            break;
        }
    }
}

- (void)pasue {
    _pasue = YES;
    [self endStream];
}

- (void)quit {
    [self endStream];
    [self send:SendQUIT];
//    dispatch_semaphore_wait(_semaphore, dispatch_time(DISPATCH_TIME_NOW, 20*NSEC_PER_SEC));
}

#pragma mark --- command socket/data stream.
- (void)setupCommandSocket {
    CFStreamClientContext context = {0, (__bridge void *)self, NULL, NULL, NULL};
    CFReadStreamRef readStream;
    CFWriteStreamRef writeStream;
    
    CFStreamCreatePairWithSocketToHost(kCFAllocatorDefault, (__bridge CFStringRef)_host, _port, &readStream, &writeStream);
    
    CFReadStreamSetClient(readStream, kCFStreamEventHasBytesAvailable|kCFStreamEventErrorOccurred|kCFStreamEventEndEncountered, ReadStreamClientCallBack, &context);
    
    CFReadStreamScheduleWithRunLoop(readStream, _comLoop, kCFRunLoopCommonModes);
    CFWriteStreamScheduleWithRunLoop(writeStream, _comLoop, kCFRunLoopCommonModes);
    
    _read = readStream;
    _write = writeStream;
    
    CFReadStreamOpen(readStream);
    CFWriteStreamOpen(writeStream);
    CFRunLoopRun();
}

- (void)setupDataSocket {

    NSLog(@"%@, %d", _dataHost, _dataPort);
    NSInputStream *input;
    NSOutputStream *output;
    
    if (_ctype >= OperateUpload) {  //上传
        [NSStream getStreamsToHostWithName:_dataHost port:_dataPort inputStream:nil outputStream:&output];
        input = [NSInputStream inputStreamWithFileAtPath:_localPath];
        [input setProperty:@(_fsize) forKey:NSStreamFileCurrentOffsetKey];
    }else {
        [NSStream getStreamsToHostWithName:_dataHost port:_dataPort inputStream:&input outputStream:nil];
        output = [NSOutputStream outputStreamToFileAtPath:_localPath append:(_ctype == OperateDownloadResume)];
    }
    
    input.delegate = self;
    output.delegate = self;
    
    CFReadStreamScheduleWithRunLoop((__bridge CFReadStreamRef)input, _dataLoop, kCFRunLoopDefaultMode);
    CFWriteStreamScheduleWithRunLoop((__bridge CFWriteStreamRef)output, _dataLoop, kCFRunLoopDefaultMode);
    
    _input = input;
    if (_ctype != OperateList)
        _output = output;
    
    
    [_output open];
    [_input open];
//    CFRunLoopRun();
}

// command
void ReadStreamClientCallBack(CFReadStreamRef stream, CFStreamEventType type, void *clientCallBackInfo) {
    YHHFtpRequest *selfClass = (__bridge YHHFtpRequest *)clientCallBackInfo;
    if (type == kCFStreamEventHasBytesAvailable) {
        UInt8 buffer[2048];
        CFIndex readlen = CFReadStreamRead(stream, buffer, 2048);
        NSString *recmsg = [[NSString alloc] initWithBytes:buffer length:readlen encoding:NSUTF8StringEncoding];
        NSLog(@"%@", recmsg);
        NSArray *recA = [recmsg componentsSeparatedByString:@"\r\n"];
        for (int i = 0; i < recA.count-1; i++) {
            NSString *recStr = recA[i];
            // 230- 是登录的时候服务器会多发出一段以230开头了乱码，这里把它忽略掉
            if ([recStr hasPrefix:@"230-"] || [recStr hasPrefix:@"226 "]) {
                continue;
            }
            [selfClass handleReceiveMessage:recStr];
        }

    }else if (type == kCFStreamEventErrorOccurred) {
        NSLog(@"commandSocket连接失败");
        [selfClass endCFStream];
        [selfClass handleReceiveMessage:@"601 connect error"];
    }else if (type == kCFStreamEventEndEncountered) {
        NSLog(@"commandSocket断开连接");
        [selfClass endCFStream];
    }
}

// data
- (void)stream:(NSStream *)aStream handleEvent:(NSStreamEvent)eventCode {
    
    if (eventCode == NSStreamEventHasBytesAvailable) {
        NSLog(@"读到了数据");
        NSOutputStream *wstream = _output;
        if (!wstream && _ctype != OperateList)
            return;
        
        long relen = [_input read:buffer maxLength:BYTES];
        if (_ctype == OperateList) {
            _listData ? nil : (_listData = [NSMutableData data]);
            [_listData appendBytes:buffer length:relen];
            return;
        }
        long wrlen = [wstream write:buffer maxLength:relen];
        // 出现wrlen != relen 时进入循环把当前读取到的数据写完。
        while (wrlen < relen) {
            uint8_t buff[relen-wrlen];
            memcpy(buff, buffer+wrlen, relen-wrlen);
            long cwr = [wstream write:buff maxLength:relen-wrlen];
            if (cwr <= 0)
                return;
            wrlen += cwr;
        }
        _fsize += wrlen;
//        NSLog(@"write: %ld, read: %ld", wrlen, relen);
        
    } else if (eventCode == NSStreamEventHasSpaceAvailable) {
        // 判断文件大小是否为零
        Float32 per = _tsize ? _fsize*1.0/_tsize : 1.0;
        _progressBlock ? _progressBlock(per, _fsize) : nil;
        
    } else if (eventCode == NSStreamEventOpenCompleted) {
        NSLog(@"数据已连接");
    } else if (eventCode == NSStreamEventErrorOccurred) {
        [self endStream];
        if (![_dataHost isEqualToString:_host]) {
            NSLog(@"尝试本地ip重连数据端口");
            _dataHost = _host;
            [self setupDataSocket];
            return;
        }
        NSLog(@"数据端口连接失败。发出错误");
    } else if (eventCode == NSStreamEventEndEncountered) {
        // 判断是被中断
        NSError *err = nil;
        if (_fsize<_tsize) {
            err = [NSError errorWithDomain:@"transfer interrupted" code:226 userInfo:nil];
        }
        NSArray *jsonArr = (_ctype == OperateList ? [self serializeData:_listData] : nil);
        NSLog(@"下载完毕／上传完毕/列表完毕");
        [self endStream];
        _completeBlock ? _completeBlock(jsonArr, err) : nil;
    }
}

- (void)endStream {
    if (_input || _output) {
        [_input close];
        [_output close];
        CFReadStreamUnscheduleFromRunLoop((__bridge CFReadStreamRef)_input, _dataLoop, kCFRunLoopDefaultMode);
        CFWriteStreamUnscheduleFromRunLoop((__bridge CFWriteStreamRef)_output, _dataLoop, kCFRunLoopDefaultMode);
        //    [_input removeFromRunLoop:_dataLoop forMode:NSDefaultRunLoopMode];
        //    [_output removeFromRunLoop:_dataLoop forMode:NSDefaultRunLoopMode];
        _input = nil;
        _output = nil;
        NSLog(@"流设置为nil");
        _pasue = NO;
    }
    [self endClean];
}

- (void)endCFStream {
    CFReadStreamClose(_read);
    CFWriteStreamClose(_write);
    CFReadStreamUnscheduleFromRunLoop(_read, _comLoop, kCFRunLoopCommonModes);
    CFWriteStreamUnscheduleFromRunLoop(_write, _comLoop, kCFRunLoopCommonModes);
    _isLogin = _isType = NO;
}

- (void)endClean {
    _listData = nil;
    _tsize = _fsize = 0;
    NSLog(@"clean");
//    _port = _dataPort = 0;
}

- (void)handleReceiveMessage:(NSString *)text {
    int code = 0;
    NSString *msg = nil;
    if (text.length >= 3) {
        code = [text substringToIndex:3].intValue;
        msg = [text substringFromIndex:4];
    }
    
    int rcode = ftp_RightCodes[@(_csmsg)].intValue;
    NSMutableSet * rset = [NSMutableSet set];
    
    // 拆解正确响应码
    for (int co = rcode; co > 0;) {
        int co1 = co % 1000;
        co = co / 1000;
        [rset addObject:@(co1)];
    }
    
    if (_csmsg < 0)// 每个send指令对应一个signal，发送完毕后置空。
        return;
    if ([rset containsObject:@(code)]) {
        NSLog(@"正确响应");
        if (_csmsg == SendSize) {
            if (_ctype == OperateUploadResume) {
                _fsize = msg.integerValue;
            }else {
                _tsize = msg.integerValue;
            }
        }else if (_csmsg == SendPASV) {
            NSString *str = [msg componentsSeparatedByString:@"("].lastObject;
            NSArray *portArr = [str componentsSeparatedByString:@","];
            int p1 = [portArr[4] intValue];
            int p2 = [portArr[5] intValue];
            UInt32 port = p1 *256 + p2;
            NSString *dataip = [NSString stringWithFormat:@"%@.%@.%@.%@", portArr[0], portArr[1], portArr[2], portArr[3]];
            _dataPort = port;
            _dataHost = dataip;
        }else if (_csmsg == SendMKD || _csmsg == SendRMD || _csmsg == SendDELE || _csmsg == SendRNTO) {
            (_completeBlock ? _completeBlock(@"success", nil) : nil);
        }else if (_csmsg == SendABOR) {
            return;
        }else if (_csmsg == SendQUIT) {
//            _csmsg = -1;
            return;
        }
    }else {
        NSLog(@"错误响应");
        !msg.length ? msg=@"" : nil;
        NSError *err = [NSError errorWithDomain:msg code:code userInfo:nil];
        _failure = YES;
        (_completeBlock ? _completeBlock(nil, err) : nil);
        [self endClean];
    }
    
    _csmsg = -1;
    NSLog(@"开始");
    dispatch_semaphore_signal(_semaphore);
    /*
     110	新文件指示器上的重启标记
     120	服务器准备就绪的时间（分钟数）
     125	打开数据连接，开始传输
     150	打开连接
     200	成功
     202	命令没有执行
     211	系统状态回复
     212	目录状态回复
     213	文件状态回复
     214	帮助信息回复
     215	系统类型回复
     220	服务就绪
     221	退出网络
     225	打开数据连接
     226	结束数据连接
     227	进入被动模式（IP 地址、ID 端口）
     230	登录因特网
     250	文件行为完成
     257	路径名建立
     331	要求密码
     332	要求帐号
     350	文件行为暂停
     421	服务关闭
     425	无法打开数据连接
     426	结束连接
     450	文件不可用
     451	遇到本地错误
     452	磁盘空间不足
     500	无效命令
     501	错误参数
     502	命令没有执行
     503	错误指令序列
     504	无效命令参数
     530	未登录网络
     532	存储文件需要帐号
     550	文件不可用
     551	不知道的页类型
     552	超过存储分配
     553	文件名不允许
     */
}

#pragma mark --- Ftp List respond to JSON Array
// 标准化服务器传回来的List信息
- (NSArray *)serializeData:(NSData *)data {
    
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!str)
        return nil;
    
    NSMutableArray *fileInfos = [NSMutableArray array];
    NSArray *fileAttrs = [str componentsSeparatedByString:@"\n"];
    for (int i = 0; i < fileAttrs.count - 1; i++) {
        NSString *attr = fileAttrs[i];                  // 单个文件的全部信息
        NSRange spacer = [attr rangeOfString:@" "];     // @" "分割文件名
        NSString *filename = [attr substringFromIndex:spacer.location + 1]; // 从空格处取文件名(+1不包括空格)
        // 文件名外的其他文件信息
        NSArray *subAttrs = [[attr substringToIndex:spacer.location] componentsSeparatedByString:@";"];
        
        NSMutableDictionary *dic = [NSMutableDictionary dictionary];
        [dic setValue:filename forKey:@"filename"];
        for (int j = 0; j < subAttrs.count - 1; j++) {
            //            NSLog(@"%@", subAttrs[j]);
            NSArray *kv = [subAttrs[j] componentsSeparatedByString:@"="];
            [dic setValue:kv.lastObject forKey:kv.firstObject];
        }
        [fileInfos addObject:dic];
    }
    //    NSLog(@"%@", fileInfos);
    _listData = nil;
    return fileInfos;
}

- (void)setServersPath:(NSString *)serversPath {
    _serversPath = serversPath.copy;
    
    NSString *subserversPath = serversPath;
    if ([serversPath hasPrefix:@"ftp://"]) {
        subserversPath = [serversPath substringFromIndex:@"ftp://".length];
    }
    NSArray *arr = [subserversPath componentsSeparatedByString:@"/"];         // firstObject: xx.xx.xx.xx:xxxx
    NSArray *subarr = [arr.firstObject componentsSeparatedByString:@":"];
    
    NSString *host = subarr.firstObject;
    UInt32 port = [subarr.lastObject intValue];
    
    if (_isLogin && (![host isEqualToString:_host] || port != _port)) {
        [self endCFStream];
    }
    _host = host;
    _port = port;
    _fileName = arr.lastObject;
    
    
    NSInteger lo = [arr.firstObject length];
    NSInteger le = subserversPath.length - lo - _fileName.length;
    _diskPath = [subserversPath substringWithRange:NSMakeRange(lo, le)];
    
    NSLog(@"host:%@, port:%d, fileName:%@, diskPath:%@, ftpName:%@, ftpPassword:%@", _host, _port, _fileName, _diskPath, self.ftpUser, self.ftpPassword);
}

@end
