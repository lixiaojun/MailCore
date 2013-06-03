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

#import "CTCoreAccount.h"
#import "CTCoreFolder.h"
#import "CTXlistResult.h"
#import "MailCoreTypes.h"
#import "MailCoreUtilities.h"

@interface CTCoreAccount ()
@end


@implementation CTCoreAccount
@synthesize lastError, pathDelimiter;

- (id)init {
    self = [super init];
    if (self) {
        connected = NO;
        myStorage = mailstorage_new(NULL);
        assert(myStorage != NULL);
    }
    return self;
}


- (void)dealloc {
    mailstorage_disconnect(myStorage);
    mailstorage_free(myStorage);
    self.lastError = nil;
    self.pathDelimiter = nil;
    [super dealloc];
}

- (NSError *)lastError {
    return lastError;
}

- (BOOL)isConnected {
    return connected;
}

- (BOOL)connectToServer:(NSString *)server port:(int)port
        connectionType:(int)conType authType:(int)authType
        login:(NSString *)login password:(NSString *)password {
    int err = 0;
    int imap_cached = 0;

    const char* auth_type_to_pass = NULL;
    if(authType == IMAP_AUTH_TYPE_SASL_CRAM_MD5) {
        auth_type_to_pass = "CRAM-MD5";
    }

    err = imap_mailstorage_init_sasl(myStorage,
                                     (char *)[server cStringUsingEncoding:NSUTF8StringEncoding],
                                     (uint16_t)port, NULL,
                                     conType,
                                     auth_type_to_pass,
                                     NULL,
                                     NULL, NULL,
                                     (char *)[login cStringUsingEncoding:NSUTF8StringEncoding], (char *)[login cStringUsingEncoding:NSUTF8StringEncoding],
                                     (char *)[password cStringUsingEncoding:NSUTF8StringEncoding], NULL,
                                     imap_cached, NULL);

    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }

    err = mailstorage_connect(myStorage);
    if (err == MAIL_ERROR_LOGIN) {
        self.lastError = MailCoreCreateError(err, @"Invalid username or password");
        return NO;
    } else if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
    }
    connected = YES;
    return YES;
}

- (NSSet *)capabilities {
    NSMutableSet *capabilitiesSet = [NSMutableSet set];
    
    int r;
    struct mailimap_capability_data *capabilities;
    
    r = mailimap_capability(self.session, &capabilities);
    if (r != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(r);
        return nil;
    }

    for(clistiter * cur = clist_begin(capabilities->cap_list); cur != NULL ; cur = cur->next) {
        struct mailimap_capability *capability;
        NSString *name;
        
        capability = clist_content(cur);
        name = nil;
        switch (capability->cap_type) {
            case MAILIMAP_CAPABILITY_AUTH_TYPE:
                name = [@"AUTH=" stringByAppendingString:[NSString stringWithUTF8String:capability->cap_data.cap_auth_type]];
                break;
            case MAILIMAP_CAPABILITY_NAME:
                name = [NSString stringWithUTF8String:capability->cap_data.cap_name];
                break;
        }
        if (name != nil) {
            [capabilitiesSet addObject:name];
        }
    }
    mailimap_capability_data_free(capabilities);
    
    return capabilitiesSet;
}

- (void)disconnect {
    if (connected) {
        connected = NO;
        mailstorage_disconnect(myStorage);
    }
}

- (CTCoreFolder *)folderWithPath:(NSString *)path {
    CTCoreFolder *folder = [[CTCoreFolder alloc] initWithPath:path inAccount:self];
    return [folder autorelease];
}


- (mailimap *)session {
    struct imap_cached_session_state_data * cached_data;
    struct imap_session_state_data * data;
    mailsession *session;

    session = myStorage->sto_session;
    if(session == nil) {
        return nil;
    }
    if (strcasecmp(session->sess_driver->sess_name, "imap-cached") == 0) {
        cached_data = session->sess_data;
        session = cached_data->imap_ancestor;
    }

    data = session->sess_data;
    return data->imap_session;
}


- (struct mailstorage *)storageStruct {
    return myStorage;
}


- (NSSet *)subscribedFolders {
    struct mailimap_mailbox_list * mailboxStruct;
    clist *subscribedList;
    clistiter *cur;

    NSString *mailboxNameObject;
    char *mailboxName;
    int err;

    NSMutableSet *subscribedFolders = [NSMutableSet set];

    //Fill the subscribed folder array
    err = mailimap_lsub([self session], "", "*", &subscribedList);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    for(cur = clist_begin(subscribedList); cur != NULL; cur = cur->next) {
        mailboxStruct = cur->data;
        struct mailimap_mbx_list_flags *flags = mailboxStruct->mb_flag;
        BOOL selectable = YES;
        if (flags) {
            selectable = !(flags->mbf_type==MAILIMAP_MBX_LIST_FLAGS_SFLAG && flags->mbf_sflag==MAILIMAP_MBX_LIST_SFLAG_NOSELECT);
        }
        
        if (selectable) {
            mailboxName = mailboxStruct->mb_name;
            // Per RFC 3501, mailbox names must use 7-bit enconding (UTF-7).
            mailboxNameObject = (NSString *)CFStringCreateWithCString(NULL, mailboxName, kCFStringEncodingUTF7_IMAP);

            if (mailboxStruct->mb_delimiter) {
                self.pathDelimiter = [NSString stringWithFormat:@"%c", mailboxStruct->mb_delimiter];
            } else {
                self.pathDelimiter = @"/";
            }
            [subscribedFolders addObject:mailboxNameObject];
            [mailboxNameObject release];
        }
    }
    mailimap_list_result_free(subscribedList);
    return subscribedFolders;
}

- (NSSet *)allFolders {
    struct mailimap_mailbox_list * mailboxStruct;
    clist *allList;
    clistiter *cur;

    NSString *mailboxNameObject;
    char *mailboxName;
    int err;

    NSMutableSet *allFolders = [NSMutableSet set];

    //Now, fill the all folders array
    //TODO Fix this so it doesn't use *
    err = mailimap_list([self session], "", "*", &allList);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    for(cur = clist_begin(allList); cur != NULL; cur = cur->next)
    {
        mailboxStruct = cur->data;
        struct mailimap_mbx_list_flags *flags = mailboxStruct->mb_flag;
        BOOL selectable = YES;
        if (flags) {
            selectable = !(flags->mbf_type==MAILIMAP_MBX_LIST_FLAGS_SFLAG && flags->mbf_sflag==MAILIMAP_MBX_LIST_SFLAG_NOSELECT);
        }
        if (selectable) {
            mailboxName = mailboxStruct->mb_name;
            // Per RFC 3501, mailbox names must use 7-bit enconding (UTF-7).
            mailboxNameObject = (NSString *)CFStringCreateWithCString(NULL, mailboxName, kCFStringEncodingUTF7_IMAP);
            
            if (mailboxStruct->mb_delimiter) {
                self.pathDelimiter = [NSString stringWithFormat:@"%c", mailboxStruct->mb_delimiter];
            } else {
                self.pathDelimiter = @"/";
            }
            [allFolders addObject:mailboxNameObject];
            [mailboxNameObject release];
        }
    }
    mailimap_list_result_free(allList);
    return allFolders;
}

- (NSSet *)allFoldersExtended {
    struct mailimap_mailbox_list * mailboxStruct;
    struct mailimap_mbx_list_oflag * oflagStruct;
    clist *allList;
    clistiter *cur, *flagIter;
    
    NSString *mailboxNameObject;
    char *mailboxName;
    NSString *flagNameObject;
    char *flagName;
    int err;
    
    NSMutableSet *allFolders = [NSMutableSet set];
    CTXlistResult *listResult;
    
    //Now, fill the all folders array
    //TODO Fix this so it doesn't use *
    err = mailimap_list([self session], "", "*", &allList);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    for(cur = clist_begin(allList); cur != NULL; cur = cur->next)
    {
        mailboxStruct = cur->data;
        struct mailimap_mbx_list_flags *flags = mailboxStruct->mb_flag;
        CTIMAPFolderFlag ctFlags;
        if (flags) {
            listResult = [[CTXlistResult alloc] init];
            ctFlags = (CTIMAPFolderFlag)imap_mailbox_flags_to_flags(flags);
            for (flagIter = clist_begin(flags->mbf_oflags); flagIter != NULL; flagIter = flagIter->next) {
                oflagStruct = flagIter->data;
                flagName = oflagStruct->of_flag_ext;
                flagNameObject = (NSString *)CFStringCreateWithCString(NULL, flagName, kCFStringEncodingUTF7_IMAP);
                [listResult addFlag:flagNameObject];
                [flagNameObject release];
            }
            
            mailboxName = mailboxStruct->mb_name;
            // Per RFC 3501, mailbox names must use 7-bit enconding (UTF-7).
            mailboxNameObject = (NSString *)CFStringCreateWithCString(NULL, mailboxName, kCFStringEncodingUTF7_IMAP);
            
            if (mailboxStruct->mb_delimiter) {
                self.pathDelimiter = [NSString stringWithFormat:@"%c", mailboxStruct->mb_delimiter];
            } else {
                self.pathDelimiter = @"/";
            }
            
            [listResult setName:mailboxNameObject];
            [listResult setDelimiter:self.pathDelimiter];
            [listResult setFolderFlags:ctFlags];
            [mailboxNameObject release];
            
            [allFolders addObject:listResult];
            [listResult release];
        }
    }
    mailimap_list_result_free(allList);
    return allFolders;
}

- (NSSet *)allFoldersExtendedWithXList {
    struct mailimap_mailbox_list * mailboxStruct;
    struct mailimap_mbx_list_oflag * oflagStruct;
    clist *allList;
    clistiter *cur, *flagIter;
    
    NSString *mailboxNameObject;
    char *mailboxName;
    NSString *flagNameObject;
    char *flagName;
    int err;
    
    NSMutableSet *allFolders = [NSMutableSet set];
    CTXlistResult *listResult;
    
    //Now, fill the all folders array
    //TODO Fix this so it doesn't use *
    err = mailimap_list([self session], "", "*", &allList);
    if (err != MAILIMAP_NO_ERROR) {
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return nil;
    }
    for(cur = clist_begin(allList); cur != NULL; cur = cur->next)
    {
        mailboxStruct = cur->data;
        struct mailimap_mbx_list_flags *flags = mailboxStruct->mb_flag;
        BOOL selectable = YES;
        if (flags) {
            selectable = !(flags->mbf_type==MAILIMAP_MBX_LIST_FLAGS_SFLAG && flags->mbf_sflag==MAILIMAP_MBX_LIST_SFLAG_NOSELECT);
        }
        if (selectable) {
            mailboxName = mailboxStruct->mb_name;
            // Per RFC 3501, mailbox names must use 7-bit enconding (UTF-7).
            mailboxNameObject = (NSString *)CFStringCreateWithCString(NULL, mailboxName, kCFStringEncodingUTF7_IMAP);
            
            if (mailboxStruct->mb_delimiter) {
                self.pathDelimiter = [NSString stringWithFormat:@"%c", mailboxStruct->mb_delimiter];
            } else {
                self.pathDelimiter = @"/";
            }
            
            listResult = [[CTXlistResult alloc] init];
            [listResult setName:mailboxNameObject];
            [mailboxNameObject release];
            
            if (flags) {
                for (flagIter = clist_begin(flags->mbf_oflags); flagIter != NULL; flagIter = flagIter->next) {
                    oflagStruct = flagIter->data;
                    flagName = oflagStruct->of_flag_ext;
                    if (flagName == NULL && oflagStruct->of_type == MAILIMAP_MBX_LIST_OFLAG_NOINFERIORS) {
                      flagName = "NoInferiors";
                    }
                    flagNameObject = (NSString *)CFStringCreateWithCString(NULL, flagName, kCFStringEncodingUTF7_IMAP);
                    [listResult addFlag:flagNameObject];
                    [flagNameObject release];
                }
            }
            
            [allFolders addObject:listResult];
            [listResult release];
        }
    }
    mailimap_list_result_free(allList);
    return allFolders;
}

- (BOOL)noop
{
    int err;
    err = mailimap_noop([self session]);
    if (err==MAILIMAP_NO_ERROR ||
        err==MAILIMAP_ERROR_STREAM) {
        return YES;
        
    }else{
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
        return NO;
        
    }
}

- (NSUInteger)statusInFolder:(NSString *)folder att:(int)att
{
    struct mailimap_mailbox_data_status *status_result;
    struct mailimap_status_att_list *att_list;
    struct mailimap_status_info *info;
    clistiter *cur;
    
    NSUInteger status = 0;
    int err;
    
    att_list = mailimap_status_att_list_new_empty();
    mailimap_status_att_list_add(att_list, att);
    
    char buffer[MAX_PATH_SIZE];
    MailCoreGetUTF7String(buffer, folder);
    
    err = mailimap_status([self session], buffer, att_list, &status_result);
    if (err==MAIL_NO_ERROR) {
        if (status_result->st_info_list!=NULL) {
            for(cur = clist_begin(status_result->st_info_list); cur != NULL; cur = cur->next) {
                info = cur->data;
                if (info->st_att == att) {
                    status = info->st_value;
                    break;
                }
            }
            mailimap_mailbox_data_status_free(status_result);
        }
        
    }else{
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
    }
    
    mailimap_status_att_list_free(att_list);
    
    return status;
    
}

- (NSDictionary *)statusInFolder:(NSString *)folder
{
    struct mailimap_mailbox_data_status *status_result;
    struct mailimap_status_att_list *att_list;
    struct mailimap_status_info *info;
    clistiter *cur;
    NSMutableDictionary *result;
    
    int err;
    
    att_list = mailimap_status_att_list_new_empty();
    mailimap_status_att_list_add(att_list, MAILIMAP_STATUS_ATT_MESSAGES);
    mailimap_status_att_list_add(att_list, MAILIMAP_STATUS_ATT_UIDNEXT);
    mailimap_status_att_list_add(att_list, MAILIMAP_STATUS_ATT_UIDVALIDITY);
    mailimap_status_att_list_add(att_list, MAILIMAP_STATUS_ATT_UNSEEN);
    mailimap_status_att_list_add(att_list, MAILIMAP_STATUS_ATT_RECENT);
    
    char buffer[MAX_PATH_SIZE];
    MailCoreGetUTF7String(buffer, folder);
    
    err = mailimap_status([self session], buffer, att_list, &status_result);
    if (err==MAIL_NO_ERROR) {
        if (status_result->st_info_list!=NULL) {
            result = [[NSMutableDictionary alloc] init];
            for(cur = clist_begin(status_result->st_info_list); cur != NULL; cur = cur->next) {
                info = cur->data;
                if (info!=NULL) {
                    NSNumber *valueNum = [NSNumber numberWithUnsignedInt:info->st_value];
                    switch (info->st_att) {
                        case MAILIMAP_STATUS_ATT_MESSAGES:
                            [result setValue:valueNum forKey:@"MESSAGES"];
                            break;
                        case MAILIMAP_STATUS_ATT_UIDVALIDITY:
                            [result setValue:valueNum forKey:@"UIDVALIDITY"];
                            break;
                        case MAILIMAP_STATUS_ATT_UIDNEXT:
                            [result setValue:valueNum forKey:@"UIDNEXT"];
                            break;
                        case MAILIMAP_STATUS_ATT_RECENT:
                            [result setValue:valueNum forKey:@"RECENT"];
                            break;
                        case MAILIMAP_STATUS_ATT_UNSEEN:
                            [result setValue:valueNum forKey:@"UNSEEN"];
                            break;
                            
                        default:
                            break;
                    }
                }
            }
            mailimap_mailbox_data_status_free(status_result);
        }
        
    }else{
        self.lastError = MailCoreCreateErrorFromIMAPCode(err);
    }
    
    mailimap_status_att_list_free(att_list);
    
    return result;
}

static struct {
    const char * name;
    int flag;
} mb_keyword_flag[] = {
    {"Inbox",     CTIMAPFolderFlagInbox},
    {"AllMail",   CTIMAPFolderFlagAllMail},
    {"SentMail",  CTIMAPFolderFlagSentMail},
    {"Spam",      CTIMAPFolderFlagSpam},
    {"Starred",   CTIMAPFolderFlagStarred},
    {"Trash",     CTIMAPFolderFlagTrash},
    {"Important", CTIMAPFolderFlagImportant},
    {"Drafts",    CTIMAPFolderFlagDrafts},
    {"Archive",   CTIMAPFolderFlagArchive},
    {"All",       CTIMAPFolderFlagAllMail},
    {"Junk",      CTIMAPFolderFlagSpam},
    {"Flagged",   CTIMAPFolderFlagStarred},
};

int imap_mailbox_flags_to_flags(struct mailimap_mbx_list_flags * imap_flags)
{
    int flags;
    clistiter * cur;
    
    flags = 0;
    if (imap_flags->mbf_type == MAILIMAP_MBX_LIST_FLAGS_SFLAG) {
        switch (imap_flags->mbf_sflag) {
            case MAILIMAP_MBX_LIST_SFLAG_MARKED:
                flags |= CTIMAPFolderFlagMarked;
                break;
            case MAILIMAP_MBX_LIST_SFLAG_NOSELECT:
                flags |= CTIMAPFolderFlagNoSelect;
                break;
            case MAILIMAP_MBX_LIST_SFLAG_UNMARKED:
                flags |= CTIMAPFolderFlagUnmarked;
                break;
        }
    }
    
    for(cur = clist_begin(imap_flags->mbf_oflags) ; cur != NULL ;
        cur = clist_next(cur)) {
        struct mailimap_mbx_list_oflag * oflag;
        
        oflag = (struct mailimap_mbx_list_oflag *) clist_content(cur);
        
        switch (oflag->of_type) {
            case MAILIMAP_MBX_LIST_OFLAG_NOINFERIORS:
                flags |= CTIMAPFolderFlagNoInferiors;
                break;
                
            case MAILIMAP_MBX_LIST_OFLAG_FLAG_EXT:
                for(unsigned int i = 0 ; i < sizeof(mb_keyword_flag) / sizeof(mb_keyword_flag[0]) ; i ++) {
                    if (strcasecmp(mb_keyword_flag[i].name, oflag->of_flag_ext) == 0) {
                        flags |= mb_keyword_flag[i].flag;
                    }
                }
                break;
        }
    }
    
    return flags;
}

@end
