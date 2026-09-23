###############################################################
# Copyright 2026 Lawrence Livermore National Security, LLC
# (c.f. AUTHORS, NOTICE.LLNS, COPYING)
#
# This file is part of the Flux resource manager framework.
# For details, see https://github.com/flux-framework.
#
# SPDX-License-Identifier: LGPL-3.0
###############################################################

"""Mapper returning device nodes present on every system.

Test hosts rarely have GPUs, so HwlocMapper.map_gpus() returns nothing and
DeviceAllow never appears. This mapper substitutes devices that always
exist, emitting the same comma-separated form the real mapper produces for
a GPU, so tests can exercise the DeviceAllow path anywhere.

Configure with:

    [sdexec]
    mapper = "test_device_mapper.TestDeviceMapper"
    mapper-searchpath = "/path/to/t/scripts"
"""

from flux.sdexec.map import HwlocMapper

# Devices present on any Linux system, plus a subsystem specifier. More than
# one entry is the point: a single GPU already yields several devices, and
# the comma-joined result is what must reach systemctl as separate arguments.
TEST_DEVICES = [
    "/dev/null rw",
    "/dev/zero rw",
    "char-pts rw",
]


class TestDeviceMapper(HwlocMapper):
    """HwlocMapper that reports test devices instead of GPUs."""

    def finalize_properties(self, properties, R, extra_properties=None):
        properties = super().finalize_properties(
            properties, R, extra_properties=extra_properties
        )
        if properties:
            properties["DeviceAllow"] = ",".join(TEST_DEVICES)
        return properties
