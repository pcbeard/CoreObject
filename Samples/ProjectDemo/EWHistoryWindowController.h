#import <Cocoa/Cocoa.h>

#import "EWHistoryGraphView.h"
#import "EWUtilityWindowController.h"

@interface EWHistoryWindowController : EWUtilityWindowController
{
    IBOutlet EWHistoryGraphView *graphView_;
    COPersistentRoot *persistentRoot_;
}

+ (EWHistoryWindowController *) sharedController;

- (IBAction) sliderChanged: (id)sender;

@end
