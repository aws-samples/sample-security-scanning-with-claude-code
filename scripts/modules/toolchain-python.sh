# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Python 3.12 with pip, headers for native packages, and uv
dnf install -y python3.12 python3.12-pip python3.12-devel
python3.12 -m pip install --quiet uv
