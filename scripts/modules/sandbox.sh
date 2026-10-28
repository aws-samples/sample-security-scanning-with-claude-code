# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Docker for the harness's sandboxed autonomous pipeline (scan-harness.sh sandbox / run)
dnf install -y docker
systemctl enable --now docker
usermod -aG docker "$U"
