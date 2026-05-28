import base64
import sys

try:
    from flux.security import SecurityContext

    def sign_none_wrap(payload, userid):
        """
        sign-none implementation when flux-security is available
        """
        return (
            SecurityContext()
            .sign_wrap_as(userid, payload, mech_type="none")
            .decode("utf-8")
        )

except ImportError:

    # Fallback implementation of sign-none when flux.security is not available
    # This implements the sign-none mechanism as described in RFC 39
    def sign_none_wrap(payload, userid):
        """
        Create a sign-none wrapped signature for payload as userid.

        Format: <base64_header>.<base64_payload>.none

        Header is base64-encoded NUL-separated key-value pairs:
        version\0i1\0userid\0i{userid}\0mechanism\0snone\0
        """
        # Build header as NUL-separated key-value pairs
        header = f"version\0i1\0userid\0i{userid}\0mechanism\0snone\0"

        # Base64 encode header and payload
        header_b64 = base64.b64encode(header.encode("utf-8")).decode("utf-8")
        payload_b64 = base64.b64encode(payload).decode("utf-8")

        # Return formatted signature
        return f"{header_b64}.{payload_b64}.none"


if len(sys.argv) < 2:
    print("Usage: {0} USERID".format(sys.argv[0]))
    sys.exit(1)

userid = int(sys.argv[1])
payload = sys.stdin.read()
print(sign_none_wrap(payload.encode("utf-8"), userid))

# vi: ts=4 sw=4 expandtab
