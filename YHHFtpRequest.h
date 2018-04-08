//
//  YHHFtpRequest.h
//  Ftp
//
//  Created by Yang on 2018/3/20.
//  Copyright © 2018年 com.locationTest. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface YHHFtpRequest : NSObject

@property (nonatomic, strong) NSString *ftpUser;
@property (nonatomic, strong) NSString *ftpPassword;
@property (nonatomic, strong) NSString *serversPath; // 服务器文件全路径，如:ftp://xx.xx.xx.xx:21/XXX/xx.jpg; (ftp://) 可以略
@property (nonatomic, strong) NSString *localPath;   // 本地文件全路径

- (void)download:(BOOL)resume
        progress:(void(^)(Float32 percent, NSUInteger finishSize))progress
        complete:(void(^)(id respond, NSError *error))complete;

- (void)upload:(BOOL)resume
      progress:(void(^)(Float32 percent, NSUInteger finishSize))progress
      complete:(void(^)(id respond, NSError *error))complete;

- (void)list:(void(^)(id respond, NSError *error))complete;
- (void)createDirctory:(NSString *)name complete:(void(^)(id respond, NSError *error))complete;
- (void)deleteDirctory:(NSString *)name complete:(void(^)(id respond, NSError *error))complete;
- (void)deleteFile:(NSString *)name complete:(void(^)(id respond, NSError *error))complete;
- (void)rename:(NSString *)newName complete:(void(^)(id respond, NSError *error))complete;

- (void)pasue;
- (void)quit;
@end
