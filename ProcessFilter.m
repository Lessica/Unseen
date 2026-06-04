#import "ProcessFilter.h"

#import <libproc.h>
#import <string.h>

static const uid_t kTargetUid = 501;
static const char *kTargetPathNeedle = "/var/containers/Bundle/Application/";

static bool pid_has_target_uid(pid_t pid, uid_t expectedUid) {
    struct proc_bsdinfo info;
    int ret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info));
    if (ret != sizeof(info)) {
        return false;
    }
    return info.pbi_uid == expectedUid;
}

bool client_is_target_pid(pid_t pid, char *pathOut, size_t pathOutLen) {
    if (pid <= 0) {
        return false;
    }

    if (!pid_has_target_uid(pid, kTargetUid)) {
        return false;
    }

    char path[PROC_PIDPATHINFO_MAXSIZE] = {0};
    int pathLen = proc_pidpath(pid, path, sizeof(path));
    if (pathLen <= 0) {
        return false;
    }

    if (!strstr(path, kTargetPathNeedle)) {
        return false;
    }

    if (pathOut && pathOutLen > 0) {
        strlcpy(pathOut, path, pathOutLen);
    }
    return true;
}

bool client_is_target_audit_token(audit_token_t token, pid_t *pidOut, char *pathOut, size_t pathOutLen) {
    pid_t pid = (pid_t)token.val[5];
    uid_t euid = (uid_t)token.val[1];
    if (pidOut) {
        *pidOut = pid;
    }
    if (pid <= 0 || euid != kTargetUid) {
        return false;
    }
    return client_is_target_pid(pid, pathOut, pathOutLen);
}
