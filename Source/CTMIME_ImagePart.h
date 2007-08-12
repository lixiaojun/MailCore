#import <Cocoa/Cocoa.h>
#import "CTMIME_SinglePart.h"

@interface CTMIME_ImagePart : CTMIME_SinglePart {
	NSImage *mImage;
}
- (id)content;
- (void)setImage:(NSImage *)image;
@end