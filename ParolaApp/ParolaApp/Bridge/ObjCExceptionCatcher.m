#import "ObjCExceptionCatcher.h"

NSException * _Nullable ParolaCatchingNSException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
