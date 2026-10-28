# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# claude-scan-doctor: the box health check users run when something doesn't work
aws s3 cp --region "$REGION" "s3://$ARTIFACT_BUCKET/${ARTIFACT_PREFIX}scripts/claude-scan-doctor.sh" /usr/local/bin/claude-scan-doctor
chmod 755 /usr/local/bin/claude-scan-doctor
