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
#include <security/_pam_macros.h>

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

/*  Return 1 if uid has the local rank currently allocated to an active
 *   Flux job.
 */
static int flux_check_user (uid_t uid)
{
    int authorized = 0;
    size_t index;
    json_t *value;
    json_t *jobs = NULL;
    flux_t *h = NULL;
    unsigned int rank = -1;
    flux_job_state_t state = FLUX_JOB_STATE_NEW;
    flux_future_t *f = NULL;

    if (!(h = flux_open (NULL, 0))) {
        log_msg (LOG_ERR, "Unable to connect to Flux: %m");
        return 0;
    }
    if (flux_get_rank (h, &rank) < 0) {
        log_msg (LOG_ERR, "Failed to get current broker rank: %m");
        goto out;
    }

    f = flux_job_list (h,
                       0,
                       "[\"ranks\", \"state\"]",
                       uid,
                       FLUX_JOB_STATE_RUNNING);
    if (!f || flux_rpc_get_unpack (f, "{s:o}", "jobs", &jobs) < 0) {
        log_msg (LOG_ERR, "flux_job_list: %m");
        goto out;
    }

    json_array_foreach (jobs, index, value) {
        const char *ranks;
        struct idset *ids;

        if (json_unpack (value,
                         "{s:s s:i}",
                         "ranks", &ranks,
                         "state", &state) < 0
            || !(ids = idset_decode (ranks))) {
            log_msg (LOG_ERR, "Failed to unpack job response");
            goto out;
        }
        /*  Job must have an R which includes this rank _and_ the job
         *   must be in FLUX_JOB_STATE_RUN (not CLEANUP)
         */
        if (idset_test (ids, rank) && state == FLUX_JOB_STATE_RUN)
            authorized = 1;
        idset_destroy (ids);
        if (authorized)
            goto out;
    }
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
    if (prsp != NULL)
        _pam_drop_reply (prsp, 1);

    return;
}

PAM_EXTERN int
pam_sm_acct_mgmt (pam_handle_t *pamh, int flags, int argc, const char **argv)
{
    int retval;
    const char *user;
    struct passwd *pw;
    uid_t uid;
    int auth = PAM_PERM_DENIED;

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

    if (flux_check_user (uid))
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
