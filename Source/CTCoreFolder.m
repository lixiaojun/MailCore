/*
 * MailCore
 *
 * Copyright (C) 2007 - Matt Ronge
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions
 * are met:
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 * 2. Redistributions in binary form must reproduce the above copyright
 *    notice, this list of conditions and the following disclaimer in the
 *    documentation and/or other materials provided with the distribution.
 * 3. Neither the name of the MailCore project nor the names of its
 *    contributors may be used to endorse or promote products derived
 *    from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHORS AND CONTRIBUTORS ``AS IS'' AND
 * ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHORS OR CONTRIBUTORS BE LIABLE
 * FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
 * DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
 * OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
 * HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
 * OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGE.
 */

#import <libetpan/libetpan.h>
#import <libetpan/imapdriver_tools.h>

#import "CTCoreFolder.h"
#import "CTCoreMessage.h"
#import "CTCoreAccount.h"
#import "MailCoreTypes.h"
#import "MailCoreUtilities.h"

#include <unistd.h>


//int imap_fetch_result_to_envelop_list(clist * fetch_result, struct mailmessage_list * env_list);
//
int uid_list_to_env_list(clist * fetch_result, struct mailmessage_list ** result,
                        mailsession * session, mailmessage_driver * driver);

@interface CTCoreFolder ()
@end


@implementation CTCoreFolder
@synthesize lastError, parentAccount=myAccount, idling;

- (id)initWithPath:(NSString *)path inAccount:(CTCoreAccount *)account; {
    struct mailstorage *storage = (struct mailstorage *)[account storageStruct];
    self = [super init];
    if (self)
    {
        myPath = [path retain];
        connected = NO;
        myAccount = [account retain];
        
        char buffer[MAX_PATH_SIZE];
        myFolder = mailfolder_new(storage, [self getUTF7String:buffer fromString:myPath], NULL);
        if (!myFolder) {
            return nil;
        }
    }
    return self;
}


- (void)dealloc {	
    if (connected)
        [self disconnect];

    mailfolder_free(myFolder);
    [myAccount release];
    [myPath release];
    self.lastError = nil;
    [super dealloc];
}


- (const char *)getUTF7String:(char *)buffer fromString:(NSString *)str {
    return MailCoreGetUTF7String(buffer, str);
}


- (BOOL)connect {
    int err = MAIL_NO_ERROR;
    err =  mailfolder_connect(myFolder);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    connected = YES;
    return YES;
}


- (void)disconnect {
    if (connected)
        mailfolder_disconnect(myFolder);
}

- (NSError *)lastError {
    return lastError;
}

- (NSString *)path {
    return myPath;
}

- (BOOL)setPath:(NSString *)path; {
    int err;

    BOOL success = [self connect];
    if (!success) {
        return NO;
    }

    success = [self unsubscribe];
    if (!success) {
        return NO;
    }
    
    char newPath[MAX_PATH_SIZE];
    [self getUTF7String:newPath fromString:path];
    
    char oldPath[MAX_PATH_SIZE];
    [self getUTF7String:oldPath fromString:myPath];
    
    err =  mailimap_rename([myAccount session], oldPath, newPath);
    
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    
    [path retain];
    [myPath release];
    myPath = path;
    
    success = [self subscribe];
    return success;
}

- (CTIdleResult)idleWithTimeout:(NSUInteger)timeout {
    NSAssert(!self.idling, @"Can't call idle when we are already idling!");
    self.lastError = nil;
    
    BOOL success = [self connect];
    if (!success) {
        return CTIdleError;
    }
    
    CTIdleResult result = CTIdleError;
    int r = 0;
    
    self.idling = YES;
    r = pipe(idlePipe);
    if (r == -1) {
        return CTIdleError;
    }
    
    self.imapSession->imap_selection_info->sel_exists = 0;
    r = mailimap_idle(self.imapSession);
    if (r != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        result = CTIdleError;
    }
    
    if (r == MAILIMAP_NO_ERROR && self.imapSession->imap_selection_info->sel_exists == 0) {
        int fd;
        int maxfd;
        fd_set readfds;
        struct timeval delay;
        
        fd = mailimap_idle_get_fd(self.imapSession);
        
        FD_ZERO(&readfds);
        FD_SET(fd, &readfds);
        FD_SET(idlePipe[0], &readfds);
        maxfd = fd;
        if (idlePipe[0] > maxfd) {
            maxfd = idlePipe[0];
        }
        delay.tv_sec = timeout;
        delay.tv_usec = 0;
        
        r = select(maxfd + 1, &readfds, NULL, NULL, &delay);
        if (r == 0) {
            result = CTIdleTimeout;
        } else if (r == -1) {
            // select error condition, just ignore this
        } else {
            if (FD_ISSET(fd, &readfds)) {
                // The server sent something down
                result = CTIdleNewData;
            } else if (FD_ISSET(idlePipe[0], &readfds)) {
                // the idle was explicitly cancelled
                char ch;
                read(idlePipe[0], &ch, 1);
                result = CTIdleCancelled;
            }
        }
    } else if (r == MAILIMAP_NO_ERROR) {
        result = CTIdleNewData;
    }
    
    r = mailimap_idle_done(self.imapSession);
    if (r != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        result = CTIdleError;
    }

    self.idling = NO;
    close(idlePipe[1]);
    close(idlePipe[0]);
    idlePipe[1] = -1;
    idlePipe[0] = -1;

    return result;
}

- (void)cancelIdle {
    if (self.idling) {
        int r;
        char c;
        
        c = 0;
        r = write(idlePipe[1], &c, 1);
    }
}

- (BOOL)create {
    int err;
    
    char path[MAX_PATH_SIZE];
    [self getUTF7String:path fromString:myPath];

    err =  mailimap_create([myAccount session], path);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    success = [self subscribe];
    return success;
}


- (BOOL)delete {
    int err;
    
    char path[MAX_PATH_SIZE];
    [self getUTF7String:path fromString:myPath];

    BOOL success = [self connect];
    if (!success) {
        return NO;
    }

    success = [self unsubscribe];
    if (!success) {
        return NO;
    }
    err =  mailimap_delete([myAccount session], path);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}


- (BOOL)subscribe {
    int err;
    
    char path[MAX_PATH_SIZE];
    [self getUTF7String:path fromString:myPath];

    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    err =  mailimap_subscribe([myAccount session], path);
    err =  mailimap_unsubscribe([myAccount session], path);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}


- (BOOL)unsubscribe {
    int err;
    
    char path[MAX_PATH_SIZE];
    [self getUTF7String:path fromString:myPath];

    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    err =  mailimap_unsubscribe([myAccount session], path);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (BOOL) appendMessage: (CTCoreMessage *) msg
{
    int err = MAILIMAP_NO_ERROR;
    NSString *msgStr = [msg render];
    if (![self connect])
        return NO;
    
    struct mail_flags *flags = mail_flags_new(MAIL_FLAG_SEEN, clist_new());
    
    err = mailsession_append_message_flags([self folderSession],
                                      [msgStr cStringUsingEncoding: NSUTF8StringEncoding],
                                      [msgStr lengthOfBytesUsingEncoding: NSUTF8StringEncoding],
                                      flags);
    
    mail_flags_free(flags);
    if (MAILIMAP_NO_ERROR != err)
        self.lastError = MailCoreCreateErrorFromIMAPCode (err);
    return MAILIMAP_NO_ERROR == err;
}

- (struct mailfolder *)folderStruct {
    return myFolder;
}

- (NSUInteger)uidValidity {
    BOOL success = [self connect];
    if (!success) {
        return 0;
    }
    mailimap *imapSession;
    imapSession = [self imapSession];
    if (imapSession->imap_selection_info != NULL) {
        return imapSession->imap_selection_info->sel_uidvalidity;
    }
    return 0;
}

- (NSUInteger)uidNext  {
    BOOL success = [self connect];
    if (!success) {
        return 0;
    }
    mailimap *imapSession;
    imapSession = [self imapSession];
    if (imapSession->imap_selection_info != NULL) {
        return imapSession->imap_selection_info->sel_uidnext;
    }
    return 0;
}

- (BOOL)check {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    int err = mailfolder_check(myFolder);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}


- (BOOL)sequenceNumberForUID:(NSUInteger)uid sequenceNumber:(NSUInteger *)sequenceNumber {
    int r;
    struct mailimap_fetch_att * fetch_att;
    struct mailimap_fetch_type * fetch_type;
    struct mailimap_set * set;
    clist * fetch_result;

    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    set = mailimap_set_new_single(uid);
    if (set == NULL) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(MAIL_ERROR_MEMORY);
        return NO;
    }

    fetch_type = mailimap_fetch_type_new_fetch_att_list_empty();
    fetch_att = mailimap_fetch_att_new_uid();
    r = mailimap_fetch_type_new_fetch_att_list_add(fetch_type, fetch_att);
    if (r != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        mailimap_fetch_att_free(fetch_att);
        return NO;
    }

    r = mailimap_uid_fetch([self imapSession], set, fetch_type, &fetch_result);
    if (r != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return NO;
    }

    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);

    if (!clist_isempty(fetch_result)) {
        struct mailimap_msg_att *msg_att = (struct mailimap_msg_att *)clist_nth_data(fetch_result, 0);
        *sequenceNumber = msg_att->att_number;
    } else {
        *sequenceNumber = 0;
    }
    mailimap_fetch_list_free(fetch_result);
    return YES;
}

// We always fetch UID and Flags
- (NSArray *)messagesForSet:(struct mailimap_set *)set fetchAttributes:(CTFetchAttributes)attrs uidFetch:(BOOL)uidFetch {
    BOOL success = [self connect];
    if (!success) {
        return nil;
    }

    NSMutableArray *messages = [NSMutableArray array];

    int r;
    struct mailimap_fetch_att * fetch_att;
    struct mailimap_fetch_type * fetch_type;
    struct mailmessage_list * env_list;

    clist * fetch_result;

    fetch_type = mailimap_fetch_type_new_fetch_att_list_empty();
    // Always fetch UID
    fetch_att = mailimap_fetch_att_new_uid();
    r = mailimap_fetch_type_new_fetch_att_list_add(fetch_type, fetch_att);
    if (r != MAILIMAP_NO_ERROR) {
        mailimap_fetch_att_free(fetch_att);
        mailimap_fetch_type_free(fetch_type);
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }

    // Always fetch flags
    fetch_att = mailimap_fetch_att_new_flags();
    r = mailimap_fetch_type_new_fetch_att_list_add(fetch_type, fetch_att);
    if (r != MAILIMAP_NO_ERROR) {
        mailimap_fetch_att_free(fetch_att);
        mailimap_fetch_type_free(fetch_type);
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }

    // We only fetch RFC822.Size if the envelope is being fetched
    if (attrs & CTFetchAttrEnvelope) {
        fetch_att = mailimap_fetch_att_new_rfc822_size();
        r = mailimap_fetch_type_new_fetch_att_list_add(fetch_type, fetch_att);
        if (r != MAILIMAP_NO_ERROR) {
            mailimap_fetch_att_free(fetch_att);
            mailimap_fetch_type_free(fetch_type);
            self.lastError = MailCoreCreateErrorFromIMAPCode(r);
            return nil;
        }
    }

    // We only fetch the body structure if requested
    if (attrs & CTFetchAttrBodyStructure) {
        fetch_att = mailimap_fetch_att_new_bodystructure();
        r = mailimap_fetch_type_new_fetch_att_list_add(fetch_type, fetch_att);
        if (r != MAILIMAP_NO_ERROR) {
            mailimap_fetch_att_free(fetch_att);
            mailimap_fetch_type_free(fetch_type);
            self.lastError = MailCoreCreateErrorFromIMAPCode(r);
            return nil;
        }
    }

    // We only fetch envelope if requested
    if (attrs & CTFetchAttrEnvelope) {
        r = imap_add_envelope_fetch_att(fetch_type);
        if (r != MAIL_NO_ERROR) {
            mailimap_fetch_type_free(fetch_type);
            self.lastError = MailCoreCreateErrorFromIMAPCode(r);
            return nil;
        }
    }
    
    if (attrs & CTFetchAttrXGmailLabels) {
        fetch_att = mailimap_fetch_att_new_xgmlabels();
        r = mailimap_fetch_type_new_fetch_att_list_add(fetch_type, fetch_att);
        if (r != MAILIMAP_NO_ERROR) {
            mailimap_fetch_att_free(fetch_att);
            mailimap_fetch_type_free(fetch_type);
            self.lastError = MailCoreCreateErrorFromIMAPCode(r);
            return nil;
        }
    }
    
    if (uidFetch) {
        r = mailimap_uid_fetch([self imapSession], set, fetch_type, &fetch_result);
    } else {
        r = mailimap_fetch([self imapSession], set, fetch_type, &fetch_result);
    }
    if (r != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }

    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);

    env_list = NULL;
    r = uid_list_to_env_list(fetch_result, &env_list, [self folderSession], imap_message_driver);
    if (r != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }
    r = imap_fetch_result_to_envelop_list(fetch_result, env_list);
    if (r != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }

    // Parsing of MIME bodies, xgmlabels
    int len = carray_count(env_list->msg_tab);

    clistiter *fetchResultIter = clist_begin(fetch_result);
    for(int i=0; i<len; i++) {
        struct mailimf_fields * fields = NULL;
        struct mailmime * new_body = NULL;
        struct mailmime_content * content_message = NULL;
        struct mailmime * body = NULL;

        struct mailmessage * msg = carray_get(env_list->msg_tab, i);
        struct mailimap_msg_att *msg_att = (struct mailimap_msg_att *)clist_content(fetchResultIter);
        if (msg_att == nil) {
            self.lastError = MailCoreCreateErrorFromIMAPCode(MAIL_ERROR_MEMORY);
            return nil;
        }

        uint32_t uid = 0;
        char * references = NULL;
        size_t ref_size = 0;
        struct mailimap_body * imap_body = NULL;
        struct mailimap_envelope * envelope = NULL;

        if (attrs & CTFetchAttrBodyStructure) {
            r = imap_get_msg_att_info(msg_att, &uid, &envelope, &references, &ref_size, NULL, &imap_body);
            if (r != MAIL_NO_ERROR) {
                mailimap_fetch_list_free(fetch_result);
                self.lastError = MailCoreCreateErrorFromIMAPCode(r);
                return nil;
            }

            if (imap_body != NULL) {
                r = imap_body_to_body(imap_body, &body);
                if (r != MAIL_NO_ERROR) {
                    mailimap_fetch_list_free(fetch_result);
                    self.lastError = MailCoreCreateErrorFromIMAPCode(r);
                    return nil;
                }
            }

            if (envelope != NULL) {
                r = imap_env_to_fields(envelope, references, ref_size, &fields);
                if (r != MAIL_NO_ERROR) {
                    mailmime_free(body);
                    mailimap_fetch_list_free(fetch_result);
                    self.lastError = MailCoreCreateErrorFromIMAPCode(r);
                    return nil;
                }
            }

            content_message = mailmime_get_content_message();
            if (content_message == NULL) {
                if (fields != NULL)
                    mailimf_fields_free(fields);
                mailmime_free(body);
                mailimap_fetch_list_free(fetch_result);
                self.lastError = MailCoreCreateErrorFromIMAPCode(MAIL_ERROR_MEMORY);
                return nil;
            }

            new_body = mailmime_new(MAILMIME_MESSAGE, NULL,
                                    0, NULL, content_message,
                                    NULL, NULL, NULL, NULL, fields, body);

            if (new_body == NULL) {
                mailmime_content_free(content_message);
                if (fields != NULL)
                    mailimf_fields_free(fields);
                mailmime_free(body);
                mailimap_fetch_list_free(fetch_result);
                self.lastError = MailCoreCreateErrorFromIMAPCode(MAIL_ERROR_MEMORY);
                return nil;
            }
        }
        
        clistiter * item_cur;
        NSMutableArray * labels;
        if (attrs & CTFetchAttrXGmailLabels) {
            for(item_cur = clist_begin(msg_att->att_list); item_cur != NULL; item_cur = clist_next(item_cur)) {
                struct mailimap_msg_att_item * att_item;
                
                att_item = clist_content(item_cur);
                if (att_item->att_type == MAILIMAP_MSG_ATT_ITEM_EXTENSION) {
                    struct mailimap_extension_data * ext_data;
                    
                    ext_data = att_item->att_data.att_extension_data;
                    if (ext_data->ext_extension == &mailimap_extension_xgmlabels) {
                        struct mailimap_msg_att_xgmlabels * cLabels;
                        clistiter * cur;
                        
                        labels = [[NSMutableArray alloc] init];
                        cLabels = (struct mailimap_msg_att_xgmlabels *) ext_data->ext_data;
                        for(cur = clist_begin(cLabels->att_labels) ; cur != NULL ; cur = clist_next(cur)) {
                            char * cLabel;
                            NSString * label;
                            
                            cLabel = (char *) clist_content(cur);
                            label = [NSString stringWithCString:cLabel encoding:NSUTF8StringEncoding];
                            [labels addObject:label];
                            [label release];
                        }
                    }
                }
            }
        }

        CTCoreMessage* msgObject = [[CTCoreMessage alloc] initWithMessageStruct:msg];
        msgObject.parentFolder = self;
        [msgObject setSequenceNumber:msg_att->att_number];
        if (fields != NULL) {
            [msgObject setFields:fields];
        }
        if (attrs & CTFetchAttrBodyStructure) {
            [msgObject setBodyStructure:new_body];
        }
        if (attrs & CTFetchAttrXGmailLabels) {
            [msgObject setXGmailLabels:labels];
        }
        [messages addObject:msgObject];
        [msgObject release];

        fetchResultIter = clist_next(fetchResultIter);
    }

    if (env_list != NULL) {
        //I am only freeing the message array because the messages themselves are in use
        carray_free(env_list->msg_tab);
        free(env_list);
    }
    mailimap_fetch_list_free(fetch_result);

    return messages;
}

- (NSArray *)messagesFromSequenceNumber:(NSUInteger)startNum to:(NSUInteger)endNum withFetchAttributes:(CTFetchAttributes)attrs {
    struct mailimap_set *set = mailimap_set_new_interval(startNum, endNum);
    NSArray *results = [self messagesForSet:set fetchAttributes:attrs uidFetch:NO];
    return results;
}

- (NSArray *)messagesFromUID:(NSUInteger)startUID to:(NSUInteger)endUID withFetchAttributes:(CTFetchAttributes)attrs {
    struct mailimap_set *set = mailimap_set_new_interval(startUID, endUID);
    NSArray *results = [self messagesForSet:set fetchAttributes:attrs uidFetch:YES];
    return results;
}

- (NSArray *)messagesWithSequenceNumbers:(NSIndexSet *)sequenceNumbers
                         fetchAttributes:(CTFetchAttributes)attrs {
  struct mailimap_set *set = mailimap_set_new_empty();
  [sequenceNumbers enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
    mailimap_set_add_interval(set, range.location, range.location + range.length - 1);
  }];
  
  return [self messagesForSet:set fetchAttributes:attrs uidFetch:NO];
  
}

- (NSArray *)messagesWithUIDs:(NSIndexSet *)uidNumbers
              fetchAttributes:(CTFetchAttributes)attrs {
  struct mailimap_set *set = mailimap_set_new_empty();
  [uidNumbers enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
    mailimap_set_add_interval(set, range.location, range.location + range.length - 1);
  }];
  
  return [self messagesForSet:set fetchAttributes:attrs uidFetch:YES];
}

- (CTCoreMessage *)messageWithUID:(NSUInteger)uid {
    int err;
    struct mailmessage *msgStruct;
    char uidString[100];

    sprintf(uidString, "%d-%d", (uint32_t)[self uidValidity], (uint32_t)uid);

    BOOL success = [self connect];
    if (!success) {
        return nil;
    }
    err = mailfolder_get_message_by_uid([self folderStruct], uidString, &msgStruct);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    err = mailmessage_fetch_envelope(msgStruct,&(msgStruct->msg_fields));
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    //TODO Fix me, i'm missing alot of things that aren't being downloaded,
    // I just hacked this in here for the mean time
    err = mailmessage_get_flags(msgStruct, &(msgStruct->msg_flags));
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    CTCoreMessage *msg = [[[CTCoreMessage alloc] initWithMessageStruct:msgStruct] autorelease];
    msg.parentFolder = self;
    return msg;
}

//Only fetch uid and SequenceNumber
- (NSArray *)messagesFromUID:(NSUInteger)startUID to:(NSUInteger)endUID
{
    struct mailimap_set *set = mailimap_set_new_interval(startUID, endUID);
    
    BOOL success = [self connect];
    if (!success) {
        return nil;
    }
    
    NSMutableArray *messages = [NSMutableArray array];
    
    int r;
    struct mailimap_fetch_att * fetch_att;
    struct mailimap_fetch_type * fetch_type;
    struct mailmessage_list * env_list;
    
    clist * fetch_result;
    
    fetch_type = mailimap_fetch_type_new_fetch_att_list_empty();
    //fetch UID
    fetch_att = mailimap_fetch_att_new_uid();
    r = mailimap_fetch_type_new_fetch_att_list_add(fetch_type, fetch_att);
    if (r != MAILIMAP_NO_ERROR) {
        mailimap_fetch_att_free(fetch_att);
        mailimap_fetch_type_free(fetch_type);
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }
    
    r = mailimap_uid_fetch([self imapSession], set, fetch_type, &fetch_result);
    if (r != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }
    
    mailimap_fetch_type_free(fetch_type);
    mailimap_set_free(set);
    
    env_list = NULL;
    r = uid_list_to_env_list(fetch_result, &env_list, [self folderSession], imap_message_driver);
    if (r != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }
    r = imap_fetch_result_to_envelop_list(fetch_result, env_list);
    if (r != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }
    
    int len = carray_count(env_list->msg_tab);
    
    clistiter *fetchResultIter = clist_begin(fetch_result);
    for(int i=0; i<len; i++) {
        struct mailimf_fields * fields = NULL;
        
        struct mailmessage * msg = carray_get(env_list->msg_tab, i);
        struct mailimap_msg_att *msg_att = (struct mailimap_msg_att *)clist_content(fetchResultIter);
        if (msg_att == nil) {
            self.lastError = MailCoreCreateErrorFromIMAPCode(MAIL_ERROR_MEMORY);
            return nil;
        }
        
        CTCoreMessage* msgObject = [[CTCoreMessage alloc] initWithMessageStruct:msg];
        msgObject.parentFolder = self;
        [msgObject setSequenceNumber:msg_att->att_number];
        if (fields != NULL) {
            [msgObject setFields:fields];
        }
        [messages addObject:msgObject];
        [msgObject release];
        
        fetchResultIter = clist_next(fetchResultIter);
    }
    
    if (env_list != NULL) {
        //I am only freeing the message array because the messages themselves are in use
        carray_free(env_list->msg_tab);
        free(env_list);
    }
    mailimap_fetch_list_free(fetch_result);
    
    return messages;
    
}

/*	Why are flagsForMessage: and setFlags:forMessage: in CTCoreFolder instead of CTCoreMessage?
    One word: dependencies. These methods rely on CTCoreFolder and CTCoreMessage to do their work,
    if they were included with CTCoreMessage, than a reference to the folder would have to be kept at
    all times. So if you wanted to do something as simple as create an basic message to send via
    SMTP, these flags methods wouldn't work because there wouldn't be a reference to a CTCoreFolder.
    By not including these methods, CTCoreMessage doesn't depend on CTCoreFolder anymore. CTCoreFolder
    already depends on CTCoreMessage so we aren't adding any dependencies here. */

- (BOOL)flagsForMessage:(CTCoreMessage *)msg flags:(NSUInteger *)flags {
    return [self flagsForMessage:msg flags:flags extensionFlags:NULL];
}


- (BOOL)setFlags:(NSUInteger)flags forMessage:(CTCoreMessage *)msg {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }

    int err;
    [msg messageStruct]->msg_flags->fl_flags=flags;
    err = mailmessage_check([msg messageStruct]);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    err = mailfolder_check(myFolder);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (BOOL)extensionFlagsForMessage:(CTCoreMessage *)msg flags:(NSArray **)flags {
    return [self flagsForMessage:msg flags:NULL extensionFlags:flags];
}

- (BOOL)setExtensionFlags:(NSArray *)flags forMessage:(CTCoreMessage *)msg {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    
    int err;
    clist *extensionFlags = MailCoreClistFromStringArray(flags);
    if ([msg messageStruct]->msg_flags->fl_extension) {
        clist_free([msg messageStruct]->msg_flags->fl_extension);
        [msg messageStruct]->msg_flags->fl_extension = NULL;
    }
    [msg messageStruct]->msg_flags->fl_extension = extensionFlags;
    err = mailmessage_check([msg messageStruct]);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    err = mailfolder_check(myFolder);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (BOOL)flagsForMessage:(CTCoreMessage *)msg flags:(NSUInteger *)flags extensionFlags:(NSArray **)extensionFlags {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    
    self.lastError = nil;
    int err;
    struct mail_flags *flagStruct;
    err = mailmessage_get_flags([msg messageStruct], &flagStruct);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    if (flags) {
        *flags = flagStruct->fl_flags;
    }
    if (extensionFlags) {
        NSArray *extionsionFlags = MailCoreStringArrayFromClist(flagStruct->fl_extension);
        *extensionFlags = extionsionFlags;
    }
    
    return YES;
}

- (BOOL)setFlags:(NSUInteger)flags extensionFlags:(NSArray *)extensionFlags forMessage:(CTCoreMessage *)msg {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    
    int err;
    [msg messageStruct]->msg_flags->fl_flags = flags;
    clist *extensions = MailCoreClistFromStringArray(extensionFlags);
    if ([msg messageStruct]->msg_flags->fl_extension) {
        clist_free([msg messageStruct]->msg_flags->fl_extension);
        [msg messageStruct]->msg_flags->fl_extension = NULL;
    }
    [msg messageStruct]->msg_flags->fl_extension = extensions;
    err = mailmessage_check([msg messageStruct]);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    err = mailfolder_check(myFolder);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (BOOL)storeFlags:(NSIndexSet *)uids requestKind:(IMAPStoreFlagsRequestKind)kind flags:(NSUInteger)flags
{
    struct mailimap_set *imap_set;
    struct mailimap_store_att_flags *store_att_flags;
    struct mailimap_flag_list *flag_list;
    int err;
    clist *setList;
    
    BOOL success = [self connect];
    if (!success)
        return success;
    
    success = NO;
    
    imap_set = mailimap_set_new_empty();
    [uids enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        mailimap_set_add_interval(imap_set, range.location, range.location + range.length - 1);
    }];
    if (clist_count(imap_set->set_list) == 0) {
        return NO;
    }
    
    setList = splitSet(imap_set, 10);
    
    flag_list = mailimap_flag_list_new_empty();
    if ((flags & MAIL_FLAG_SEEN) != 0) {
        struct mailimap_flag * f;
        
        f = mailimap_flag_new_seen();
        mailimap_flag_list_add(flag_list, f);
        
    }
    if ((flags & MAIL_FLAG_ANSWERED) != 0) {
        struct mailimap_flag * f;
        
        f = mailimap_flag_new_answered();
        mailimap_flag_list_add(flag_list, f);
    }
    if ((flags & MAIL_FLAG_FLAGGED) != 0) {
        struct mailimap_flag * f;
        
        f = mailimap_flag_new_flagged();
        mailimap_flag_list_add(flag_list, f);
    }
    if ((flags & MAIL_FLAG_DELETED) != 0) {
        struct mailimap_flag * f;
        
        f = mailimap_flag_new_deleted();
        mailimap_flag_list_add(flag_list, f);
    }
    if ((flags & MAIL_FLAG_FORWARDED) != 0) {
        struct mailimap_flag * f;
        
        f = mailimap_flag_new_flag_keyword("$Forwarded");
        mailimap_flag_list_add(flag_list, f);
    }
    
    store_att_flags = NULL;
    for(clistiter * iter = clist_begin(setList) ; iter != NULL ; iter = clist_next(iter)) {
        struct mailimap_set * current_set;
        
        current_set = (struct mailimap_set *) clist_content(iter);
        
        switch (kind) {
            case IMAPStoreFlagsRequestKindRemove:
                store_att_flags = mailimap_store_att_flags_new_remove_flags_silent(flag_list);
                break;
            case IMAPStoreFlagsRequestKindAdd:
                store_att_flags = mailimap_store_att_flags_new_add_flags_silent(flag_list);
                break;
            case IMAPStoreFlagsRequestKindSet:
                store_att_flags = mailimap_store_att_flags_new_set_flags_silent(flag_list);
                break;
        }
        err = mailimap_uid_store([self imapSession], current_set, store_att_flags);
        if (err != MAILIMAP_NO_ERROR) {
            self.lastError = MailCoreCreateErrorFromIMAPCode(err);
            success = NO;
            goto release;
        }
        else{
            self.lastError = nil;
            success = YES;
        }
    }
    
    release:
    for(clistiter * iter = clist_begin(setList) ; iter != NULL ; iter = clist_next(iter)) {
        struct mailimap_set * current_set;
        
        current_set = (struct mailimap_set *) clist_content(iter);
        mailimap_set_free(current_set);
    }
    clist_free(setList);
    mailimap_store_att_flags_free(store_att_flags);
    mailimap_set_free(imap_set);
    
    return success;
    
}

- (BOOL)storeLabels:(NSIndexSet *)uids requestKind:(IMAPStoreFlagsRequestKind)kind labels:(NSArray *)labels
{
    struct mailimap_set * imap_set;
    struct mailimap_msg_att_xgmlabels * xgmlabels;
    int err;
    clist * setList;
    
    BOOL success = [self connect];
    if (!success)
        return success;
    
    success = NO;
    
    imap_set = mailimap_set_new_empty();
    [uids enumerateRangesUsingBlock:^(NSRange range, BOOL *stop) {
        mailimap_set_add_interval(imap_set, range.location, range.location + range.length - 1);
    }];
    if (clist_count(imap_set->set_list) == 0) {
        return NO;
    }
    
    setList = splitSet(imap_set, 10);
    
    xgmlabels = mailimap_msg_att_xgmlabels_new_empty();
    for(unsigned int i = 0 ; i < [labels count] ; i ++) {
        NSString * label = [labels objectAtIndex:i];
        mailimap_msg_att_xgmlabels_add(xgmlabels, strdup([label cStringUsingEncoding:NSUTF8StringEncoding]));
    }
    
    for(clistiter * iter = clist_begin(setList) ; iter != NULL ; iter = clist_next(iter)) {
        struct mailimap_set * current_set;
        int fl_sign;
        
        current_set = (struct mailimap_set *) clist_content(iter);
        
        switch (kind) {
            case IMAPStoreFlagsRequestKindRemove:
                fl_sign = -1;
                break;
            case IMAPStoreFlagsRequestKindAdd:
                fl_sign = 1;
                break;
            case IMAPStoreFlagsRequestKindSet:
                fl_sign = 0;
                break;
        }
        err = mailimap_uid_store_xgmlabels([self imapSession], current_set, fl_sign, 1, xgmlabels);
        if (err != MAILIMAP_NO_ERROR) {
            self.lastError = MailCoreCreateErrorFromIMAPCode(err);
            success = NO;
            goto release;
        }
        else{
            self.lastError = nil;
            success = YES;
        }
    }
    
    release:
    for(clistiter * iter = clist_begin(setList) ; iter != NULL ; iter = clist_next(iter)) {
        struct mailimap_set * current_set;
        
        current_set = (struct mailimap_set *) clist_content(iter);
        mailimap_set_free(current_set);
    }
    clist_free(setList);
    mailimap_msg_att_xgmlabels_free(xgmlabels);
    mailimap_set_free(imap_set);
    return success;
    
}

- (BOOL)expunge {
    int err;
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    err = mailfolder_expunge(myFolder);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (BOOL)copyMessageWithUID:(NSUInteger)uid toPath:(NSString *)path {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }

    char mbPath[MAX_PATH_SIZE];
    [self getUTF7String:mbPath fromString:path];
    int err = mailsession_copy_message([self folderSession], uid, mbPath);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (BOOL)moveMessageWithUID:(NSUInteger)uid toPath:(NSString *)path {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }

    char mbPath[MAX_PATH_SIZE];
    [self getUTF7String:mbPath fromString:path];
    int err = mailsession_move_message([self folderSession], uid, mbPath);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}

- (BOOL)unreadMessageCount:(NSUInteger *)unseenCount {
    unsigned int junk;
    int err;

    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    err =  mailfolder_status(myFolder, &junk, &junk, (uint32_t *)unseenCount);
    if (err != MAIL_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    return YES;
}


- (BOOL)totalMessageCount:(NSUInteger *)totalCount {
    BOOL success = [self connect];
    if (!success) {
        return NO;
    }
    *totalCount =  [self imapSession]->imap_selection_info->sel_exists;
    return YES;
}


- (mailsession *)folderSession; {
    return myFolder->fld_session;
}


- (mailimap *)imapSession; {
    struct imap_cached_session_state_data * cached_data;
    struct imap_session_state_data * data;
    mailsession *session;

    session = [self folderSession];
    if (strcasecmp(session->sess_driver->sess_name, "imap-cached") == 0) {
        cached_data = session->sess_data;
        session = cached_data->imap_ancestor;
    }

    data = session->sess_data;
    return data->imap_session;
}

/* From Libetpan source */
//TODO Can these things be made public in libetpan?
int uid_list_to_env_list(clist * fetch_result, struct mailmessage_list ** result,
                        mailsession * session, mailmessage_driver * driver) {
    clistiter * cur;
    struct mailmessage_list * env_list;
    int r;
    int res;
    carray * tab;
    unsigned int i;
    mailmessage * msg;

    tab = carray_new(128);
    if (tab == NULL) {
        res = MAIL_ERROR_MEMORY;
        goto err;
    }

    for(cur = clist_begin(fetch_result); cur != NULL; cur = clist_next(cur)) {
        struct mailimap_msg_att * msg_att;
        clistiter * item_cur;
        uint32_t uid;
        size_t size;

        msg_att = clist_content(cur);
        uid = 0;
        size = 0;
        for(item_cur = clist_begin(msg_att->att_list); item_cur != NULL; item_cur = clist_next(item_cur)) {
            struct mailimap_msg_att_item * item;

            item = clist_content(item_cur);
            switch (item->att_type) {
                case MAILIMAP_MSG_ATT_ITEM_STATIC:
                switch (item->att_data.att_static->att_type) {
                    case MAILIMAP_MSG_ATT_UID:
                        uid = item->att_data.att_static->att_data.att_uid;
                    break;

                    case MAILIMAP_MSG_ATT_RFC822_SIZE:
                        size = item->att_data.att_static->att_data.att_rfc822_size;
                    break;
                }
                break;
            }
        }

        msg = mailmessage_new();
        if (msg == NULL) {
            res = MAIL_ERROR_MEMORY;
            goto free_list;
        }

        r = mailmessage_init(msg, session, driver, uid, size);
        if (r != MAIL_NO_ERROR) {
            res = r;
            goto free_msg;
        }

        r = carray_add(tab, msg, NULL);
        if (r < 0) {
            res = MAIL_ERROR_MEMORY;
            goto free_msg;
        }
    }

    env_list = mailmessage_list_new(tab);
    if (env_list == NULL) {
        res = MAIL_ERROR_MEMORY;
        goto free_list;
    }

    * result = env_list;

    return MAIL_NO_ERROR;

    free_msg:
        mailmessage_free(msg);
    free_list:
        for(i = 0 ; i < carray_count(tab) ; i++)
        mailmessage_free(carray_get(tab, i));
    err:
        return res;
}

//export from mailcore2
static clist * splitSet(struct mailimap_set * set, unsigned int splitCount)
{
    struct mailimap_set * current_set;
    clist * result;
    unsigned int count;
    
    result = clist_new();
    
    current_set = NULL;
    count = 0;
    for(clistiter * iter = clist_begin(set->set_list) ; iter != NULL ; iter = clist_next(iter)) {
        struct mailimap_set_item * item;
        
        if (current_set == NULL) {
            current_set = mailimap_set_new_empty();
        }
        
        item = (struct mailimap_set_item *) clist_content(iter);
        mailimap_set_add_interval(current_set, item->set_first, item->set_last);
        count ++;
        
        if (count >= splitCount) {
            clist_append(result, current_set);
            current_set = NULL;
            count = 0;
        }
    }
    if (current_set != NULL) {
        clist_append(result, current_set);
    }
    
    return result;
}

@end
