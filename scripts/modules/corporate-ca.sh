# shellcheck shell=bash
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: MIT-0
# Corporate CA for a TLS-inspecting firewall or proxy (shared stack: CorporateCaBundleKey). Added to the
# system trust store, which dnf, curl, Git, Python and the collector use, and pointed to for the tools that
# keep their own list. Runs first, so every later download trusts it.
ca=/etc/pki/ca-trust/source/anchors/claude-scan-corporate-ca.pem
bundle=/etc/pki/tls/certs/ca-bundle.crt
aws s3 cp --region "$REGION" "s3://$ARTIFACT_BUCKET/${ARTIFACT_PREFIX}$CORPORATE_CA_KEY" "$ca"
grep -q "BEGIN CERTIFICATE" "$ca"
update-ca-trust extract
cat > /etc/profile.d/claude-scan-ca.sh <<PROFILE
# Corporate CA (TLS inspection): Node.js and Claude Code add it to their built-in list; the AWS CLI,
# Python requests and pip use the system bundle, which includes it
export NODE_EXTRA_CA_CERTS=$ca
export AWS_CA_BUNDLE=$bundle
export REQUESTS_CA_BUNDLE=$bundle
export SSL_CERT_FILE=$bundle
export PIP_CERT=$bundle
PROFILE
