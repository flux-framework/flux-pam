/************************************************************\
 * Copyright 2022 Lawrence Livermore National Security, LLC
 * (c.f. AUTHORS, NOTICE.LLNS, COPYING)
 *
 * This file is part of the Flux resource manager framework.
 * For details, see https://github.com/flux-framework.
 *
 * SPDX-License-Identifier: LGPL-3.0
\************************************************************/
/*
 * Simple PAM test application
 *
 * gcc -g -Wall -o pamtest pamtest.c -lpam -lpam_misc
 *
 */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <libgen.h>
#include <sys/types.h>
#include <pwd.h>
#include <grp.h>
#include <errno.h>

#include <security/pam_appl.h>
#include <security/pam_misc.h>

#define GETOPT_ARGS "hvu:s:"
#define USAGE "\
Usage %s [-v] -u user -s service\n\
  -h          This help message.\n\
  -v          Verbose operation\n\
  -s service  Use service name \"service\"\n\
  -u user     Use user name \"user\"\n"

#define DEFAULT_CMD "id"

static int verbose = 0;

struct program_opts {
    char *user;
    struct passwd *pwd;
    char *service;
    char host[1024];
};

void log_msg (const char *fmt, va_list ap);
void log_fatal (const char *fmt, ...);
void log_err (const char *fmt, ...);
void log_verbose (const char *fmt, ...);
void usage (char *name);

void handle_args (struct program_opts *opts, int ac, char *av[]);
int  do_pam_setup (pam_handle_t **pamh, struct program_opts *opt);
int  do_pam_end (pam_handle_t *pamh, struct program_opts *opt);

/*
 * Use the PAM conversation function supplied by libpam_misc.so
 */
static struct pam_conv conv = {
        misc_conv,
        NULL
};

static char *program = NULL;

int main (int ac, char *av[])
{
    pam_handle_t *pamh = NULL;
    struct program_opts opts[1];

    memset (opts, 0, sizeof (*opts));

    handle_args (opts, ac, av);

    if (do_pam_setup (&pamh, opts) < 0)
        log_fatal ("PAM setup failed\n");

    do_pam_end (pamh, opts);

    exit (0);
}

void handle_args (struct program_opts *opt, int ac, char *av[])
{
    int c;

    program = strdup (basename (av[0]));

    while ((c = getopt (ac, av, GETOPT_ARGS)) > 0) {
        switch (c) {
        case 'v' : verbose++;
                   break;
        case 's' : opt->service = strdup (optarg);
                   break;
        case 'u' : opt->user = strdup (optarg);
                   break;
        case 'h' :
        default  : usage (av[0]);
        }
    }

    if ((opt->service == NULL) || (opt->user == NULL))
        log_fatal ("Must supply user and service.\n");

    if (gethostname (opt->host, sizeof(opt->host)) < 0)
        log_fatal ("Can't get hostname: %s\n", strerror (errno));

    if ((opt->pwd = getpwnam (opt->user)) == NULL)
        log_fatal ("User \"%s\" does not exist.\n", opt->user);

    return;
}

int do_pam_setup (pam_handle_t **ppamh, struct program_opts *opt)
{
    int rc;
    pam_handle_t *pamh;

    /*
     * Initialize PAM interface and read system configration file
     */
    log_verbose ("pam_start (\"%s\", \"%s\", misc_conv, &pamh)\n",
                 opt->service, opt->user);

    if ((rc = pam_start (opt->service, opt->user, &conv, ppamh)) != PAM_SUCCESS)
        log_fatal ("pam_start: %s\n", strerror (errno));

    pamh = *ppamh;

    /*
     *  Perform necessary pam_set_item() calls here:
     *   pam_set_item (pamh, PAM_RUSER, remote_user);
     */
    /*
     * We already know the PAM user name. So set it in the PAM env now.
     * In a more traditional authentication mechanism, the username
     *  is entered via a "login:" prompt or some other method, and
     *  the username can be obtained via a pam_get_item _after_
     *  pam_authenticate() is called.
     */
    log_verbose ("pam_set_item (pamh, PAM_USER, \"%s\")\n", opt->user);
    if ((rc = pam_set_item (pamh, PAM_USER, opt->user)) != PAM_SUCCESS)
        log_fatal ("pam_set_item (PAM_USER, %s) = %d\n", opt->user, rc);

    log_verbose ("pam_set_item (pamh, PAM_RUSER, \"%s\")\n", opt->user);
    if ((rc = pam_set_item (pamh, PAM_RUSER, opt->user)) != PAM_SUCCESS)
        log_fatal ("pam_set_item (PAM_RUSER, %s) = %d\n", opt->user, rc);

    log_verbose ("pam_set_item (pamh, PAM_HOST, \"%s\")\n", opt->host);
    if ((rc = pam_set_item (pamh, PAM_RHOST, opt->host)) != PAM_SUCCESS)
        log_fatal ("pam_set_item (PAM_HOST, %s) = %d\n", opt->host, rc);

    /*
     *  Call PAM auth stack
     *  (Is user really who they say they are?)
     */
    log_verbose ("pam_authenticate (pamh, 0)\n");
    if ((rc = pam_authenticate (pamh, 0)) != PAM_SUCCESS)
        log_fatal ("User %s not authorized. rc=%d\n", opt->user, rc);

    /*
     *  Call PAM account mgmt stack
     *  (Is user permitted access?)
     */
    log_verbose ("pam_acct_mgmt (pamh, 0)\n");
    if ((rc = pam_acct_mgmt (pamh, 0)) != PAM_SUCCESS)
        log_fatal ("User %s not authorized. rc=%d\n", opt->user, rc);
    log_verbose ("pam_acct_mgmt rc=%d\n", rc);

    return (0);
}

int do_pam_end (pam_handle_t *pamh, struct program_opts *opt)
{
    log_verbose ("pam_end (pamh, PAM_SUCCESS)\n");
    pam_end (pamh, PAM_SUCCESS);
    return (0);
}

void log_msg(const char *fmt, va_list ap)
{
    char buf[4096];
    int len = 0;

    len += snprintf(buf, 4095, "%s: ", program);
    vsnprintf(buf+len, 4095 - len, fmt, ap);

    fputs(buf, stderr);
    return;
}

void log_fatal(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    log_msg(fmt, ap);
    va_end(ap);
    exit(1);
}

void log_verbose (const char *fmt, ...)
{
    va_list ap;
    if (!verbose)
        return;
    va_start(ap, fmt);
    log_msg(fmt, ap);
    va_end(ap);
}

void log_err(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    log_msg(fmt, ap);
    va_end(ap);
    return;
}

void usage (char *name)
{
    fprintf (stderr, USAGE, basename (name));
    exit (0);
}


/*
 * vi: ts=4 sw=4 expandtab
 */
