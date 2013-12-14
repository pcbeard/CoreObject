/*
    Copyright (C) 2013 Eric Wasylishen

    Author:  Eric Wasylishen <ewasylishen@gmail.com>
    Date:  November 2013
    License:  MIT  (see COPYING)
 */

#import <Foundation/Foundation.h>

@interface COAttachmentID : NSObject
{
	NSData *_data;
}

- (instancetype) initWithData: (NSData *)aData;
- (NSData *) dataValue;

@end
