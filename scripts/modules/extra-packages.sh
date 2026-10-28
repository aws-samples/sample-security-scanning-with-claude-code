# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# The box stack's ExtraPackages (space-separated Amazon Linux package names)
# shellcheck disable=SC2086
dnf install -y $EXTRA_PACKAGES
