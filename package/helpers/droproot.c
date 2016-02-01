/* Do an initgroups() / setgid() / setuid() and then exec another process
 *
 * This is only needed because Tclx can't do it all (specifically, it has
 * no interface for setgroups or initgroups)
 */

#include <sys/types.h>
#include <unistd.h>
#include <stdio.h>
#include <string.h>
#include <errno.h>
#include <pwd.h>
#include <grp.h>

int main(int argc, char **argv)
{
    struct passwd *entry;

    if (argc < 4) {
        fprintf(stderr, "syntax: %s username path argv0 args...\n", argv[0]);
        return 42;
    }

    if (geteuid() != 0) {
        /* this is not a security check; if we are not root then
         * setuid() et al is going to fail anyway
         */
        fprintf(stderr, "%s: caller is not root, refusing to continue\n", argv[0]);
        return 42;
    }

    /* ugh */
    errno = 0;
    entry = getpwnam(argv[1]);
    if (!entry) {
        if (errno) {
            fprintf(stderr, "%s: error looking up user %s: %s\n", argv[0], argv[1], strerror(errno));
        } else {
            fprintf(stderr, "%s: user %s does not exist\n", argv[0], argv[1]);
        }
        return 43;
    }

    if (entry->pw_uid == 0) {
        /* sanity check, as the caller is expecting us to actually drop some privileges */
        fprintf(stderr, "%s: user %s has UID 0, refusing to continue\n", argv[0], argv[1]);
        return 44;
    }

    /* important to setgid() before setuid() */

    if (initgroups(argv[1], entry->pw_gid) < 0) {
        fprintf(stderr, "%s: setgroups(%s,%d) failed: %s\n", argv[0], argv[1], entry->pw_gid, strerror(errno));
        return 45;
    }

    if (setgid(entry->pw_gid) < 0) {
        fprintf(stderr, "%s: setgid(%d) failed: %s\n", argv[0], entry->pw_gid, strerror(errno));
        return 45;
    }

    if (setuid(entry->pw_uid) < 0) {
        fprintf(stderr, "%s: setuid(%d) failed: %s\n", argv[0], entry->pw_uid, strerror(errno));
        return 46;
    }

    /* argv[argc] is always NULL, no need to terminate the list ourselves */
    if (execvp(argv[2], &argv[3]) < 0) {
        fprintf(stderr, "%s: exec of %s failed: %s\n", argv[0], argv[2], strerror(errno));
        return 47;
    }

    /* should never get here */
    fprintf(stderr, "%s: somehow execvp returned success, that's unpossible\n", argv[0]);
    return 48;
}
