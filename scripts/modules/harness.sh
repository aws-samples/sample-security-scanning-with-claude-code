# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Defending-code harness: scan-harness.sh from the kit bucket, then clone the harness for the claude user
aws s3 cp --region "$REGION" "s3://$ARTIFACT_BUCKET/${ARTIFACT_PREFIX}scripts/scan-harness.sh" /usr/local/bin/scan-harness.sh
chmod 755 /usr/local/bin/scan-harness.sh
as_user 'scan-harness.sh setup'
