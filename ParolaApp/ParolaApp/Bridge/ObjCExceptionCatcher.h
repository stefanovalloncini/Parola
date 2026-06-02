#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` inside an Objective-C @try/@catch. Returns nil on success, or the caught
/// NSException. Swift cannot catch Objective-C exceptions; the accessibility KVC/AX calls in
/// the bridge tree walker can raise them on SwiftUI proxy objects, so this keeps a debug
/// bridge command from terminating the app.
NSException * _Nullable ParolaCatchingNSException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
