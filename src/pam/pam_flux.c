/************************************************************\
 * Copyright 2022 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/

/*  PAM module allowing access to users with the current node
 *   allocated to a job when Flux is being used as the system
 *   instance resource manager.
 *
 *  This software was adapted from pam_slurm.c, (originally
 *   pam_rms.c) by Chris Dunlap <cdunlap@llnl.gov>
 *   and Jim Garlick <garlick.llnl.gov>
 */

#if HAVE_CONFIG_H
#  include "config.h"
#endif

#include <errno.h>
#include <fcntl.h>
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

#include <jansson.h>

#include <flux/core.h>
#include <flux/idset.h>

#ifdef HAVE_LIBSYSTEMD
#include <systemd/sd-bus.h>
#endif

#define PAM_SM_ACCOUNT
#include <security/pam_modules.h>
#include <security/pam_ext.h>

struct options {
    /*  If set, permit access to all users if the specified user has
     *  a job in RUN state on this host, this is rank 0 of that job,
     *  the job is an instance of Flux, and has access.allow-guest-user
     *  configured.
     *  (Allows guests to access multi-user instance jobs via ssh connector)
     */
    bool allow_guest_user;

    /*  If set, enable debug logging of PAM module
     */
    bool debug;

    /*  Prefix to use for session management scope names, default: flux-pam
     */
    const char *scope_prefix;

    /*  Directory for per-user lock files, default: /run/flux-pam
     */
    const char *lock_dir;
};

static char *uri_to_local (const char *uri)
{
    char *local_uri = NULL;
    char *p;

    /* Ensure this uri starts with `ssh://`
     */
    if (!uri || strncmp (uri, "ssh://", 6) != 0)
        return NULL;

    /* Skip to next '/' after ssh:// part
     */
    if (!(p = strchr (uri+6, '/')))
        return NULL;

    /* Construct local uri from remainder (path)
     */
    if (asprintf (&local_uri, "local:///%s", p) < 0)
        return NULL;
    return local_uri;
}

/* Return 1 if local instance at uri has access.allow-guest-user=true.
 * Return 0 otherwise.
 */
static int check_guest_allowed (pam_handle_t *pamh, const char *uri)
{
    int allowed = 0;
    flux_t *h = NULL;
    flux_future_t *f = NULL;
    char *local_uri = NULL;

    if (!uri)
        goto out;

    if (!(local_uri = uri_to_local (uri))) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "failed to transform %s into local uri",
                    uri);
        goto out;
    }
    if (!(h = flux_open (local_uri, 0))) {
        pam_syslog (pamh, LOG_ERR, "flux_open (%s): %m", local_uri);
        goto out;
    }
    if (!(f = flux_rpc (h, "config.get", NULL, FLUX_NODEID_ANY, 0))
        || flux_rpc_get_unpack (f,
                                "{s?{s?b}}",
                                "access",
                                 "allow-guest-user", &allowed) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to get config: %m");
        goto out;
    }
    if (!allowed)
        pam_syslog (pamh,
                    LOG_INFO,
                    "access.allow-guest-user not enabled in child");
out:
    flux_close (h);
    free (local_uri);
    return allowed;
}

typedef enum {
    FLUX_AUTH_DENIED    = 0,
    FLUX_AUTH_JOB_OWNER = 1,  /* uid has a direct active job on this node */
    FLUX_AUTH_GUEST     = 2,  /* uid is a guest of the instance owner's job */
} flux_auth_t;

/* Loop over jobs in json array 'jobs'.
 * - If any job owner is uid, permit as FLUX_AUTH_JOB_OWNER.
 * - If any job owner is allow_if_user and rank == rank 0 of the job,
 *   permit as FLUX_AUTH_GUEST if the job is an instance and
 *   access.allow-guest-user is true.
 */
static flux_auth_t check_jobs_array (pam_handle_t *pamh,
                                     json_t *jobs,
                                     unsigned int rank,
                                     uid_t uid,
                                     uid_t allow_if_user)
{
    size_t index;
    json_t *entry;

    json_array_foreach (jobs, index, entry) {
        const char *job_ranks;
        const char *uri = NULL;
        int job_uid;

        if (json_unpack (entry,
                         "{s:i s:s s?{s?{s?s}}}",
                         "userid", &job_uid,
                         "ranks", &job_ranks,
                         "annotations",
                          "user",
                           "uri", &uri) < 0) {
            pam_syslog (pamh,
                        LOG_ERR,
                        "failed to unpack userid, ranks for job");
            return FLUX_AUTH_DENIED;
        }
        if (job_uid == uid)
            return FLUX_AUTH_JOB_OWNER;
        else if (job_uid == allow_if_user) {
            struct idset *ranks;
            if ((ranks = idset_decode (job_ranks))) {
                int allowed = 0;
                /* Only if this rank is rank 0 of the job, check that
                 * access.allow-guest-user is enabled in the job instance:
                 */
                if (rank == idset_first (ranks))
                    allowed = check_guest_allowed (pamh, uri);
                idset_destroy (ranks);
                if (allowed)
                    return FLUX_AUTH_GUEST;
            }
        }
    }
    return FLUX_AUTH_DENIED;
}

/* Fetch an attribute and return its value as uid_t.
 */
static uid_t attr_get_uid (flux_t *h, const char *name)
{
    const char *s;
    char *endptr;
    long i;

    if (!(s = flux_attr_get (h, name)))
        return (uid_t) -1;
    errno = 0;
    i = strtol (s, &endptr, 10);
    if (errno != 0 || *endptr != '\0')
        return (uid_t) -1;
    return (uid_t) i;
}


/*  get jobs in RUN state on this node for user(s) of interest:
 */
static flux_auth_t flux_check_user (pam_handle_t *pamh,
                                    struct options *opts,
                                    uid_t uid)
{
    flux_auth_t authorized = FLUX_AUTH_DENIED;
    json_t *jobs = NULL;
    flux_t *h = NULL;
    unsigned int rank = -1;
    char rankstr[16];
    flux_future_t *f = NULL;

    /* allow_if_user MAY be set to the instance owner to allow guest
     * access for uid to this node in the case of a multi-user subinstance.
     * However, initialize it to uid so it can unconditionally be used below
     * in the RPC to job-list, which greatly simplifies code.
     */
    uid_t allow_if_user = uid;

    if (!(h = flux_open (NULL, 0))) {
        pam_syslog (pamh, LOG_ERR, "Unable to connect to Flux: %m");
        return FLUX_AUTH_DENIED;
    }
    if (flux_get_rank (h, &rank) < 0) {
        pam_syslog (pamh, LOG_ERR, "Failed to get current broker rank: %m");
        goto out;
    }
    if (opts->allow_guest_user) {
        uid_t owner = attr_get_uid (h, "security.owner");
        if (owner != (uid_t) -1)
            allow_if_user = owner;
        else
            pam_syslog (pamh,
                        LOG_ERR,
                        "Failed to get security.owner, can't allow guest access");
    }
    if (snprintf (rankstr,
                  sizeof (rankstr),
                  "%u",
                  rank) >= sizeof (rankstr)) {
        pam_syslog (pamh, LOG_ERR, "Failed to encode broker rank as string: %m");
        goto out;
    }

    /* Query jobs in RUN state on current rank using RFC 43 constraint object
     */
    f = flux_rpc_pack (h,
                       "job-list.list",
                       0,
                       0,
                       "{s:i s:[sss] s:{s:[{s:[ii]} {s:[s]} {s:[i]}]}}",
                       "max_entries", 0,
                       "attrs", "userid", "ranks", "annotations",
                       "constraint",
                        "and",
                         "userid", uid, allow_if_user,
                         "ranks", rankstr,
                         "states", FLUX_JOB_STATE_RUN);
    if (!f || flux_rpc_get_unpack (f, "{s:o}", "jobs", &jobs) < 0) {
        pam_syslog (pamh, LOG_ERR, "flux_job_list: %m");
        goto out;
    }

    authorized = check_jobs_array (pamh, jobs, rank, uid, allow_if_user);

out:
    flux_future_destroy (f);
    flux_close (h);
    return authorized;
}

/*
 *  Sends a message to the application informing the user that access
 *  was denied. Used by both pam_sm_acct_mgmt and pam_sm_open_session.
 */
static void send_denial_msg (pam_handle_t *pamh,
                             const char *user,
                             uid_t uid)
{
    int retval;
    const struct pam_conv *conv;
    int n;
    char str[PAM_MAX_MSG_SIZE];
    struct pam_message msg[1];
    const struct pam_message *pmsg[1];
    struct pam_response *prsp;

    /*  Get conversation function to talk with app.
     */
    retval = pam_get_item(pamh, PAM_CONV, (const void **) &conv);
    if (retval != PAM_SUCCESS) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "unable to get pam_conv: %s",
                    pam_strerror (pamh, retval));
        return;
    }

    /*  Construct msg to send to app.
     */
    n = snprintf(str,
                 sizeof(str),
                 "Access denied: user %s has no active jobs on this node",
                 user);
    if ((n < 0) || (n >= sizeof(str)))
        pam_syslog (pamh, LOG_ERR, "exceeded buffer for pam_conv message");

    msg[0].msg_style = PAM_ERROR_MSG;
    msg[0].msg = str;
    pmsg[0] = &msg[0];
    prsp = NULL;

    /*  Send msg to app and free the (meaningless) rsp.
     */
    retval = conv->conv(1, pmsg, &prsp, conv->appdata_ptr);
    if (retval != PAM_SUCCESS)
        pam_syslog (pamh,
                    LOG_ERR,
                    "unable to converse with app: %s",
                    pam_strerror (pamh, retval));
    if (prsp != NULL) {
        /* N.B. _pam_drop_reply() deprecated in recent versions
         * of Linux-PAM. Free reply without use of macros:
         */
        free (prsp[0].resp);
        free (prsp);
    }

    return;
}

/*  Get UID for PAM_USER. Returns 0 on success, -1 on failure.
 *  On failure, uid is set to (uid_t)-1.
 */
static int get_pam_user_uid (pam_handle_t *pamh, const char **puser, uid_t *uid)
{
    const char *user;
    struct passwd pwd;
    struct passwd *result;
    char buf[4096];
    int retval;

    *uid = (uid_t)-1;

    retval = pam_get_item (pamh, PAM_USER, (const void **) &user);
    if (retval != PAM_SUCCESS || !user || *user == '\0') {
        pam_syslog (pamh,
                    LOG_ERR,
                    "unable to get PAM_USER: %s",
                    pam_strerror (pamh, retval));
        return -1;
    }

    if (getpwnam_r (user, &pwd, buf, sizeof (buf), &result) != 0
        || !result) {
        pam_syslog (pamh, LOG_ERR, "user %s does not exist", user);
        return -1;
    }

    *puser = user;
    *uid = pwd.pw_uid;
    return 0;
}

static int parse_options (pam_handle_t *pamh,
                          struct options *opts,
                          int argc,
                          const char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (strcmp ("allow-guest-user", argv[i]) == 0) {
            opts->allow_guest_user = true;
        }
        else if (strcmp ("debug", argv[i]) == 0) {
            opts->debug = true;
        }
        else if (strncmp ("scope-prefix=", argv[i], 13) == 0) {
            opts->scope_prefix = argv[i] + 13;
        }
        else if (strncmp ("lock-dir=", argv[i], 9) == 0) {
            opts->lock_dir = argv[i] + 9;
        }
        else {
            pam_syslog (pamh,
                        LOG_ERR,
                        "unrecognized option: %s",
                        argv[i]);
            return -1;
        }
    }
    return 0;
}

#ifdef HAVE_LIBSYSTEMD
/*  Check if user@$UID.service is active and ready for session attachment.
 *  The service is started by the Flux prolog when a job begins and stopped
 *  by housekeeping when the last job ends, so inactive means no active job.
 *
 *  Returns  0 if service is active or activating (mirrors systemd's
 *             UNIT_IS_ACTIVE_OR_ACTIVATING macro).
 *  Returns -1 if service is not running or an error occurred with specific
 *             reason set in errmsg
 */
static int check_user_service_active (pam_handle_t *pamh,
                                      uid_t uid,
                                      bool debug,
                                      const char **errmsg)
{
    sd_bus *bus = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    sd_bus_message *reply = NULL;
    char unit_name[64];
    const char *unit_path_raw = NULL;
    char *unit_path = NULL;
    char *active_state = NULL;
    int rc = -1;

    *errmsg = "Unable to determine unit state";

    if (snprintf (unit_name,
                  sizeof (unit_name),
                  "user@%u.service",
                  uid) >= sizeof (unit_name)) {
        pam_syslog (pamh, LOG_ERR, "unit name overflow for uid %u", uid);
        return -1;
    }

    /*  Connect to the system bus.
     */
    if (sd_bus_open_system (&bus) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to connect to system bus: %m");
        return -1;
    }

    /*  Get the unit object path from systemd.  LoadUnit creates a stub entry
     *  for units that are not yet loaded, so it always returns a path.
     */
    if (sd_bus_call_method (bus,
                            "org.freedesktop.systemd1",
                            "/org/freedesktop/systemd1",
                            "org.freedesktop.systemd1.Manager",
                            "LoadUnit",
                            &error,
                            &reply,
                            "s",
                            unit_name) < 0) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "failed to load unit %s: %s",
                    unit_name,
                    error.message ? error.message : "unknown error");
        goto out;
    }

    if (sd_bus_message_read (reply, "o", &unit_path_raw) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to parse LoadUnit response: %m");
        goto out;
    }

    /*  unit_path_raw points into the reply message buffer and becomes a
     *  dangling pointer once the message is unreffed below.  Copy it first.
     */
    if (!(unit_path = strdup (unit_path_raw))) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "out of memory copying unit path for %s",
                    unit_name);
        goto out;
    }

    sd_bus_message_unref (reply);
    reply = NULL;
    sd_bus_error_free (&error);

    if (debug)
        pam_syslog (pamh, LOG_INFO,
                    "checking state of %s at D-Bus path %s",
                    unit_name,
                    unit_path);

    /*  Get ActiveState property.
     */
    if (sd_bus_get_property_string (bus,
                                    "org.freedesktop.systemd1",
                                    unit_path,
                                    "org.freedesktop.systemd1.Unit",
                                    "ActiveState",
                                    &error,
                                    &active_state) < 0) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "failed to get ActiveState for %s: %s",
                    unit_name,
                    error.message ? error.message : "unknown error");
        goto out;
    }
    sd_bus_error_free (&error);

    /* Mirror systemd's own UNIT_IS_ACTIVE_OR_ACTIVATING macro when
     * checking for an active or activating user@UID service:
     */
    if (strcmp (active_state, "active") == 0
        || strcmp (active_state, "activating") == 0
        || strcmp (active_state, "reloading") == 0
        || strcmp (active_state, "refreshing") == 0) {
        if (debug)
            pam_syslog (pamh,
                        LOG_INFO,
                        "%s is active or activating",
                        unit_name);
        rc = 0;
    }
    else {
        /*  inactive/dead is the normal case when no Flux job is running for
         *  this user (prolog starts the service, housekeeping stops it).
         *  Always log the observed state so the denial reason is auditable.
         */
        pam_syslog (pamh,
                    LOG_INFO,
                    "%s not active or activating: ActiveState=%s",
                    unit_name,
                    active_state);
        *errmsg = "unit not active or activating";
        rc = -1;
    }

out:
    free (unit_path);
    free (active_state);
    sd_bus_message_unref (reply);
    sd_bus_error_free (&error);
    sd_bus_unref (bus);
    return rc;
}

/*  Create a transient scope under user-$UID.slice for the login session.
 *  Scope name: flux-pam-<pid>.scope
 *  PID alone is sufficient for uniqueness system-wide.
 *  Returns 0 on success, -1 on error.
 */
static int create_session_scope (pam_handle_t *pamh,
                                 const char *scope_name,
                                 uid_t uid,
                                 pid_t pid,
                                 bool debug)
{
    sd_bus *bus = NULL;
    sd_bus_error error = SD_BUS_ERROR_NULL;
    sd_bus_message *m = NULL;
    sd_bus_message *reply = NULL;
    char slice_name[64];
    int rc = -1;

    if (snprintf (slice_name,
                  sizeof (slice_name),
                  "user-%u.slice",
                  uid) >= sizeof (slice_name)) {
        pam_syslog (pamh, LOG_ERR, "slice name overflow for uid=%u", uid);
        return -1;
    }

    /*  Connect to system bus.
     */
    if (sd_bus_open_system (&bus) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to connect to system bus: %m");
        return -1;
    }

    /*  Create StartTransientUnit method call.
     */
    if (sd_bus_message_new_method_call (bus,
                                        &m,
                                        "org.freedesktop.systemd1",
                                        "/org/freedesktop/systemd1",
                                        "org.freedesktop.systemd1.Manager",
                                        "StartTransientUnit") < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to create method call: %m");
        goto out;
    }

    /*  Append unit name and mode.
     */
    if (sd_bus_message_append (m, "ss", scope_name, "fail") < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to append unit name: %m");
        goto out;
    }

    /*  Start properties array.
     */
    if (sd_bus_message_open_container (m, 'a', "(sv)") < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to open properties container: %m");
        goto out;
    }

    /*  Add Slice property.
     */
    if (sd_bus_message_open_container (m, 'r', "sv") < 0
        || sd_bus_message_append (m, "s", "Slice") < 0
        || sd_bus_message_open_container (m, 'v', "s") < 0
        || sd_bus_message_append (m, "s", slice_name) < 0
        || sd_bus_message_close_container (m) < 0
        || sd_bus_message_close_container (m) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to append Slice property: %m");
        goto out;
    }

    /*  Add PIDs property.
     */
    if (sd_bus_message_open_container (m, 'r', "sv") < 0
        || sd_bus_message_append (m, "s", "PIDs") < 0
        || sd_bus_message_open_container (m, 'v', "au") < 0
        || sd_bus_message_open_container (m, 'a', "u") < 0
        || sd_bus_message_append (m, "u", (uint32_t)pid) < 0
        || sd_bus_message_close_container (m) < 0
        || sd_bus_message_close_container (m) < 0
        || sd_bus_message_close_container (m) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to append PIDs property: %m");
        goto out;
    }

    /*  Close properties array.
     */
    if (sd_bus_message_close_container (m) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to close properties container: %m");
        goto out;
    }

    /*  Append empty aux array.
     */
    if (sd_bus_message_append (m, "a(sa(sv))", 0) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to append aux array: %m");
        goto out;
    }

    /*  Call the method.
     */
    if (sd_bus_call (bus, m, 0, &error, &reply) < 0) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "StartTransientUnit(%s) failed: %s",
                    scope_name,
                    error.message ? error.message : "unknown error");
        goto out;
    }

    if (debug)
        pam_syslog (pamh,
                    LOG_INFO,
                    "created scope %s for userid %u",
                    scope_name,
                    uid);
    rc = 0;

out:
    sd_bus_message_unref (reply);
    sd_bus_message_unref (m);
    sd_bus_error_free (&error);
    sd_bus_unref (bus);
    return rc;
}
/*  Acquire exclusive per-user flock at /run/flux-pam/uid.<uid>.lock,
 *  serializing pam_sm_open_session with prolog/housekeeping scripts.
 *  Returns fd on success (caller must close to release), -1 on error.
 */
static int user_lock_acquire (pam_handle_t *pamh,
                              uid_t uid,
                              const char *lock_dir)
{
    char path[PATH_MAX];
    struct stat st;
    int fd;

    /* Verify lock directory is only writable by root */
    if (stat (lock_dir, &st) < 0) {
        pam_syslog (pamh, LOG_ERR, "stat lock dir %s: %m", lock_dir);
        return -1;
    }
    if (st.st_mode & (S_IWGRP | S_IWOTH)) {
        pam_syslog (pamh, LOG_ERR,
                    "lock dir %s must not be group/other writable (mode=%04o)",
                    lock_dir, st.st_mode & 0777);
        return -1;
    }

    if (snprintf (path, sizeof (path), "%s/uid.%u.lock", lock_dir, uid)
        >= sizeof (path)) {
        pam_syslog (pamh, LOG_ERR, "lock path overflow for uid=%u", uid);
        return -1;
    }
    if ((fd = open (path, O_CREAT | O_RDWR | O_NOFOLLOW, 0600)) < 0) {
        pam_syslog (pamh, LOG_ERR, "open lock uid=%u: %m", uid);
        return -1;
    }
    if (flock (fd, LOCK_EX) < 0) {
        pam_syslog (pamh, LOG_ERR, "flock uid=%u: %m", uid);
        close (fd);
        return -1;
    }
    return fd;
}

static void user_lock_release (int fd)
{
    if (fd >= 0)
        close (fd);
}

#endif /* HAVE_LIBSYSTEMD */

static int check_pam_manage_user_slice (pam_handle_t *pamh, int *resultp)
{
    flux_t *h = NULL;
    flux_future_t *f = NULL;

    *resultp = 0;

    /* Connect to Flux and fetch config
     */
    if (!(h = flux_open (NULL, 0))) {
        pam_syslog (pamh, LOG_ERR, "failed to connect to Flux: %m");
        return -1;
    }

    /*  Fetch broker config via RPC (not cached handle config).
     */
    if (!(f = flux_rpc (h, "config.get", NULL, FLUX_NODEID_ANY, 0))
        || flux_rpc_get_unpack (f,
                                "{s?:{s?:b}}",
                                "pam",
                                "manage-user-slice", resultp) < 0) {
        pam_syslog (pamh, LOG_ERR, "failed to fetch broker config: %m");
        flux_future_destroy (f);
        flux_close (h);
        return -1;
    }
    flux_future_destroy (f);
    flux_close (h);

    return 0;
}

PAM_EXTERN int
pam_sm_acct_mgmt (pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    const char *user;
    uid_t uid;
    int auth = PAM_PERM_DENIED;
    flux_auth_t result;
    struct options opts = { .allow_guest_user = false };

    if (get_pam_user_uid (pamh, &user, &uid) < 0)
        return PAM_USER_UNKNOWN;

    if (parse_options (pamh, &opts, argc, argv) < 0)
        return PAM_SYSTEM_ERR;

    result = flux_check_user (pamh, &opts, uid);
    if (result != FLUX_AUTH_DENIED) {
        /*  User has a local job or allow-guest-user is true. In either case
         *  return PAM_SUCCESS:
         */
        auth = PAM_SUCCESS;
        /*  If user is job owner, set pam_flux_authorized sentinel to allow
         *  other PAM callbacks to determine that pam_flux authorized
         *  access for this login attempt:
         */
        if (result == FLUX_AUTH_JOB_OWNER)
            pam_set_data (pamh, "pam_flux_authorized", (void *) 0x1, NULL);
    }

    if (auth != PAM_SUCCESS)
        send_denial_msg (pamh, user, uid);

    /*
     *  Generate an entry to the system log if access was denied
     */
    if (auth != PAM_SUCCESS) {
        pam_syslog (pamh,
                    LOG_INFO,
                    "access denied for user %s (uid=%u)",
                    user,
                    uid);
    }
    else if (opts.debug) {
        pam_syslog (pamh,
                    LOG_INFO,
                    "access granted for user %s (uid=%u)",
                    user,
                    uid);
    }
    return auth;
}

PAM_EXTERN int
pam_sm_open_session (pam_handle_t *pamh,
                     int flags,
                     int argc,
                     const char **argv)
{
    uid_t uid;
    const char *user;
    const void *pam_flux_authorized = NULL;
    int manage_slice;
    struct options opts = {
        .allow_guest_user = false,
        .debug = false,
        .scope_prefix = "flux-pam",
        .lock_dir = "/run/flux-pam"
    };

    if (parse_options (pamh, &opts, argc, argv) < 0)
        return PAM_SESSION_ERR;

    /*  Session management decision table:
     *
     *  pam_flux_authorized is a sentinel set by pam_sm_acct_mgmt when it
     *  grants access to a direct job owner. Its presence means "this user was
     *  authorized by pam_flux and has an active job."
     *
     *  This implementation assumes pam_systemd.so is absent. Such that
     *  fall-through in the session PAM stack via PAM_IGNORE will not
     *  invoke pam_systemd.so, which may interfere with flux-pam management
     *  of the user slice and user@.service.
     *
     *  Scenario 1: sentinel present + manage-slice enabled
     *    User authorized by pam_flux. Create scope, set env vars, etc.
     *
     *  Scenario 2: sentinel present + manage-slice disabled
     *    User authorized by pam_flux but feature disabled. Return success
     *    without creating scope.
     *
     *  Scenario 3: No sentinel
     *    User authorized by another module (e.g. pam_access.so for admins).
     *    Return PAM_IGNORE - session runs in sshd's cgroup.
     */
    pam_get_data (pamh, "pam_flux_authorized", &pam_flux_authorized);
    if (!pam_flux_authorized) {
        if (opts.debug)
            pam_syslog (pamh,
                        LOG_INFO,
                        "skipping session setup because !pam_flux_authorized");
        return PAM_IGNORE;
    }

    /*  Sentinel present: user authorized by pam_flux.
     *  Check if manage-user-slice feature is enabled.
     */
    if (get_pam_user_uid (pamh, &user, &uid) < 0)
        return PAM_SESSION_ERR;

    if (check_pam_manage_user_slice (pamh, &manage_slice) < 0)
        return PAM_SESSION_ERR;

    /*  Skip attach to user slice if pam.manage-user-slice not set
     */
    if (!manage_slice) {
        if (opts.debug)
            pam_syslog (pamh,
                        LOG_INFO,
                        "pam.manage-user-slice not set or false. Skipping.");
        return PAM_SUCCESS;
    }

#ifdef HAVE_LIBSYSTEMD
    char scope_name[128];
    pid_t pid = getpid ();
    const char *errmsg = "unknown";
    int lock_fd;

    /* Generate scope name
     */
    if (snprintf (scope_name,
                  sizeof (scope_name),
                  "%s-%d.scope",
                  opts.scope_prefix,
                  pid) >= sizeof (scope_name)) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "failed to generate scope name for prefix=%s",
                    opts.scope_prefix);
        return PAM_SESSION_ERR;
    }

    /*  Serialize service check + scope creation with prolog/housekeeping to
     *  prevent a TOCTOU where housekeeping stops the service between our
     *  check and StartTransientUnit.
     */
    if ((lock_fd = user_lock_acquire (pamh, uid, opts.lock_dir)) < 0)
        return PAM_SESSION_ERR;

    /*  Verify user@$UID.service is active before attempting attach.
     *  The service is started by the Flux prolog and stopped by housekeeping,
     *  so an inactive service means no active job — deny the login to enforce
     *  containment.
     */
    if (check_user_service_active (pamh, uid, opts.debug, &errmsg) < 0) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "user %s: user@%u.service: %s. Denying login",
                    user,
                    uid,
                    errmsg);
        send_denial_msg (pamh, user, uid);
        user_lock_release (lock_fd);
        return PAM_SESSION_ERR;
    }

    /*  Create transient scope for this session.
     */
    if (create_session_scope (pamh, scope_name, uid, pid, opts.debug) < 0) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "failed to attach uid=%u: scope creation failed",
                    uid);
        user_lock_release (lock_fd);
        return PAM_SESSION_ERR;
    }

    user_lock_release (lock_fd);

    /*  Set environment variables for the login shell.
     */
    char xdg_runtime_dir[64];
    char dbus_session_bus[128];

    if (snprintf (xdg_runtime_dir,
                  sizeof (xdg_runtime_dir),
                  "XDG_RUNTIME_DIR=/run/user/%u",
                  uid) >= sizeof (xdg_runtime_dir)) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "XDG_RUNTIME_DIR overflow for uid=%u",
                    uid);
        return PAM_SESSION_ERR;
    }

    if (snprintf (dbus_session_bus,
                  sizeof (dbus_session_bus),
                  "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/%u/bus",
                  uid) >= sizeof (dbus_session_bus)) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "DBUS_SESSION_BUS_ADDRESS overflow for uid=%u",
                    uid);
        return PAM_SESSION_ERR;
    }

    if (pam_putenv (pamh, xdg_runtime_dir) != PAM_SUCCESS
        || pam_putenv (pamh, dbus_session_bus) != PAM_SUCCESS) {
        pam_syslog (pamh,
                    LOG_ERR,
                    "failed to set environment for user %s (uid %u)",
                    user,
                    uid);
        return PAM_SESSION_ERR;
    }

    /*  Log successful attachment if debug is enabled.
     */
    if (opts.debug) {
        pam_syslog (pamh,
                    LOG_INFO,
                    "attached user %s uid=%u pid=%d scope=%s",
                    user,
                    uid,
                    pid,
                    scope_name);
    }
#else
    /*  Without libsystemd, we cannot verify slice state.
     *  Log a warning and skip attachment.
     */
    pam_syslog (pamh,
                LOG_WARNING,
                "libsystemd not available, cannot verify slice state");
    return PAM_SUCCESS;
#endif

    return PAM_SUCCESS;
}

PAM_EXTERN int
pam_sm_close_session (pam_handle_t *pamh,
                      int flags,
                      int argc,
                      const char **argv)
{
    /*  The transient scope created in pam_sm_open_session is tied to the
     *  session PID: systemd automatically stops and removes the scope when
     *  the last PID in it exits, so no explicit cleanup is required here.
     */
    return PAM_SUCCESS;
}

#ifdef PAM_STATIC
struct pam_module _pam_flux_modstruct = {
    "pam_flux",
    NULL,
    NULL,
    pam_sm_acct_mgmt,
    pam_sm_open_session,
    pam_sm_close_session,
    NULL,
};
#endif /* PAM_STATIC */

/*
 * vi: ts=4 sw=4 expandtab
 */
