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
#include <pwd.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <syslog.h>
#include <unistd.h>

#include <jansson.h>

#include <flux/core.h>
#include <flux/idset.h>

#define PAM_SM_ACCOUNT
#include <security/pam_modules.h>

struct options {
    /*  If set, permit access to all users if the specified user has
     *  a job in RUN state on this host, this is rank 0 of that job,
     *  the job is an instance of Flux, and has access.allow-guest-user
     *  configured.
     *  (Allows guests to access multi-user instance jobs via ssh connector)
     */
    bool allow_guest_user;
};

/*
 *  Write message described by the 'format' string to syslog.
 */
static void log_msg (int level, const char *format, ...)
{
    va_list args;

    openlog ("pam_flux", LOG_CONS | LOG_PID, LOG_AUTHPRIV);
    va_start (args, format);
    vsyslog (level, format, args);
    va_end (args);
    closelog ();
    return;
}

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
static int check_guest_allowed (const char *uri)
{
    int allowed = 0;
    flux_t *h = NULL;
    flux_future_t *f = NULL;
    char *local_uri = NULL;

    if (!uri)
        goto out;

    if (!(local_uri = uri_to_local (uri))) {
        log_msg (LOG_ERR, "failed to transform %s into local uri", uri);
        goto out;
    }
    if (!(h = flux_open (local_uri, 0))) {
        log_msg (LOG_ERR, "flux_open (%s): %m", local_uri);
        goto out;
    }
    if (!(f = flux_rpc (h, "config.get", NULL, FLUX_NODEID_ANY, 0))
        || flux_rpc_get_unpack (f,
                                "{s?{s?b}}",
                                "access",
                                 "allow-guest-user", &allowed) < 0) {
        log_msg (LOG_ERR, "failed to get config: %m");
        goto out;
    }
    if (!allowed)
        log_msg (LOG_INFO, "access.allow-guest-user not enabled in child");
out:
    flux_close (h);
    free (local_uri);
    return allowed;
}

/* Loop over jobs in json array 'jobs'.
 * - If any job owner is uid, permit.
 * - If any job owner is allow_if_user and rank == rank 0 of the job,
 *   permit if the job is an instance (has a uri) and acesss.allow-guest-user
 *   is true.
 */
static int check_jobs_array (json_t *jobs,
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
            log_msg (LOG_ERR, "failed to unpack userid, ranks for job");
            return 0;
        }
        if (job_uid == uid)
            return 1;
        else if (job_uid == allow_if_user) {
            struct idset *ranks;
            if ((ranks = idset_decode (job_ranks))) {
                int allowed = 0;
                /* Only if this rank is rank 0 of the job, check that
                 * access.allow-guest-user is enabled in the job instance:
                 */
                if (rank == idset_first (ranks))
                    allowed = check_guest_allowed (uri);
                idset_destroy (ranks);
                if (allowed)
                    return 1;
            }
        }
    }
    return 0;
}

/* Fetch an attribute and return its value as uid_t.
 */
static uid_t attr_get_uid (flux_t *h, const char *name)
{
    const char *s;
    char *endptr;
    long i;

    if (!(s = flux_attr_get (h, name))) {
        log_msg (LOG_ERR, "flux_attr_get (%s): %m", name);
        return (uid_t) -1;
    }
    errno = 0;
    i = strtol (s, &endptr, 10);
    if (errno != 0 || *endptr != '\0') {
        log_msg (LOG_ERR, "error converting %s to uid: %m", name);
        return (uid_t) -1;
    }
    return (uid_t) i;
}


/*  get jobs in RUN state on this node for user(s) of interest:
 */
static int flux_check_user (struct options *opts, uid_t uid)
{
    int authorized = 0;
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
        log_msg (LOG_ERR, "Unable to connect to Flux: %m");
        return 0;
    }
    if (flux_get_rank (h, &rank) < 0) {
        log_msg (LOG_ERR, "Failed to get current broker rank: %m");
        goto out;
    }
    if (opts->allow_guest_user) {
        uid_t owner = attr_get_uid (h, "security.owner");
        if (owner != (uid_t) -1)
            allow_if_user = owner;
        else
            log_msg (LOG_ERR,
                     "Failed to get security.owner, can't allow guest access");
    }
    if (snprintf (rankstr,
                  sizeof (rankstr),
                  "%u",
                  rank) >= sizeof (rankstr)) {
        log_msg (LOG_ERR, "Failed to encode broker rank as string: %m");
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
        log_msg (LOG_ERR, "flux_job_list: %m");
        goto out;
    }

    authorized = check_jobs_array (jobs, rank, uid, allow_if_user);

out:
    flux_future_destroy (f);
    flux_close (h);
    return authorized;
}

/*
 *  Sends a message to the application informing the user
 *  that access was denied due to Slurm.
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
        log_msg (LOG_ERR,
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
        log_msg (LOG_ERR, "exceeded buffer for pam_conv message");

    msg[0].msg_style = PAM_ERROR_MSG;
    msg[0].msg = str;
    pmsg[0] = &msg[0];
    prsp = NULL;

    /*  Send msg to app and free the (meaningless) rsp.
     */
    retval = conv->conv(1, pmsg, &prsp, conv->appdata_ptr);
    if (retval != PAM_SUCCESS)
        log_msg (LOG_ERR,
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

static int parse_options (struct options *opts, int argc, const char **argv)
{
    for (int i = 0; i < argc; i++) {
        if (strcmp ("allow-guest-user", argv[i]) == 0) {
            opts->allow_guest_user = true;
        }
        else {
            log_msg (LOG_ERR,
                    "unrecognized option: %s",
                    argv[i]);
            return -1;
        }
    }
    return 0;
}


PAM_EXTERN int
pam_sm_acct_mgmt (pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    int retval;
    const char *user;
    struct passwd *pw;
    uid_t uid;
    int auth = PAM_PERM_DENIED;
    struct options opts = { .allow_guest_user = false };

    retval = pam_get_item (pamh, PAM_USER, (const void **) &user);
    if ((retval != PAM_SUCCESS) || (user == NULL) || (*user == '\0')) {
        log_msg (LOG_ERR,
                 "unable to identify user: %s",
                 pam_strerror(pamh, retval));
        return PAM_USER_UNKNOWN;
    }
    if (!(pw = getpwnam (user))) {
        log_msg (LOG_ERR, "user %s does not exist", user);
        return PAM_USER_UNKNOWN;
    }
    uid = pw->pw_uid;

    if (parse_options (&opts, argc, argv) < 0)
        return PAM_SYSTEM_ERR;

    if (flux_check_user (&opts, uid))
        auth = PAM_SUCCESS;

    if (auth != PAM_SUCCESS)
        send_denial_msg (pamh, user, uid);

    /*
     *  Generate an entry to the system log if access was denied
     */
    if (auth != PAM_SUCCESS) {
        log_msg (LOG_INFO,
                 "access %s for user %s (uid=%u)",
                 (auth == PAM_SUCCESS) ? "granted" : "denied",
                 user, uid);
    }
    return auth;
}

#ifdef PAM_STATIC
struct pam_module _pam_flux_modstruct = {
    "pam_flux",
    NULL,
    NULL,
    pam_sm_acct_mgmt,
    NULL,
    NULL,
    NULL,
};
#endif /* PAM_STATIC */

/*
 * vi: ts=4 sw=4 expandtab
 */
